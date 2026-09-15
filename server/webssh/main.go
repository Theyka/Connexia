//go:build js && wasm

package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"syscall/js"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

var (
	jsObject     = js.Global().Get("Object")
	jsArray      = js.Global().Get("Array")
	jsUint8Array = js.Global().Get("Uint8Array")
	jsPromise    = js.Global().Get("Promise")
	jsError      = js.Global().Get("Error")
	errCancelled = errors.New("Cancelled.")
)

func main() {
	api := jsObject.New()
	api.Set("connect", js.FuncOf(connect))
	js.Global().Set("connexiaSSH", api)
	if ready := js.Global().Get("connexiaSSHReady"); ready.Type() == js.TypeFunction {
		ready.Invoke()
	}
	select {}
}

func promise(work func() (any, error)) js.Value {
	var executor js.Func
	executor = js.FuncOf(func(_ js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			defer executor.Release()
			value, err := work()
			if err != nil {
				reject.Invoke(jsError.New(err.Error()))
				return
			}
			resolve.Invoke(value)
		}()
		return nil
	})
	return jsPromise.New(executor)
}

func await(value js.Value) (js.Value, error) {
	results := make(chan js.Value, 1)
	failures := make(chan error, 1)
	onResolve := js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 {
			results <- args[0]
		} else {
			results <- js.Undefined()
		}
		return nil
	})
	onReject := js.FuncOf(func(_ js.Value, args []js.Value) any {
		message := "cancelled"
		if len(args) > 0 {
			if m := args[0].Get("message"); m.Type() == js.TypeString {
				message = m.String()
			} else {
				message = args[0].Call("toString").String()
			}
		}
		failures <- errors.New(message)
		return nil
	})
	defer onResolve.Release()
	defer onReject.Release()
	jsPromise.Call("resolve", value).Call("then", onResolve, onReject)
	select {
	case result := <-results:
		return result, nil
	case err := <-failures:
		return js.Undefined(), err
	}
}

func isThenable(value js.Value) bool {
	return value.Type() == js.TypeObject && value.Get("then").Type() == js.TypeFunction
}

func optString(opts js.Value, key string) string {
	value := opts.Get(key)
	if value.Type() != js.TypeString {
		return ""
	}
	return value.String()
}

func optInt(opts js.Value, key string, fallback int) int {
	value := opts.Get(key)
	if value.Type() != js.TypeNumber {
		return fallback
	}
	return value.Int()
}

func argString(args []js.Value, i int) string {
	if i >= len(args) || args[i].Type() != js.TypeString {
		return ""
	}
	return args[i].String()
}

func toStrings(value js.Value) []string {
	if value.Type() != js.TypeObject {
		return nil
	}
	out := make([]string, value.Length())
	for i := range out {
		out[i] = value.Index(i).String()
	}
	return out
}

func toBytes(value js.Value) []byte {
	if value.Type() == js.TypeString {
		return []byte(value.String())
	}
	out := make([]byte, value.Length())
	js.CopyBytesToGo(out, value)
	return out
}

func toUint8Array(data []byte) js.Value {
	array := jsUint8Array.New(len(data))
	js.CopyBytesToJS(array, data)
	return array
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *lockedBuffer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

func (w *lockedBuffer) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.String()
}

type relayAddr struct{}

func (relayAddr) Network() string { return "websocket" }
func (relayAddr) String() string  { return "relay" }

type wsConn struct {
	ws      js.Value
	mu      sync.Mutex
	cond    *sync.Cond
	pending [][]byte
	current []byte
	closed  bool
	reason  string
}

func dialRelay(url string, protocols []string) (*wsConn, error) {
	c := &wsConn{}
	c.cond = sync.NewCond(&c.mu)

	jsProtocols := jsArray.New()
	for _, p := range protocols {
		jsProtocols.Call("push", p)
	}
	c.ws = js.Global().Get("WebSocket").New(url, jsProtocols)
	c.ws.Set("binaryType", "arraybuffer")

	opened := make(chan struct{})
	var openOnce sync.Once
	c.ws.Set("onopen", js.FuncOf(func(js.Value, []js.Value) any {
		openOnce.Do(func() { close(opened) })
		return nil
	}))
	c.ws.Set("onmessage", js.FuncOf(func(_ js.Value, args []js.Value) any {
		data := toBytes(jsUint8Array.New(args[0].Get("data")))
		c.mu.Lock()
		c.pending = append(c.pending, data)
		c.mu.Unlock()
		c.cond.Broadcast()
		return nil
	}))
	c.ws.Set("onclose", js.FuncOf(func(_ js.Value, args []js.Value) any {
		c.mu.Lock()
		c.closed = true
		if reason := args[0].Get("reason").String(); reason != "" {
			c.reason = reason
		}
		c.mu.Unlock()
		c.cond.Broadcast()
		openOnce.Do(func() { close(opened) })
		return nil
	}))

	<-opened
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		if c.reason != "" {
			return nil, errors.New(c.reason)
		}
		return nil, errors.New("Could not reach the SSH relay on the sync server.")
	}
	return c, nil
}

func (c *wsConn) closeReason() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reason
}

func (c *wsConn) Read(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.current) == 0 && len(c.pending) == 0 && !c.closed {
		c.cond.Wait()
	}
	if len(c.current) == 0 {
		if len(c.pending) == 0 {
			return 0, io.EOF
		}
		c.current = c.pending[0]
		c.pending = c.pending[1:]
	}
	n := copy(p, c.current)
	c.current = c.current[n:]
	return n, nil
}

func (c *wsConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return 0, net.ErrClosed
	}
	c.ws.Call("send", toUint8Array(p))
	return len(p), nil
}

func (c *wsConn) Close() error {
	c.mu.Lock()
	wasClosed := c.closed
	c.closed = true
	c.mu.Unlock()
	c.cond.Broadcast()
	if !wasClosed {
		c.ws.Call("close")
	}
	return nil
}

func (c *wsConn) LocalAddr() net.Addr              { return relayAddr{} }
func (c *wsConn) RemoteAddr() net.Addr             { return relayAddr{} }
func (c *wsConn) SetDeadline(time.Time) error      { return nil }
func (c *wsConn) SetReadDeadline(time.Time) error  { return nil }
func (c *wsConn) SetWriteDeadline(time.Time) error { return nil }

type byteQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	items  [][]byte
	closed bool
}

func newByteQueue() *byteQueue {
	q := &byteQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *byteQueue) push(data []byte) {
	q.mu.Lock()
	q.items = append(q.items, data)
	q.mu.Unlock()
	q.cond.Signal()
}

func (q *byteQueue) pop() ([]byte, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.items) == 0 && !q.closed {
		q.cond.Wait()
	}
	if len(q.items) == 0 {
		return nil, false
	}
	item := q.items[0]
	q.items = q.items[1:]
	return item, true
}

func (q *byteQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	q.cond.Broadcast()
}

func ask(opts js.Value, name, instruction string, questions []string, echos []bool) ([]string, error) {
	prompt := opts.Get("prompt")
	if prompt.Type() != js.TypeFunction {
		return nil, errors.New("Authentication failed. Check the username, password or key.")
	}
	jsQuestions := jsArray.New()
	jsEchos := jsArray.New()
	for i, q := range questions {
		jsQuestions.Call("push", q)
		jsEchos.Call("push", echos[i])
	}
	result, err := await(prompt.Invoke(name, instruction, jsQuestions, jsEchos))
	if err != nil {
		return nil, err
	}
	if result.Type() != js.TypeObject {
		return nil, errors.New("Authentication cancelled.")
	}
	answers := toStrings(result)
	if len(answers) != len(questions) {
		return nil, errors.New("Authentication cancelled.")
	}
	return answers, nil
}

func authMethods(opts js.Value) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	password := optString(opts, "password")

	if pem := optString(opts, "privateKey"); pem != "" {
		signer, err := ssh.ParsePrivateKey([]byte(pem))
		var missing *ssh.PassphraseMissingError
		if errors.As(err, &missing) {
			passphrase := optString(opts, "passphrase")
			if passphrase == "" {
				answers, askErr := ask(opts, "", "The private key is protected by a passphrase.", []string{"Passphrase:"}, []bool{false})
				if askErr != nil {
					return nil, askErr
				}
				passphrase = answers[0]
			}
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(pem), []byte(passphrase))
		}
		if err != nil {
			return nil, errors.New("Could not read the private key: " + err.Error())
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}

	if password != "" {
		methods = append(methods, ssh.Password(password))
	} else if opts.Get("prompt").Type() == js.TypeFunction {
		methods = append(methods, ssh.PasswordCallback(func() (string, error) {
			answers, err := ask(opts, "", "", []string{"Password:"}, []bool{false})
			if err != nil {
				return "", err
			}
			return answers[0], nil
		}))
	}

	usedPassword := false
	methods = append(methods, ssh.KeyboardInteractive(func(name, instruction string, questions []string, echos []bool) ([]string, error) {
		if len(questions) == 0 {
			return nil, nil
		}
		if password != "" && !usedPassword && len(questions) == 1 && !echos[0] {
			usedPassword = true
			return []string{password}, nil
		}
		return ask(opts, name, instruction, questions, echos)
	}))
	return methods, nil
}

func friendlyError(err error, conn *wsConn) error {
	if reason := conn.closeReason(); reason != "" {
		return errors.New(reason)
	}
	message := err.Error()
	switch {
	case strings.Contains(message, "unable to authenticate"):
		return errors.New("Authentication failed. Check the username, password or key.")
	case strings.Contains(message, "EOF"):
		return errors.New("The server closed the connection.")
	}
	return errors.New(strings.TrimPrefix(message, "ssh: "))
}

func sftpError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, errCancelled) {
		return errCancelled
	}
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("No such file or directory.")
	}
	if errors.Is(err, os.ErrPermission) {
		return errors.New("Permission denied.")
	}
	message := err.Error()
	if strings.HasPrefix(message, "sftp: \"") {
		message = strings.TrimPrefix(message, "sftp: \"")
		if i := strings.LastIndex(message, "\" ("); i >= 0 {
			message = message[:i]
		}
	}
	message = strings.TrimPrefix(message, "sftp: ")
	if message == "" {
		message = "The operation failed."
	}
	return errors.New(message)
}

func connect(_ js.Value, args []js.Value) any {
	opts := args[0]
	return promise(func() (any, error) {
		methods, err := authMethods(opts)
		if err != nil {
			return nil, err
		}

		conn, err := dialRelay(optString(opts, "url"), toStrings(opts.Get("protocols")))
		if err != nil {
			return nil, err
		}

		config := &ssh.ClientConfig{
			User: optString(opts, "username"),
			Auth: methods,
			HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
				result, err := await(opts.Call("verifyHostKey", key.Type(), ssh.FingerprintSHA256(key)))
				if err != nil {
					return err
				}
				if result.Type() == js.TypeString {
					return errors.New(result.String())
				}
				if !result.Truthy() {
					return errors.New("Connection cancelled: host key not trusted.")
				}
				return nil
			},
			HostKeyAlgorithms: []string{
				ssh.KeyAlgoED25519,
				ssh.KeyAlgoRSASHA512,
				ssh.KeyAlgoRSASHA256,
				ssh.KeyAlgoRSA,
				ssh.KeyAlgoECDSA521,
				ssh.KeyAlgoECDSA384,
				ssh.KeyAlgoECDSA256,
			},
		}

		clientConn, channels, requests, err := ssh.NewClientConn(conn, "relay", config)
		if err != nil {
			conn.Close()
			if strings.HasPrefix(err.Error(), "ssh: handshake failed: ") {
				inner := errors.New(strings.TrimPrefix(err.Error(), "ssh: handshake failed: "))
				return nil, friendlyError(inner, conn)
			}
			return nil, friendlyError(err, conn)
		}
		client := ssh.NewClient(clientConn, channels, requests)

		if shell := opts.Get("shell"); shell.Type() == js.TypeBoolean && !shell.Bool() {
			return clientHandle(client, opts, conn), nil
		}
		session, err := openShell(client, opts, conn)
		if err != nil {
			client.Close()
			return nil, err
		}
		return session, nil
	})
}

func notifyClose(opts js.Value, reason string) {
	onClose := opts.Get("onClose")
	if onClose.Type() != js.TypeFunction {
		return
	}
	if reason == "" {
		onClose.Invoke(js.Null())
	} else {
		onClose.Invoke(reason)
	}
}

func clientHandle(client *ssh.Client, opts js.Value, conn *wsConn) js.Value {
	var finishOnce sync.Once
	finish := func(reason string) {
		finishOnce.Do(func() {
			client.Close()
			notifyClose(opts, reason)
		})
	}
	go func() {
		client.Wait()
		finish(conn.closeReason())
	}()

	handle := jsObject.New()
	handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		go finish("")
		return nil
	}))
	addCommands(handle, client)
	return handle
}

func openShell(client *ssh.Client, opts js.Value, conn *wsConn) (js.Value, error) {
	session, err := client.NewSession()
	if err != nil {
		return js.Undefined(), friendlyError(err, conn)
	}
	modes := ssh.TerminalModes{ssh.ECHO: 1, ssh.TTY_OP_ISPEED: 14400, ssh.TTY_OP_OSPEED: 14400}
	if err := session.RequestPty("xterm-256color", optInt(opts, "rows", 24), optInt(opts, "cols", 80), modes); err != nil {
		return js.Undefined(), friendlyError(err, conn)
	}
	stdin, _ := session.StdinPipe()
	stdout, _ := session.StdoutPipe()
	stderr, _ := session.StderrPipe()
	if err := session.Shell(); err != nil {
		return js.Undefined(), friendlyError(err, conn)
	}

	onData := opts.Get("onData")
	input := newByteQueue()

	var finishOnce sync.Once
	finish := func(reason string) {
		finishOnce.Do(func() {
			input.close()
			client.Close()
			notifyClose(opts, reason)
		})
	}

	go func() {
		for {
			data, ok := input.pop()
			if !ok {
				return
			}
			if _, err := stdin.Write(data); err != nil {
				return
			}
		}
	}()

	var pumps sync.WaitGroup
	pump := func(r io.Reader) {
		defer pumps.Done()
		buf := make([]byte, 32*1024)
		for {
			n, err := r.Read(buf)
			if n > 0 && onData.Type() == js.TypeFunction {
				onData.Invoke(toUint8Array(buf[:n]))
			}
			if err != nil {
				return
			}
		}
	}
	pumps.Add(2)
	go pump(stdout)
	go pump(stderr)

	go func() {
		err := session.Wait()
		pumps.Wait()
		var exit *ssh.ExitError
		if err != nil && !errors.As(err, &exit) {
			if reason := conn.closeReason(); reason != "" {
				finish(reason)
				return
			}
		}
		finish("")
	}()

	handle := jsObject.New()
	handle.Set("write", js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 {
			input.push(toBytes(args[0]))
		}
		return nil
	}))
	handle.Set("resize", js.FuncOf(func(_ js.Value, args []js.Value) any {
		cols, rows := args[0].Int(), args[1].Int()
		go session.WindowChange(rows, cols)
		return nil
	}))
	handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		go finish("")
		return nil
	}))
	addCommands(handle, client)
	return handle, nil
}

func addCommands(handle js.Value, client *ssh.Client) {
	handle.Set("exec", js.FuncOf(func(_ js.Value, args []js.Value) any {
		command := argString(args, 0)
		return promise(func() (any, error) {
			run, err := client.NewSession()
			if err != nil {
				return nil, err
			}
			defer run.Close()
			output := &lockedBuffer{}
			run.Stdout = output
			run.Stderr = output
			code := 0
			if err := run.Run(command); err != nil {
				var exit *ssh.ExitError
				if !errors.As(err, &exit) {
					return nil, err
				}
				code = exit.ExitStatus()
			}
			result := jsObject.New()
			result.Set("output", output.String())
			result.Set("code", code)
			return result, nil
		})
	}))

	handle.Set("run", js.FuncOf(func(_ js.Value, args []js.Value) any {
		command := argString(args, 0)
		var stdin []byte
		if len(args) > 1 && (args[1].Type() == js.TypeString || args[1].Type() == js.TypeObject) {
			stdin = toBytes(args[1])
		}
		return promise(func() (any, error) {
			run, err := client.NewSession()
			if err != nil {
				return nil, errors.New("Lost connection")
			}
			defer run.Close()
			stdout := &lockedBuffer{}
			stderr := &lockedBuffer{}
			run.Stdout = stdout
			run.Stderr = stderr
			run.Stdin = bytes.NewReader(stdin)
			code := 0
			if err := run.Run(command); err != nil {
				var exit *ssh.ExitError
				var missing *ssh.ExitMissingError
				switch {
				case errors.As(err, &exit):
					code = exit.ExitStatus()
				case errors.As(err, &missing):
					code = -1
				default:
					return nil, errors.New("Lost connection")
				}
			}
			result := jsObject.New()
			result.Set("stdout", stdout.String())
			result.Set("stderr", stderr.String())
			result.Set("code", code)
			return result, nil
		})
	}))

	handle.Set("sftp", js.FuncOf(func(js.Value, []js.Value) any {
		return promise(func() (any, error) {
			sc, err := sftp.NewClient(client, sftp.UseConcurrentWrites(true), sftp.UseConcurrentReads(true))
			if err != nil {
				return nil, errors.New("This server does not support SFTP: " + err.Error())
			}
			return sftpHandle(sc), nil
		})
	}))
}

func fileInfo(name string, info os.FileInfo, isDir bool) js.Value {
	entry := jsObject.New()
	entry.Set("name", name)
	entry.Set("size", float64(info.Size()))
	entry.Set("mode", uint32(info.Mode().Perm()))
	entry.Set("isDir", isDir)
	entry.Set("isLink", info.Mode()&os.ModeSymlink != 0)
	entry.Set("mtime", float64(info.ModTime().UnixMilli()))
	return entry
}

func sftpHandle(sc *sftp.Client) js.Value {
	handle := jsObject.New()
	pathOp := func(op func(path string) error) js.Func {
		return js.FuncOf(func(_ js.Value, args []js.Value) any {
			path := argString(args, 0)
			return promise(func() (any, error) {
				if err := op(path); err != nil {
					return nil, sftpError(err)
				}
				return js.Undefined(), nil
			})
		})
	}

	handle.Set("home", js.FuncOf(func(js.Value, []js.Value) any {
		return promise(func() (any, error) {
			dir, err := sc.Getwd()
			if err != nil {
				return "/", nil
			}
			return dir, nil
		})
	}))

	handle.Set("list", js.FuncOf(func(_ js.Value, args []js.Value) any {
		dir := argString(args, 0)
		return promise(func() (any, error) {
			infos, err := sc.ReadDir(dir)
			if err != nil {
				return nil, sftpError(err)
			}
			entries := jsArray.New()
			for _, info := range infos {
				name := info.Name()
				if name == "." || name == ".." {
					continue
				}
				isDir := info.IsDir()
				if info.Mode()&os.ModeSymlink != 0 {
					if target, err := sc.Stat(strings.TrimSuffix(dir, "/") + "/" + name); err == nil {
						isDir = target.IsDir()
					}
				}
				entries.Call("push", fileInfo(name, info, isDir))
			}
			return entries, nil
		})
	}))

	handle.Set("stat", js.FuncOf(func(_ js.Value, args []js.Value) any {
		path := argString(args, 0)
		return promise(func() (any, error) {
			info, err := sc.Stat(path)
			if err != nil {
				return nil, sftpError(err)
			}
			return fileInfo(info.Name(), info, info.IsDir()), nil
		})
	}))

	handle.Set("mkdir", pathOp(sc.Mkdir))
	handle.Set("remove", pathOp(sc.Remove))
	handle.Set("rmdir", pathOp(sc.RemoveDirectory))

	handle.Set("rename", js.FuncOf(func(_ js.Value, args []js.Value) any {
		from, to := argString(args, 0), argString(args, 1)
		return promise(func() (any, error) {
			if err := sc.Rename(from, to); err != nil {
				return nil, sftpError(err)
			}
			return js.Undefined(), nil
		})
	}))

	handle.Set("chmod", js.FuncOf(func(_ js.Value, args []js.Value) any {
		path := argString(args, 0)
		mode := uint32(args[1].Int())
		return promise(func() (any, error) {
			if err := sc.Chmod(path, os.FileMode(mode)); err != nil {
				return nil, sftpError(err)
			}
			return js.Undefined(), nil
		})
	}))

	handle.Set("openRead", js.FuncOf(func(_ js.Value, args []js.Value) any {
		path := argString(args, 0)
		return promise(func() (any, error) {
			file, err := sc.Open(path)
			if err != nil {
				return nil, sftpError(err)
			}
			return readHandle(file), nil
		})
	}))

	handle.Set("openWrite", js.FuncOf(func(_ js.Value, args []js.Value) any {
		path := argString(args, 0)
		return promise(func() (any, error) {
			file, err := sc.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
			if err != nil {
				return nil, sftpError(err)
			}
			return writeHandle(file), nil
		})
	}))

	handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		go sc.Close()
		return nil
	}))
	return handle
}

type chunkWriter func([]byte) (int, error)

func (w chunkWriter) Write(p []byte) (int, error) { return w(p) }

func closeOnce(file *sftp.File) func() error {
	var once sync.Once
	var err error
	return func() error {
		once.Do(func() { err = file.Close() })
		return err
	}
}

func readHandle(file *sftp.File) js.Value {
	handle := jsObject.New()
	closeFile := closeOnce(file)
	size := -1.0
	if info, err := file.Stat(); err == nil {
		size = float64(info.Size())
	}
	handle.Set("size", size)

	var cancelled sync.Mutex
	stopped := false
	handle.Set("readAll", js.FuncOf(func(_ js.Value, args []js.Value) any {
		onChunk := args[0]
		return promise(func() (any, error) {
			const chunk = 256 * 1024
			writer := chunkWriter(func(p []byte) (int, error) {
				for offset := 0; offset < len(p); offset += chunk {
					cancelled.Lock()
					stop := stopped
					cancelled.Unlock()
					if stop {
						return 0, errCancelled
					}
					end := min(offset+chunk, len(p))
					result := onChunk.Invoke(toUint8Array(p[offset:end]))
					if result.Type() == js.TypeBoolean && !result.Bool() {
						return 0, errCancelled
					}
					if isThenable(result) {
						if _, err := await(result); err != nil {
							return 0, err
						}
					}
				}
				return len(p), nil
			})
			total, err := file.WriteTo(writer)
			closeFile()
			if err != nil {
				return nil, sftpError(err)
			}
			return float64(total), nil
		})
	}))
	handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		cancelled.Lock()
		stopped = true
		cancelled.Unlock()
		go closeFile()
		return nil
	}))
	return handle
}

func writeHandle(file *sftp.File) js.Value {
	handle := jsObject.New()
	closeFile := closeOnce(file)
	handle.Set("write", js.FuncOf(func(_ js.Value, args []js.Value) any {
		data := toBytes(args[0])
		return promise(func() (any, error) {
			if _, err := file.Write(data); err != nil {
				return nil, sftpError(err)
			}
			return js.Undefined(), nil
		})
	}))
	handle.Set("close", js.FuncOf(func(js.Value, []js.Value) any {
		return promise(func() (any, error) {
			if err := closeFile(); err != nil {
				return nil, sftpError(err)
			}
			return js.Undefined(), nil
		})
	}))
	return handle
}
