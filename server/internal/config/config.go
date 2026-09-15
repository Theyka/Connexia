package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

const (
	SessionTTL        = 30 * 24 * time.Hour
	MaxBodyBytes      = 16 * 1024 * 1024
	BlobLimitBytes    = 6 * 1024 * 1024
	VerifyCodeTTL     = 10 * time.Minute
	VerifyResendDelay = time.Minute
	TotpChallengeTTL  = 5 * time.Minute
	ScryptN           = 16384
	ScryptR           = 8
	ScryptP           = 1
	ScryptKeyLen      = 64

	RateRegisterLimit  = 10
	RateRegisterWindow = time.Hour
	RateLoginLimit     = 10
	RateLoginWindow    = time.Minute
	RateCodeLimit      = 10
	RateCodeWindow     = time.Minute
	RateResendLimit    = 5
	RateResendWindow   = time.Minute
	RateSyncLimit      = 120
	RateSyncWindow     = time.Minute
	RateRelayLimit     = 60
	RateRelayWindow    = time.Minute
	RateSweepThreshold = 10000
)

var (
	Port      = EnvInt("PORT", 8047)
	DataDir   = EnvStr("DATA_DIR", filepath.Join(".", "data"))
	SMTP      = smtpConfig()
	EmailRe   = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
	UsersFile string
	BlobsDir  string
)

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

func EnvStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func EnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}

func BlobFile(id string) string {
	return filepath.Join(BlobsDir, id+".json")
}
