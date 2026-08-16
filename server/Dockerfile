# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/syncserver .

FROM alpine:3.21
RUN adduser -D -u 10001 syncserver
WORKDIR /app
COPY --from=build /out/syncserver /app/syncserver
RUN mkdir -p /data && chown syncserver:syncserver /data
USER syncserver
EXPOSE 8047
ENV PORT=8047 \
    DATA_DIR=/data
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8047/api/health || exit 1
CMD ["/app/syncserver"]
