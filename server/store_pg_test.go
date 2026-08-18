//go:build pgtest

// Integration test for the PostgreSQL storage backend. Excluded from normal
// builds/tests (use -tags pgtest). Spins up a real embedded PostgreSQL,
// downloads its binaries on first run.
package main

import (
	"os"
	"path/filepath"
	"testing"

	embeddedpostgres "github.com/fergusstrange/embedded-postgres"
)

func TestPostgresStore(t *testing.T) {
	port := uint32(15432)
	root := filepath.Join(os.TempDir(), "connexia-embedded-pg", "data")
	rt := filepath.Join(os.TempDir(), "connexia-embedded-pg", "runtime")
	for _, p := range []string{root, rt} {
		if err := os.RemoveAll(p); err != nil {
			t.Fatal(err)
		}
	}

	pg := embeddedpostgres.NewDatabase(embeddedpostgres.DefaultConfig().
		Port(port).
		DataPath(root).
		RuntimePath(rt))
	if err := pg.Start(); err != nil {
		t.Fatalf("start embedded postgres: %v", err)
	}
	defer func() {
		if err := pg.Stop(); err != nil {
			t.Logf("stop embedded postgres: %v", err)
		}
	}()

	dsn := "postgres://postgres:postgres@127.0.0.1:15432/postgres?sslmode=disable"
	os.Setenv("DATABASE_URL", dsn)
	st2, err := openStore()
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	defer st2.Close()
	store = st2
	if storeBackendName() != "PostgreSQL" {
		t.Fatalf("expected PostgreSQL backend, got %q", storeBackendName())
	}

	// Empty database.
	if n, _ := st2.CountUsers(); n != 0 {
		t.Fatalf("expected 0 users, got %d", n)
	}

	// First user becomes admin.
	admin := &user{
		Email: "admin@pg.dev", Salt: "aa", Hash: "bb", CreatedAt: "2026-01-01T00:00:00Z",
		EmailVerified: boolPtr(true), Sessions: map[string]string{"tok": "2027-01-01T00:00:00Z"},
		IsAdmin:       true,
	}
	if err := st2.SaveUser("u1", admin); err != nil {
		t.Fatalf("SaveUser admin: %v", err)
	}
	if ok, _ := st2.HasAdmin(); !ok {
		t.Fatal("expected admin to exist")
	}

	// Second user is not admin.
	u2 := &user{
		Email: "user@pg.dev", Salt: "cc", Hash: "dd", CreatedAt: "2026-02-01T00:00:00Z",
		EmailVerified: boolPtr(false), Sessions: map[string]string{},
	}
	if err := st2.SaveUser("u2", u2); err != nil {
		t.Fatalf("SaveUser u2: %v", err)
	}
	if n, _ := st2.CountUsers(); n != 2 {
		t.Fatalf("expected 2 users, got %d", n)
	}

	// Blob upsert.
	blobStr := "cG9zdGdyZXM="
	ts := "2026-03-01T00:00:00Z"
	if err := st2.SaveBlob("u1", &blob{Revision: 1, Blob: &blobStr, UpdatedAt: &ts}); err != nil {
		t.Fatalf("SaveBlob: %v", err)
	}
	if err := st2.SaveBlob("u1", &blob{Revision: 2, Blob: &blobStr, UpdatedAt: &ts}); err != nil {
		t.Fatalf("SaveBlob upsert: %v", err)
	}

	// LoadAll reflects everything, including the nested fields.
	users, blobs, err := st2.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	a := users["u1"]
	if a == nil || !a.IsAdmin || a.Email != "admin@pg.dev" || a.Sessions["tok"] == "" {
		t.Fatalf("unexpected admin user loaded: %+v", a)
	}
	if b := users["u2"]; b == nil || b.IsAdmin {
		t.Fatalf("unexpected u2: %+v", b)
	}
	if bl := blobs["u1"]; bl == nil || bl.Revision != 2 || bl.Blob == nil || *bl.Blob != blobStr {
		t.Fatalf("unexpected blob loaded: %+v", bl)
	}

	// Delete.
	if err := st2.DeleteUser("u2"); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}
	if err := st2.DeleteBlob("u1"); err != nil {
		t.Fatalf("DeleteBlob: %v", err)
	}
	if n, _ := st2.CountUsers(); n != 1 {
		t.Fatalf("expected 1 user after delete, got %d", n)
	}
	_, blobs2, err := st2.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll after delete: %v", err)
	}
	if _, ok := blobs2["u1"]; ok {
		t.Fatal("expected blob deleted")
	}
}

func boolPtr(b bool) *bool { return &b }
