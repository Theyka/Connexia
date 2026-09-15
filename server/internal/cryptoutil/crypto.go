package cryptoutil

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/hex"
	"fmt"
	"log"
	"net/url"
	"strings"
	"time"

	"golang.org/x/crypto/scrypt"

	"connexia/syncserver/internal/config"
)

func ScryptHash(password string, salt []byte) []byte {
	hash, err := scrypt.Key([]byte(password), salt, config.ScryptN, config.ScryptR, config.ScryptP, config.ScryptKeyLen)
	if err != nil {
		log.Printf("scrypt error: %v", err)
		return make([]byte, config.ScryptKeyLen)
	}
	return hash
}

func NewSalt() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return hex.EncodeToString(buf)
}

func NewUUID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", buf[0:4], buf[4:6], buf[6:8], buf[8:10], buf[10:16])
}

func RandomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return hex.EncodeToString(buf)
}

func NowISO() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
}

func ParseISO(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

func MustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		log.Printf("hex decode error for salt %q", s)
		return []byte(s)
	}
	return b
}

func base32Decode(s string) ([]byte, error) {
	return base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(
		strings.ToUpper(strings.Map(func(r rune) rune {
			switch {
			case r >= 'A' && r <= 'Z':
				return r
			case r >= '2' && r <= '7':
				return r
			default:
				return -1
			}
		}, s)),
	)
}

func base32Encode(buf []byte) string {
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buf)
}

func totpAt(secretB32 string, timeSec int64) string {
	key, err := base32Decode(secretB32)
	if err != nil {
		return ""
	}
	counter := timeSec / 30
	var msg [8]byte
	for i := 7; i >= 0; i-- {
		msg[i] = byte(counter & 0xff)
		counter >>= 8
	}
	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	code := ((int(sum[offset]) & 0x7f) << 24) |
		(int(sum[offset+1]) << 16) |
		(int(sum[offset+2]) << 8) |
		int(sum[offset+3])
	return fmt.Sprintf("%06d", code%1000000)
}

func VerifyTotp(secretB32, code string) bool {
	now := time.Now().Unix()
	for i := int64(-1); i <= 1; i++ {
		if totpAt(secretB32, now+i*30) == code {
			return true
		}
	}
	return false
}

func NewTotpSecret() string {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return base32Encode(buf)
}

func OtpauthURL(email, secret string) string {
	return "otpauth://totp/Connexia:" + url.QueryEscape(email) +
		"?secret=" + secret + "&issuer=Connexia&digits=6&period=30"
}
