package model

type VerifyCode struct {
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

type TotpPending struct {
	Secret    string `json:"secret"`
	CreatedAt string `json:"createdAt"`
}

type Challenge struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expiresAt"`
}

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

type Blob struct {
	Revision  int     `json:"revision"`
	Blob      *string `json:"blob"`
	UpdatedAt *string `json:"updatedAt"`
}

type UserKey struct {
	UserID            string `json:"userId"`
	PublicKey         string `json:"publicKey"`
	WrappedPrivateKey string `json:"wrappedPrivateKey"`
}

type TeamMember struct {
	UserID     string `json:"userId"`
	Email      string `json:"email"`
	Role       string `json:"role"`
	WrappedKey string `json:"wrappedKey"`
	JoinedAt   string `json:"joinedAt"`
}

type Team struct {
	ID         string       `json:"id"`
	Name       string       `json:"name"`
	CreatedBy  string       `json:"createdBy"`
	CreatedAt  string       `json:"createdAt"`
	Members    []TeamMember `json:"members"`
	KeyVersion int          `json:"keyVersion"`
}

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

type AuditQuery struct {
	Actor  string
	Action string
	Limit  int
	Offset int
}
