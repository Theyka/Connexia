#!/bin/sh
set -e
cd "$(dirname "$0")/.."
out=internal/web/static/wasm
GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o "$out/ssh.wasm" ./webssh
gzip -9 -n -f "$out/ssh.wasm"
cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$out/wasm_exec.js"
ls -l "$out"
