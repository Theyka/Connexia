// Package email sends transactional mail (verification codes) over SMTP,
// supporting implicit TLS (465) and STARTTLS (587).
package email

import (
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"log"
	"net/smtp"
	"strings"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/model"
)

// Send delivers one plain-text message. Without SMTP_HOST it logs the
// would-be message to the console instead, which is handy for local
// testing.
func Send(to, subject, text string) error {
	cfg := config.SMTP
	if cfg.Host == "" {
		log.Printf("[smtp] no SMTP_HOST configured; would email %s:", to)
		log.Printf("[smtp] subject: %s", subject)
		log.Printf("[smtp] body:\n%s", text)
		return nil
	}
	addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)

	var client *smtp.Client
	var err error
	if cfg.Secure {
		conn, cerr := tls.Dial("tcp", addr, &tls.Config{ServerName: cfg.Host})
		if cerr != nil {
			return cerr
		}
		client, err = smtp.NewClient(conn, cfg.Host)
	} else {
		client, err = smtp.Dial(addr)
	}
	if err != nil {
		return err
	}
	defer client.Close()

	if !cfg.Secure {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(&tls.Config{ServerName: cfg.Host}); err != nil {
				return err
			}
		}
	}
	if cfg.User != "" {
		auth := smtp.PlainAuth("", cfg.User, cfg.Pass, cfg.Host)
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	// MAIL FROM must be a bare address; the optional display name
	// ("Connexia <noreply@...>") belongs only in the From header.
	if err := client.Mail(EnvelopeFrom(cfg.From)); err != nil {
		return err
	}
	if err := client.Rcpt(to); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	body := "From: " + cfg.From + "\r\n" +
		"To: " + to + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=utf-8\r\n" +
		"Content-Transfer-Encoding: 8bit\r\n" +
		"\r\n" +
		text
	if _, err := w.Write([]byte(body)); err != nil {
		return err
	}
	return w.Close()
}

// EnvelopeFrom returns the bare email address from a From value that may
// include a display name, e.g. "Connexia <noreply@connexia.run>" ->
// "noreply@connexia.run". Used for the SMTP MAIL FROM command.
func EnvelopeFrom(from string) string {
	if i := strings.LastIndex(from, "<"); i >= 0 {
		if j := strings.Index(from[i:], ">"); j > 0 {
			return from[i+1 : i+j]
		}
	}
	return from
}

// SendVerificationEmail emails the 6-digit verification code.
func SendVerificationEmail(to, code string) {
	err := Send(to, "Your Connexia verification code",
		"Your Connexia verification code is: "+code+
			"\n\nEnter it in the app to verify your email. "+
			"The code expires in 10 minutes.\n\nIf you did not create a "+
			"Connexia account, you can ignore this email.")
	if err != nil {
		log.Printf("[smtp] %v", err)
	}
}

// NewVerifyCode generates a fresh 6-digit code with its expiry timestamp.
func NewVerifyCode() model.VerifyCode {
	buf := make([]byte, 3)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	n := (int(buf[0])<<16 | int(buf[1])<<8 | int(buf[2])) % 1000000
	return model.VerifyCode{Code: fmt.Sprintf("%06d", n), ExpiresAt: time.Now().Add(config.VerifyCodeTTL).UTC().Format("2006-01-02T15:04:05.000Z")}
}

// VerifyCodeValid reports whether code matches the account's pending
// verification code and has not expired.
func VerifyCodeValid(account *model.User, code string) bool {
	if account.VerifyCode == nil {
		return false
	}
	return account.VerifyCode.Code == code &&
		time.Now().Before(cryptoutil.ParseISO(account.VerifyCode.ExpiresAt))
}

// CanResend reports whether another verification code may be sent, given
// the resend delay since the last one.
func CanResend(account *model.User) bool {
	if account.LastVerifySent == "" {
		return true
	}
	return time.Since(cryptoutil.ParseISO(account.LastVerifySent)) >= config.VerifyResendDelay
}
