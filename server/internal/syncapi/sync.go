// Package syncapi implements the per-account encrypted snapshot endpoints
// (GET/POST /api/sync with optimistic revision checking).
package syncapi

import (
	"encoding/base64"
	"log"
	"net/http"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/httpx"
	"connexia/syncserver/internal/model"
	"connexia/syncserver/internal/state"
)

func HandleGet(w http.ResponseWriter, r *http.Request, userId string) {
	state.St.Mu.RLock()
	b := state.St.Blobs[userId]
	state.St.Mu.RUnlock()
	if b == nil {
		b = &model.Blob{Revision: 0}
	}
	httpx.SendJSON(w, 200, map[string]any{
		"revision":  b.Revision,
		"blob":      b.Blob,
		"updatedAt": b.UpdatedAt,
	})
}

func HandlePost(w http.ResponseWriter, r *http.Request, userId string) {
	var body struct {
		Revision int    `json:"revision"`
		Blob     string `json:"blob"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if body.Revision < 0 {
		httpx.SendError(w, 400, "invalid revision")
		return
	}
	// Approximate decoded byte size like Node's Buffer.byteLength(blob, 'base64').
	decodedLen := base64.StdEncoding.DecodedLen(len(body.Blob))
	if decodedLen > config.BlobLimitBytes {
		httpx.SendError(w, 413, "blob too large")
		return
	}

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	current := state.St.Blobs[userId]
	if current == nil {
		current = &model.Blob{Revision: 0}
	}
	if body.Revision != current.Revision {
		httpx.SendError(w, 409, "revision conflict")
		return
	}
	blobStr := body.Blob
	ts := cryptoutil.NowISO()
	next := &model.Blob{Revision: current.Revision + 1, Blob: &blobStr, UpdatedAt: &ts}
	state.St.Blobs[userId] = next
	state.PersistBlobID(userId)
	log.Printf("[%s] sync %s -> revision %d", cryptoutil.NowISO(), state.St.Users[userId].Email, next.Revision)
	httpx.SendJSON(w, 200, map[string]any{"revision": next.Revision})
}
