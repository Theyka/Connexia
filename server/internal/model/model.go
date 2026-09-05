// Package model defines the domain types shared by every layer: kept hot
// in memory by the state package and persisted through the store package.
package model

// VerifyCode is a pending email-verification code.
type VerifyCode struct {
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

// TotpPending holds a 2FA secret awaiting user confirmation.
type TotpPending struct {
	Secret    string `json:"secret"`
	CreatedAt string `json:"createdAt"`
}

// Challenge is a short-lived token issued between password login and the
// 2FA code check.
type Challenge struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expiresAt"`
}

// User is a sync account. Zero-knowledge design: only an scrypt hash of
// the password is stored, never the password itself.
type User struct {
	Email          string            `json:"email"`
	Salt           string            `json:"salt"`
	Hash           string            `json:"hash"`
	CreatedAt      string            `json:"createdAt"`
	EmailVerified  *bool             `json:"emailVerified"`
	VerifyCode     *VerifyCode       `json:"verifyCode,omitempty"`
	LastVerifySent string            `json:"lastVerifySentAt,omitempty"`
	Sessions       map[string]string `json:"sessions"`
	TotpSecret     string            `json:"totpSecret,omitempty"`
	TotpPending    *TotpPending      `json:"totpPending,omitempty"`
	Challenge      *Challenge        `json:"challenge,omitempty"`
	IsAdmin        bool              `json:"isAdmin,omitempty"`
}

// Blob is one encrypted snapshot, per account or per workspace.
type Blob struct {
	Revision  int     `json:"revision"`
	Blob      *string `json:"blob"`
	UpdatedAt *string `json:"updatedAt"`
}

// UserKey is an account's public key plus its private key wrapped by the
// account password; the server never sees the unwrapped key.
type UserKey struct {
	UserID            string `json:"userId"`
	PublicKey         string `json:"publicKey"`
	WrappedPrivateKey string `json:"wrappedPrivateKey"`
}

// TeamMember is one membership entry of a workspace.
type TeamMember struct {
	UserID     string `json:"userId"`
	Email      string `json:"email"`
	Role       string `json:"role"`
	WrappedKey string `json:"wrappedKey"`
	JoinedAt   string `json:"joinedAt"`
}

// Team is a shared workspace: one encrypted blob plus per-member
// key-wrappings for the workspace key.
type Team struct {
	ID         string       `json:"id"`
	Name       string       `json:"name"`
	CreatedBy  string       `json:"createdBy"`
	CreatedAt  string       `json:"createdAt"`
	Members    []TeamMember `json:"members"`
	KeyVersion int          `json:"keyVersion"`
}

// AuditEvent is one append-only audit log entry for a workspace.
type AuditEvent struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspaceId"`
	ActorID     string `json:"actorId"`
	Action      string `json:"action"`
	Target      string `json:"target"`
	Revision    int    `json:"revision"`
	IP          string `json:"ip"`
	Source      string `json:"source"`
	CreatedAt   string `json:"createdAt"`
}

// AuditQuery filters AuditEvents.
type AuditQuery struct {
	Actor  string
	Action string
	Limit  int
	Offset int
}
