// Package ratelimit implements the per-IP fixed-window rate limiting used
// by the public endpoints.
package ratelimit

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/httpx"
)

type bucket struct {
	count   int
	resetAt time.Time
}

// Limiter is an in-memory fixed-window rate limiter keyed by string.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

// New returns an empty limiter.
func New() *Limiter {
	return &Limiter{buckets: map[string]*bucket{}}
}

// Allow records one attempt from key and reports whether it is within the
// fixed window (limit attempts per window). Sweeps expired buckets once the
// map grows large to bound memory.
func (l *Limiter) Allow(key string, limit int, window time.Duration) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if len(l.buckets) >= config.RateSweepThreshold {
		for k, b := range l.buckets {
			if now.After(b.resetAt) {
				delete(l.buckets, k)
			}
		}
	}
	b := l.buckets[key]
	if b == nil || now.After(b.resetAt) {
		l.buckets[key] = &bucket{count: 1, resetAt: now.Add(window)}
		return true
	}
	if b.count >= limit {
		return false
	}
	b.count++
	return true
}

// ClientIP best-effort extracts the caller's IP, honoring X-Forwarded-For
// when the server sits behind a reverse proxy.
func ClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// WithRateLimit wraps a handler with a per-IP fixed-window limit.
func WithRateLimit(l *Limiter, key string, limit int, window time.Duration, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !l.Allow(key+":"+ClientIP(r), limit, window) {
			httpx.SendError(w, 429, "too many requests")
			return
		}
		h(w, r)
	}
}
