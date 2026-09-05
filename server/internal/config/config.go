// Package config holds server configuration: environment variables,
// limits and constants used across the application.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

const (
	SessionTTL        = 30 * 24 * time.Hour // 30 days
	MaxBodyBytes      = 16 * 1024 * 1024    // 16 MB
	BlobLimitBytes    = 6 * 1024 * 1024     // 6 MB
	VerifyCodeTTL     = 10 * time.Minute
	VerifyResendDelay = time.Minute
	TotpChallengeTTL  = 5 * time.Minute
	ScryptN           = 16384 // matches Node's default scryptSync params
	ScryptR           = 8
	ScryptP           = 1
	ScryptKeyLen      = 64

	// Per-IP rate limits (in-memory, fixed window).
	RateRegisterLimit  = 10 // account creations
	RateRegisterWindow = time.Hour
	RateLoginLimit     = 10 // password attempts
	RateLoginWindow    = time.Minute
	RateCodeLimit      = 10 // verify/2FA code checks
	RateCodeWindow     = time.Minute
	RateResendLimit    = 5 // resend-verification requests
	RateResendWindow   = time.Minute
	RateSyncLimit      = 120 // blob uploads
	RateSyncWindow     = time.Minute
	RateSweepThreshold = 10000 // sweep expired buckets when the map grows this big
)

var (
	Port      = EnvInt("PORT", 8047)
	DataDir   = EnvStr("DATA_DIR", filepath.Join(".", "data"))
	SMTP      = smtpConfig()
	EmailRe   = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
	UsersFile string
	BlobsDir  string
)

// SMTPConfig describes the outgoing mail server. Without a Host the email
// package logs messages to the console instead of sending them.
type SMTPConfig struct {
	Host   string
	Port   int
	Secure bool
	User   string
	Pass   string
	From   string
}

func smtpConfig() SMTPConfig {
	secure := EnvStr("SMTP_SECURE", "") == "true"
	port := EnvInt("SMTP_PORT", 587)
	if secure {
		port = 465
	}
	return SMTPConfig{
		Host:   EnvStr("SMTP_HOST", ""),
		Port:   port,
		Secure: secure,
		User:   EnvStr("SMTP_USER", ""),
		Pass:   EnvStr("SMTP_PASS", ""),
		From:   EnvStr("SMTP_FROM", "Connexia <noreply@connexia.local>"),
	}
}

// EnvStr returns the environment variable or the default when unset/empty.
func EnvStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// EnvInt returns the environment variable parsed as an int, or the default.
func EnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}

// BlobFile returns the legacy JSON path of one blob (pre-database format).
func BlobFile(id string) string {
	return filepath.Join(BlobsDir, id+".json")
}
