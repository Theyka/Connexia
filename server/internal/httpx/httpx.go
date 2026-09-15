package httpx

import (
	"encoding/json"
	"net/http"

	"connexia/syncserver/internal/config"
)

func SendJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func SendError(w http.ResponseWriter, status int, message string) {
	SendJSON(w, status, map[string]string{"error": message})
}

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
