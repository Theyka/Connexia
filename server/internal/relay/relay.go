package relay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/state"
)

const (
	Protocol    = "connexia-relay"
	tokenPrefix = "token."
	maxPerUser  = 32
	maxDialing  = 8
	dialTimeout = 10 * time.Second
	pingEvery   = 25 * time.Second
	pingTimeout = 15 * time.Second
	readLimit   = 1 << 20
)

const (
	closeBadTarget    websocket.StatusCode = 4400
	closeUnauthorized websocket.StatusCode = 4401
	closeDisabled     websocket.StatusCode = 4403
	closeBlocked      websocket.StatusCode = 4406
	closeTooMany      websocket.StatusCode = 4429
	closeUnreachable  websocket.StatusCode = 4502
)

var (
	errNotFound = errors.New("host not found")
	errBlocked  = errors.New("address not allowed")

	blockedNets = parseNets(
		"0.0.0.0/8",
		"100.64.0.0/10",
		"192.0.0.0/24",
		"198.18.0.0/15",
		"240.0.0.0/4",
	)

	mu      sync.Mutex
	active  = map[string]int{}
	dialing = map[string]int{}
)

func parseNets(cidrs ...string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, cidr := range cidrs {
		_, n, err := net.ParseCIDR(cidr)
		if err != nil {
			panic(err)
		}
		out = append(out, n)
	}
	return out
}

func Handle(w http.ResponseWriter, r *http.Request) {
	token := ""
	for _, part := range strings.Split(r.Header.Get("Sec-WebSocket-Protocol"), ",") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, tokenPrefix) {
			token = strings.TrimPrefix(part, tokenPrefix)
		}
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Protocol}})
	if err != nil {
		return
	}
	conn.SetReadLimit(readLimit)

	userID := state.AuthToken(token)
	state.St.Mu.RLock()
	account := state.St.Users[userID]
	state.St.Mu.RUnlock()
	if userID == "" || account == nil || (account.EmailVerified != nil && !*account.EmailVerified) {
		conn.Close(closeUnauthorized, "Your session expired. Sign in again.")
		return
	}

	enabled, allowPrivate := state.WebSSH()
	if !enabled {
		conn.Close(closeDisabled, "Web SSH is turned off on this server.")
		return
	}

	host := strings.TrimSpace(r.URL.Query().Get("host"))
	port, err := strconv.Atoi(r.URL.Query().Get("port"))
	if host == "" || len(host) > 253 || err != nil || port < 1 || port > 65535 {
		conn.Close(closeBadTarget, "Invalid host or port.")
		return
	}

	if !take(dialing, userID, maxDialing) {
		log.Printf("[%s] relay %s -> %s:%d rejected: %d connection attempts already in progress", cryptoutil.NowISO(), account.Email, host, port, maxDialing)
		conn.Close(closeTooMany, "Too many web SSH connections are being opened at once. Try again in a few seconds.")
		return
	}
	upstream, failure := dial(r.Context(), host, port, allowPrivate)
	give(dialing, userID)
	if failure != nil {
		log.Printf("[%s] relay %s -> %s:%d failed: %s", cryptoutil.NowISO(), account.Email, host, port, failure.reason)
		conn.Close(failure.code, failure.reason)
		return
	}
	defer upstream.Close()

	if !take(active, userID, maxPerUser) {
		log.Printf("[%s] relay %s -> %s:%d rejected: %d connections already open", cryptoutil.NowISO(), account.Email, host, port, maxPerUser)
		conn.Close(closeTooMany, fmt.Sprintf("Too many web SSH connections are open (%d). Close some terminals, SFTP panes or tracked servers.", maxPerUser))
		return
	}
	defer give(active, userID)

	started := time.Now()
	log.Printf("[%s] relay %s -> %s:%d opened", cryptoutil.NowISO(), account.Email, host, port)

	streamCtx, stop := context.WithCancel(context.Background())
	defer stop()
	stream := websocket.NetConn(streamCtx, conn, websocket.MessageBinary)

	go func() {
		ticker := time.NewTicker(pingEvery)
		defer ticker.Stop()
		for {
			select {
			case <-streamCtx.Done():
				return
			case <-ticker.C:
				ctx, cancel := context.WithTimeout(streamCtx, pingTimeout)
				err := conn.Ping(ctx)
				cancel()
				if err != nil && streamCtx.Err() == nil {
					log.Printf("[%s] relay %s -> %s:%d browser stopped answering, closing", cryptoutil.NowISO(), account.Email, host, port)
					upstream.Close()
					conn.CloseNow()
					return
				}
			}
		}
	}()

	done := make(chan struct{}, 2)
	var sent, received int64
	go func() {
		sent, _ = io.Copy(upstream, stream)
		done <- struct{}{}
	}()
	go func() {
		received, _ = io.Copy(stream, upstream)
		done <- struct{}{}
	}()
	<-done
	upstream.Close()
	conn.Close(websocket.StatusNormalClosure, "")
	stop()
	<-done

	log.Printf("[%s] relay %s -> %s:%d closed after %s (%d bytes up, %d down)",
		cryptoutil.NowISO(), account.Email, host, port, time.Since(started).Round(time.Second), sent, received)
}

type dialError struct {
	code   websocket.StatusCode
	reason string
}

func dial(parent context.Context, host string, port int, allowPrivate bool) (net.Conn, *dialError) {
	ctx, cancel := context.WithTimeout(parent, dialTimeout)
	defer cancel()
	ip, err := resolve(ctx, host, allowPrivate)
	if errors.Is(err, errBlocked) {
		return nil, &dialError{closeBlocked, fmt.Sprintf("%s is a private or local address, which this server doesn't relay to.", host)}
	}
	if err != nil {
		return nil, &dialError{closeUnreachable, fmt.Sprintf("Could not resolve %s.", host)}
	}
	var dialer net.Dialer
	upstream, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), strconv.Itoa(port)))
	if err != nil {
		return nil, &dialError{closeUnreachable, fmt.Sprintf("Could not connect to %s:%d (%s).", host, port, dialFailure(err))}
	}
	return upstream, nil
}

func take(counts map[string]int, userID string, limit int) bool {
	mu.Lock()
	defer mu.Unlock()
	if counts[userID] >= limit {
		return false
	}
	counts[userID]++
	return true
}

func give(counts map[string]int, userID string) {
	mu.Lock()
	defer mu.Unlock()
	counts[userID]--
	if counts[userID] <= 0 {
		delete(counts, userID)
	}
}

func resolve(ctx context.Context, host string, allowPrivate bool) (net.IP, error) {
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return nil, errNotFound
	}
	for _, ip := range ips {
		if allowPrivate || isPublic(ip) {
			return ip, nil
		}
	}
	return nil, errBlocked
}

func isPublic(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() || ip.IsMulticast() ||
		ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsInterfaceLocalMulticast() {
		return false
	}
	for _, n := range blockedNets {
		if n.Contains(ip) {
			return false
		}
	}
	return true
}

func dialFailure(err error) string {
	var netErr net.Error
	switch {
	case errors.As(err, &netErr) && netErr.Timeout():
		return "timed out"
	case strings.Contains(err.Error(), "refused"):
		return "connection refused"
	case strings.Contains(err.Error(), "unreachable"):
		return "network unreachable"
	default:
		return "connection failed"
	}
}
