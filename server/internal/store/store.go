// Package store persists users, blobs and workspaces. The hot state lives
// in the state package; every mutation is written through a Store. Two
// backends are supported:
//
//   - PostgreSQL when DATABASE_URL is set (via pgx; PgBouncer works
//     transparently — just point DATABASE_URL at the pooler endpoint).
//   - SQLite (pure-Go, no CGO) otherwise, as a file <DATA_DIR>/sync.db.
//
// The schema is deliberately shared between the two backends (TEXT/INTEGER
// columns, the same UPSERT syntax), so queries differ only in placeholder
// style ($1 vs ?).
package store

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

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/model"
)

// Store persists users, blobs and workspaces. Implementations must be safe
// for concurrent use (database/sql handles that for the sql-backed ones).
type Store interface {
	// LoadAll returns every user and blob. The maps must be non-nil even
	// when empty.
	LoadAll() (map[string]*model.User, map[string]*model.Blob, error)
	LoadTeams() (map[string]*model.Team, map[string]*model.Blob, error)
	LoadUserKeys() (map[string]*model.UserKey, error)
	SaveUser(id string, u *model.User) error
	DeleteUser(id string) error
	SaveBlob(id string, b *model.Blob) error
	DeleteBlob(id string) error
	SaveTeam(id string, t *model.Team) error
	DeleteTeam(id string) error
	SaveTeamBlob(id string, b *model.Blob) error
	DeleteTeamBlob(id string) error
	SaveUserKey(id string, uk *model.UserKey) error
	DeleteUserKey(id string) error
	AppendAudit(e *model.AuditEvent) error
	AuditEvents(workspaceID string, q model.AuditQuery) ([]*model.AuditEvent, error)
	GetSetting(key string) (string, bool, error)
	SetSetting(key, value string) error
	HasAdmin() (bool, error)
	CountUsers() (int, error)
	Close() error
}

// DB is the active backend, set by Open() in main().
var DB Store

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
	CREATE TABLE IF NOT EXISTS user_keys (
		user_id             TEXT PRIMARY KEY,
		public_key          TEXT NOT NULL,
		wrapped_private_key TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS teams (
		id          TEXT PRIMARY KEY,
		name        TEXT NOT NULL,
		created_by  TEXT NOT NULL,
		created_at  TEXT NOT NULL,
		members     TEXT NOT NULL,
		key_version INTEGER NOT NULL DEFAULT 1
	);
	CREATE TABLE IF NOT EXISTS team_blobs (
		id          TEXT PRIMARY KEY,
		revision    INTEGER NOT NULL DEFAULT 0,
		blob_data   TEXT NOT NULL,
		updated_at  TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS audit_events (
		id           TEXT PRIMARY KEY,
		workspace_id TEXT NOT NULL,
		actor_id     TEXT NOT NULL,
		action       TEXT NOT NULL,
		target       TEXT NOT NULL,
		revision     INTEGER NOT NULL DEFAULT 0,
		ip           TEXT NOT NULL,
		source       TEXT NOT NULL,
		created_at   TEXT NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
	CREATE INDEX IF NOT EXISTS idx_audit_workspace ON audit_events(workspace_id, created_at);`
)

// Open picks the backend from the environment. DATABASE_URL set =>
// PostgreSQL, otherwise SQLite in DATA_DIR.
func Open() (Store, error) {
	if dbURL := config.EnvStr("DATABASE_URL", ""); dbURL != "" {
		return openSQLStore(pgDriver, dbURL)
	}
	dbPath := filepath.Join(config.DataDir, "sync.db")
	if err := os.MkdirAll(config.DataDir, 0o755); err != nil {
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

func (s *sqlStore) SaveUser(id string, u *model.User) error {
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

func (s *sqlStore) SaveBlob(id string, b *model.Blob) error {
	if b == nil {
		b = &model.Blob{Revision: 0}
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

func (s *sqlStore) SaveTeam(id string, t *model.Team) error {
	if t == nil {
		return fmt.Errorf("nil team")
	}
	members, _ := json.Marshal(t.Members)
	query := "INSERT INTO teams (id, name, created_by, created_at, members, key_version) VALUES (" +
		s.ph(1) + ", " + s.ph(2) + ", " + s.ph(3) + ", " + s.ph(4) + ", " + s.ph(5) + ", " + s.ph(6) +
		") ON CONFLICT (id) DO UPDATE SET name = excluded.name, created_by = excluded.created_by, " +
		"created_at = excluded.created_at, members = excluded.members, key_version = excluded.key_version"
	_, err := s.db.Exec(query, id, t.Name, t.CreatedBy, t.CreatedAt, string(members), t.KeyVersion)
	return err
}

func (s *sqlStore) DeleteTeam(id string) error {
	_, err := s.db.Exec("DELETE FROM teams WHERE id = "+s.ph(1), id)
	return err
}

func (s *sqlStore) SaveTeamBlob(id string, b *model.Blob) error {
	if b == nil {
		b = &model.Blob{Revision: 0}
	}
	blobData := ""
	if b.Blob != nil {
		blobData = *b.Blob
	}
	updatedAt := ""
	if b.UpdatedAt != nil {
		updatedAt = *b.UpdatedAt
	}
	query := "INSERT INTO team_blobs (id, revision, blob_data, updated_at) VALUES (" +
		s.ph(1) + ", " + s.ph(2) + ", " + s.ph(3) + ", " + s.ph(4) +
		") ON CONFLICT (id) DO UPDATE SET revision = excluded.revision" +
		", blob_data = excluded.blob_data, updated_at = excluded.updated_at"
	_, err := s.db.Exec(query, id, b.Revision, blobData, updatedAt)
	return err
}

func (s *sqlStore) DeleteTeamBlob(id string) error {
	_, err := s.db.Exec("DELETE FROM team_blobs WHERE id = "+s.ph(1), id)
	return err
}

func (s *sqlStore) SaveUserKey(id string, uk *model.UserKey) error {
	if uk == nil {
		return fmt.Errorf("nil userKey")
	}
	query := "INSERT INTO user_keys (user_id, public_key, wrapped_private_key) VALUES (" +
		s.ph(1) + ", " + s.ph(2) + ", " + s.ph(3) +
		") ON CONFLICT (user_id) DO UPDATE SET public_key = excluded.public_key, wrapped_private_key = excluded.wrapped_private_key"
	_, err := s.db.Exec(query, id, uk.PublicKey, uk.WrappedPrivateKey)
	return err
}

func (s *sqlStore) DeleteUserKey(id string) error {
	_, err := s.db.Exec("DELETE FROM user_keys WHERE user_id = "+s.ph(1), id)
	return err
}

func (s *sqlStore) AppendAudit(e *model.AuditEvent) error {
	if e == nil {
		return fmt.Errorf("nil auditEvent")
	}
	query := "INSERT INTO audit_events (id, workspace_id, actor_id, action, target, revision, ip, source, created_at) VALUES (" +
		s.ph(1) + ", " + s.ph(2) + ", " + s.ph(3) + ", " + s.ph(4) + ", " + s.ph(5) + ", " + s.ph(6) + ", " + s.ph(7) + ", " + s.ph(8) + ", " + s.ph(9) + ")"
	_, err := s.db.Exec(query, e.ID, e.WorkspaceID, e.ActorID, e.Action, e.Target, e.Revision, e.IP, e.Source, e.CreatedAt)
	return err
}

func (s *sqlStore) AuditEvents(workspaceID string, q model.AuditQuery) ([]*model.AuditEvent, error) {
	conds := []string{"workspace_id = " + s.ph(1)}
	args := []any{workspaceID}
	if q.Actor != "" {
		args = append(args, q.Actor)
		conds = append(conds, "actor_id = "+s.ph(len(args)))
	}
	if q.Action != "" {
		args = append(args, q.Action)
		conds = append(conds, "action = "+s.ph(len(args)))
	}
	query := "SELECT id, workspace_id, actor_id, action, target, revision, ip, source, created_at FROM audit_events WHERE " +
		strings.Join(conds, " AND ") + " ORDER BY created_at DESC, id DESC"
	if q.Limit > 0 {
		args = append(args, q.Limit)
		query += " LIMIT " + s.ph(len(args))
	} else {
		args = append(args, 100)
		query += " LIMIT " + s.ph(len(args))
	}
	if q.Offset > 0 {
		args = append(args, q.Offset)
		query += " OFFSET " + s.ph(len(args))
	}
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []*model.AuditEvent
	for rows.Next() {
		e := &model.AuditEvent{}
		if err := rows.Scan(&e.ID, &e.WorkspaceID, &e.ActorID, &e.Action, &e.Target, &e.Revision, &e.IP, &e.Source, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
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

func (s *sqlStore) LoadAll() (map[string]*model.User, map[string]*model.Blob, error) {
	users := map[string]*model.User{}
	blobs := map[string]*model.Blob{}

	rows, err := s.db.Query("SELECT id, email, salt, hash, created_at, email_verified, " +
		"verify_code, last_verify_sent, sessions, totp_secret, totp_pending, challenge, is_admin FROM users")
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id string
		u := &model.User{Sessions: map[string]string{}}
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
		b := &model.Blob{Revision: rev}
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

func (s *sqlStore) LoadTeams() (map[string]*model.Team, map[string]*model.Blob, error) {
	teams := map[string]*model.Team{}
	blobs := map[string]*model.Blob{}

	rows, err := s.db.Query("SELECT id, name, created_by, created_at, members, key_version FROM teams")
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id, name, createdBy, createdAt, members string
		var kv int
		if err := rows.Scan(&id, &name, &createdBy, &createdAt, &members, &kv); err != nil {
			rows.Close()
			return nil, nil, err
		}
		t := &model.Team{ID: id, Name: name, CreatedBy: createdBy, CreatedAt: createdAt, KeyVersion: kv}
		_ = json.Unmarshal([]byte(members), &t.Members)
		if t.Members == nil {
			t.Members = []model.TeamMember{}
		}
		teams[id] = t
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, nil, err
	}
	rows.Close()

	brows, err := s.db.Query("SELECT id, revision, blob_data, updated_at FROM team_blobs")
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
		b := &model.Blob{Revision: rev}
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
	return teams, blobs, nil
}

func (s *sqlStore) LoadUserKeys() (map[string]*model.UserKey, error) {
	keys := map[string]*model.UserKey{}
	rows, err := s.db.Query("SELECT user_id, public_key, wrapped_private_key FROM user_keys")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		uk := &model.UserKey{}
		if err := rows.Scan(&uk.UserID, &uk.PublicKey, &uk.WrappedPrivateKey); err != nil {
			return nil, err
		}
		keys[uk.UserID] = uk
	}
	return keys, rows.Err()
}

func (s *sqlStore) CountUsers() (int, error) {
	var n int
	err := s.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&n)
	return n, err
}

func (s *sqlStore) Close() error { return s.db.Close() }

// BackendName reports which backend is active (for logs).
func BackendName() string {
	if ss, ok := DB.(*sqlStore); ok {
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

// MigrateFromJSON imports a legacy <DATA_DIR>/users.json + blobs/ directory
// into the store on first boot (only when the database is empty). The JSON
// files are left untouched as a backup.
func MigrateFromJSON(s Store, usersFile, blobsDir string) {
	n, err := s.CountUsers()
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
	var users map[string]*model.User
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
		if err := s.SaveUser(id, u); err != nil {
			log.Printf("migration: saving user %s: %v", id, err)
			continue
		}
		b := &model.Blob{Revision: 0}
		if raw, err := os.ReadFile(filepath.Join(blobsDir, id+".json")); err == nil {
			_ = json.Unmarshal(raw, b)
		}
		if err := s.SaveBlob(id, b); err != nil {
			log.Printf("migration: saving blob %s: %v", id, err)
		}
		migrated++
	}
	log.Printf("migrated %d account(s) from JSON to database", migrated)
}
