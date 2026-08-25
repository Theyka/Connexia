package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestTeamStoreSQLite exercises the workspace/team tables on the SQLite
// backend: user keys, teams + team blobs, membership round-trips and the
// append-only audit log.
func TestTeamStoreSQLite(t *testing.T) {
	dir, err := os.MkdirTemp("", "connexia-teamstore")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	dsn := "file:" + filepath.Join(dir, "test.db") + "?_pragma=journal_mode(WAL)"
	s, err := openSQLStore(sqliteDrv, dsn)
	if err != nil {
		t.Fatalf("openSQLStore: %v", err)
	}
	defer s.Close()

	// User keys.
	uk := &userKey{UserID: "u1", PublicKey: "pk-1", WrappedPrivateKey: "wrapped-1"}
	if err := s.SaveUserKey("u1", uk); err != nil {
		t.Fatalf("SaveUserKey: %v", err)
	}
	keys, err := s.LoadUserKeys()
	if err != nil {
		t.Fatalf("LoadUserKeys: %v", err)
	}
	if keys["u1"] == nil || keys["u1"].PublicKey != "pk-1" || keys["u1"].WrappedPrivateKey != "wrapped-1" {
		t.Fatalf("unexpected user key loaded: %+v", keys["u1"])
	}
	if err := s.DeleteUserKey("u1"); err != nil {
		t.Fatalf("DeleteUserKey: %v", err)
	}
	keys, _ = s.LoadUserKeys()
	if _, ok := keys["u1"]; ok {
		t.Fatal("expected user key deleted")
	}

	// Team with members + team blob.
	tm := &team{
		ID: "t1", Name: "ops", CreatedBy: "u1", CreatedAt: "2026-01-01T00:00:00Z",
		Members: []teamMember{{
			UserID: "u1", Email: "admin@pg.dev", Role: "owner",
			WrappedKey: "w-owner", JoinedAt: "2026-01-01T00:00:00Z",
		}},
		KeyVersion: 1,
	}
	if err := s.SaveTeam("t1", tm); err != nil {
		t.Fatalf("SaveTeam: %v", err)
	}
	blobStr := "dGVhbQ=="
	ts := "2026-01-02T00:00:00Z"
	if err := s.SaveTeamBlob("t1", &blob{Revision: 3, Blob: &blobStr, UpdatedAt: &ts}); err != nil {
		t.Fatalf("SaveTeamBlob: %v", err)
	}

	// Add a second member, upsert the team.
	tm.Members = append(tm.Members, teamMember{
		UserID: "u2", Email: "user@pg.dev", Role: "admin",
		WrappedKey: "w-admin", JoinedAt: "2026-01-03T00:00:00Z",
	})
	tm.KeyVersion = 2
	if err := s.SaveTeam("t1", tm); err != nil {
		t.Fatalf("SaveTeam upsert: %v", err)
	}

	teams, blobs, err := s.LoadTeams()
	if err != nil {
		t.Fatalf("LoadTeams: %v", err)
	}
	got := teams["t1"]
	if got == nil || got.Name != "ops" || got.KeyVersion != 2 || len(got.Members) != 2 {
		t.Fatalf("unexpected team loaded: %+v", got)
	}
	if got.Members[0].Role != "owner" || got.Members[1].Role != "admin" {
		t.Fatalf("unexpected members loaded: %+v", got.Members)
	}
	if b := blobs["t1"]; b == nil || b.Revision != 3 || b.Blob == nil || *b.Blob != blobStr {
		t.Fatalf("unexpected team blob loaded: %+v", b)
	}

	// Audit log append + filter.
	if err := s.AppendAudit(&auditEvent{
		ID: "e1", WorkspaceID: "t1", ActorID: "u1", Action: "member.add",
		Target: "u2", Revision: 2, IP: "1.2.3.4", Source: "server",
		CreatedAt: "2026-01-03T00:00:00Z",
	}); err != nil {
		t.Fatalf("AppendAudit: %v", err)
	}
	if err := s.AppendAudit(&auditEvent{
		ID: "e2", WorkspaceID: "t1", ActorID: "u2", Action: "workspace.sync",
		Target: "4", Revision: 4, IP: "5.6.7.8", Source: "server",
		CreatedAt: "2026-01-04T00:00:00Z",
	}); err != nil {
		t.Fatalf("AppendAudit: %v", err)
	}
	all, err := s.AuditEvents("t1", auditQuery{Limit: 10})
	if err != nil {
		t.Fatalf("AuditEvents: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("expected 2 audit events, got %d", len(all))
	}
	// Newest first (created_at DESC).
	if all[0].ID != "e2" || all[1].ID != "e1" {
		t.Fatalf("unexpected audit order: %+v", all)
	}
	filtered, err := s.AuditEvents("t1", auditQuery{Actor: "u1"})
	if err != nil {
		t.Fatalf("AuditEvents (actor filter): %v", err)
	}
	if len(filtered) != 1 || filtered[0].Action != "member.add" {
		t.Fatalf("unexpected filtered audit: %+v", filtered)
	}
	limited, err := s.AuditEvents("t1", auditQuery{Limit: 1, Offset: 1})
	if err != nil {
		t.Fatalf("AuditEvents (limit/offset): %v", err)
	}
	if len(limited) != 1 || limited[0].ID != "e1" {
		t.Fatalf("unexpected paginated audit: %+v", limited)
	}
	// Another workspace must not leak.
	other, err := s.AuditEvents("t2", auditQuery{Limit: 10})
	if err != nil {
		t.Fatalf("AuditEvents (other workspace): %v", err)
	}
	if len(other) != 0 {
		t.Fatalf("expected no audit events for t2, got %d", len(other))
	}

	// Deletes.
	if err := s.DeleteTeam("t1"); err != nil {
		t.Fatalf("DeleteTeam: %v", err)
	}
	if err := s.DeleteTeamBlob("t1"); err != nil {
		t.Fatalf("DeleteTeamBlob: %v", err)
	}
	teams, blobs, err = s.LoadTeams()
	if err != nil {
		t.Fatalf("LoadTeams after delete: %v", err)
	}
	if _, ok := teams["t1"]; ok {
		t.Fatal("expected team deleted")
	}
	if _, ok := blobs["t1"]; ok {
		t.Fatal("expected team blob deleted")
	}
}
