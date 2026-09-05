// Package httpx holds the small HTTP request/response helpers shared by
// every handler package.
package httpx

import (
	"encoding/json"
	"net/http"

	"connexia/syncserver/internal/config"
)

// SendJSON writes a JSON response with permissive CORS headers.
func SendJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// SendError writes a JSON error response.
func SendError(w http.ResponseWriter, status int, message string) {
	SendJSON(w, status, map[string]string{"error": message})
}

// ReadJSON decodes the request body into out, replying with a 400 on
// invalid input. It reports whether decoding succeeded.
func ReadJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	if r.ContentLength > config.MaxBodyBytes {
		SendError(w, 400, "invalid body")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, config.MaxBodyBytes))
	if err := dec.Decode(out); err != nil {
		SendError(w, 400, "invalid JSON")
		return false
	}
	return true
}
