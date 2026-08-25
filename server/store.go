// Storage abstraction.
//
// The server keeps its "hot" state in memory (state struct in main.go) and
// persists every mutation through a Store. Two backends are supported:
//
//   - PostgreSQL when DATABASE_URL is set (via pgx; PgBouncer works
//     transparently — just point DATABASE_URL at the pooler endpoint).
//   - SQLite (pure-Go, no CGO) otherwise, as a file <DATA_DIR>/sync.db.
//
// The schema is deliberately shared between the two backends (TEXT/INTEGER
// columns, the same UPSERT syntax), so queries differ only in placeholder
// style ($1 vs ?).

package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib"
	_ "modernc.org/sqlite"
)

// Store persists users and blobs. Implementations must be safe for
// concurrent use (database/sql handles that for the sql-backed ones).
type Store interface {
	// LoadAll returns every user and blob. The maps must be non-nil even
	// when empty.
	LoadAll() (map[string]*user, map[string]*blob, error)
	SaveUser(id string, u *user) error
	DeleteUser(id string) error
	SaveBlob(id string, b *blob) error
	DeleteBlob(id string) error
	GetSetting(key string) (string, bool, error)
	SetSetting(key, value string) error
	HasAdmin() (bool, error)
	CountUsers() (int, error)
	Close() error
}

// store is the active backend, set in main().
var store Store

const (
	pgDriver   = "pgx"
	sqliteDrv  = "sqlite"
	usersTable = `CREATE TABLE IF NOT EXISTS users (
		id              TEXT PRIMARY KEY,
		email           TEXT NOT NULL,
		salt            TEXT NOT NULL,
		hash            TEXT NOT NULL,
		created_at      TEXT NOT NULL,
		email_verified  INTEGER NOT NULL DEFAULT 0,
		verify_code     TEXT NOT NULL,
		last_verify_sent TEXT NOT NULL,
		sessions        TEXT NOT NULL,
		totp_secret     TEXT NOT NULL,
		totp_pending    TEXT NOT NULL,
		challenge       TEXT NOT NULL,
		is_admin        INTEGER NOT NULL DEFAULT 0
	);
	CREATE TABLE IF NOT EXISTS blobs (
		id          TEXT PRIMARY KEY,
		revision    INTEGER NOT NULL DEFAULT 0,
		blob_data   TEXT NOT NULL,
		updated_at  TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS settings (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);`
)

// openStore picks the backend from the environment. DATABASE_URL set =>
// PostgreSQL, otherwise SQLite in DATA_DIR.
func openStore() (Store, error) {
	if dbURL := envStr("DATABASE_URL", ""); dbURL != "" {
		return openSQLStore(pgDriver, dbURL)
	}
	dbPath := filepath.Join(dataDir, "sync.db")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	// WAL + busy timeout avoid "database is locked" under concurrent access.
	dsn := "file:" + dbPath + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"
	return openSQLStore(sqliteDrv, dsn)
}

func openSQLStore(driver, dsn string) (Store, error) {
	db, err := sql.Open(driver, dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", driver, err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(10)
	// SQLite writes are serialized by the app lock anyway; a single
	// connection sidesteps any residual "database is locked" edge cases.
	if driver == sqliteDrv {
		db.SetMaxOpenConns(1)
	}
	s := &sqlStore{db: db, driver: driver}
	if err := s.init(); err != nil {
		db.Close()
		return nil, fmt.Errorf("init %s schema: %w", driver, err)
	}
	return s, nil
}

type sqlStore struct {
	db     *sql.DB
	driver string
}

func (s *sqlStore) init() error {
	_, err := s.db.Exec(usersTable)
	return err
}

// ph returns the i-th (1-based) positional placeholder for this driver.
func (s *sqlStore) ph(i int) string {
	if s.driver == pgDriver {
		return fmt.Sprintf("$%d", i)
	}
	return "?"
}

// excludedClause builds "col = excluded.col, ..." for an UPSERT. Both
// SQLite and PostgreSQL support referencing the proposed insert row as
// `excluded.<col>`, so no extra bound arguments are needed.
func (s *sqlStore) excludedClause(cols []string) string {
	parts := make([]string, len(cols))
	for i, c := range cols {
		parts[i] = c + " = excluded." + c
	}
	return strings.Join(parts, ", ")
}

var userCols = []string{
	"email", "salt", "hash", "created_at", "email_verified",
	"verify_code", "last_verify_sent", "sessions", "totp_secret",
	"totp_pending", "challenge", "is_admin",
}

func (s *sqlStore) SaveUser(id string, u *user) error {
	if u == nil {
		return fmt.Errorf("nil user")
	}
	vc, _ := json.Marshal(u.VerifyCode)
	tp, _ := json.Marshal(u.TotpPending)
	ch, _ := json.Marshal(u.Challenge)
	sess, _ := json.Marshal(u.Sessions)
	verified := u.EmailVerified != nil && *u.EmailVerified

	query := "INSERT INTO users (id, " + strings.Join(userCols, ", ") +
		") VALUES (" + s.ph(1)
	for i := 2; i <= len(userCols)+1; i++ {
		query += ", " + s.ph(i)
	}
	query += ") ON CONFLICT (id) DO UPDATE SET " + s.excludedClause(userCols)

	args := []any{
		id, u.Email, u.Salt, u.Hash, u.CreatedAt, b2i(verified),
		vc, u.LastVerifySent, sess, u.TotpSecret, tp, ch, b2i(u.IsAdmin),
	}
	_, err := s.db.Exec(query, args...)
	return err
}

func (s *sqlStore) DeleteUser(id string) error {
	_, err := s.db.Exec("DELETE FROM users WHERE id = "+s.ph(1), id)
	return err
}

func (s *sqlStore) SaveBlob(id string, b *blob) error {
	if b == nil {
		b = &blob{Revision: 0}
	}
	blobData := ""
	if b.Blob != nil {
		blobData = *b.Blob
	}
	updatedAt := ""
	if b.UpdatedAt != nil {
		updatedAt = *b.UpdatedAt
	}
	query := "INSERT INTO blobs (id, revision, blob_data, updated_at) VALUES (" +
		s.ph(1) + ", " + s.ph(2) + ", " + s.ph(3) + ", " + s.ph(4) +
		") ON CONFLICT (id) DO UPDATE SET revision = excluded.revision" +
		", blob_data = excluded.blob_data, updated_at = excluded.updated_at"
	_, err := s.db.Exec(query, id, b.Revision, blobData, updatedAt)
	return err
}

func (s *sqlStore) DeleteBlob(id string) error {
	_, err := s.db.Exec("DELETE FROM blobs WHERE id = "+s.ph(1), id)
	return err
}

// GetSetting returns the stored value for key, or ok=false when absent.
func (s *sqlStore) GetSetting(key string) (string, bool, error) {
	var v string
	err := s.db.QueryRow("SELECT value FROM settings WHERE key = "+s.ph(1), key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// SetSetting upserts a key/value pair.
func (s *sqlStore) SetSetting(key, value string) error {
	query := "INSERT INTO settings (key, value) VALUES (" + s.ph(1) + ", " + s.ph(2) +
		") ON CONFLICT (key) DO UPDATE SET value = excluded.value"
	_, err := s.db.Exec(query, key, value)
	return err
}

func (s *sqlStore) LoadAll() (map[string]*user, map[string]*blob, error) {
	users := map[string]*user{}
	blobs := map[string]*blob{}

	rows, err := s.db.Query("SELECT id, email, salt, hash, created_at, email_verified, " +
		"verify_code, last_verify_sent, sessions, totp_secret, totp_pending, challenge, is_admin FROM users")
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id string
		u := &user{Sessions: map[string]string{}}
		var ev, adm int
		var vc, lvs, sess, totp, tp, ch string
		if err := rows.Scan(&id, &u.Email, &u.Salt, &u.Hash, &u.CreatedAt, &ev, &vc, &lvs, &sess, &totp, &tp, &ch, &adm); err != nil {
			rows.Close()
			return nil, nil, err
		}
		_ = json.Unmarshal([]byte(vc), &u.VerifyCode)
		_ = json.Unmarshal([]byte(sess), &u.Sessions)
		_ = json.Unmarshal([]byte(tp), &u.TotpPending)
		_ = json.Unmarshal([]byte(ch), &u.Challenge)
		u.LastVerifySent = lvs
		u.TotpSecret = totp
		if ev != 0 {
			v := true
			u.EmailVerified = &v
		}
		u.IsAdmin = adm != 0
		users[id] = u
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, nil, err
	}
	rows.Close()

	brows, err := s.db.Query("SELECT id, revision, blob_data, updated_at FROM blobs")
	if err != nil {
		return nil, nil, err
	}
	for brows.Next() {
		var id, blobData, updatedAt string
		var rev int
		if err := brows.Scan(&id, &rev, &blobData, &updatedAt); err != nil {
			brows.Close()
			return nil, nil, err
		}
		b := &blob{Revision: rev}
		if blobData != "" {
			b.Blob = &blobData
		}
		if updatedAt != "" {
			b.UpdatedAt = &updatedAt
		}
		blobs[id] = b
	}
	if err := brows.Err(); err != nil {
		brows.Close()
		return nil, nil, err
	}
	brows.Close()
	return users, blobs, nil
}

func (s *sqlStore) HasAdmin() (bool, error) {
	var n int
	err := s.db.QueryRow("SELECT COUNT(*) FROM users WHERE is_admin = 1").Scan(&n)
	return n > 0, err
}

func (s *sqlStore) CountUsers() (int, error) {
	var n int
	err := s.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&n)
	return n, err
}

func (s *sqlStore) Close() error { return s.db.Close() }

// storeBackendName reports which backend is active (for logs).
func storeBackendName() string {
	if ss, ok := store.(*sqlStore); ok {
		if ss.driver == pgDriver {
			return "PostgreSQL"
		}
		return "SQLite"
	}
	return "unknown"
}

// b2i converts a bool to an int for storing in an INTEGER column.
func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// migrateFromJSON imports a legacy <DATA_DIR>/users.json + blobs/ directory
// into the store on first boot (only when the database is empty). The JSON
// files are left untouched as a backup.
func migrateFromJSON(store Store) {
	n, err := store.CountUsers()
	if err != nil {
		log.Printf("migration: cannot check database: %v", err)
		return
	}
	if n > 0 {
		return
	}
	raw, err := os.ReadFile(usersFile)
	if err != nil {
		return // fresh install, nothing to migrate
	}
	var users map[string]*user
	if err := json.Unmarshal(raw, &users); err != nil {
		log.Printf("migration: parsing %s: %v", usersFile, err)
		return
	}
	migrated := 0
	for id, u := range users {
		if u == nil {
			continue
		}
		if u.EmailVerified == nil {
			v := true
			u.EmailVerified = &v
		}
		if u.Sessions == nil {
			u.Sessions = map[string]string{}
		}
		if err := store.SaveUser(id, u); err != nil {
			log.Printf("migration: saving user %s: %v", id, err)
			continue
		}
		b := &blob{Revision: 0}
		if raw, err := os.ReadFile(blobFile(id)); err == nil {
			_ = json.Unmarshal(raw, b)
		}
		if err := store.SaveBlob(id, b); err != nil {
			log.Printf("migration: saving blob %s: %v", id, err)
		}
		migrated++
	}
	log.Printf("migrated %d account(s) from JSON to database", migrated)
}
