#!/bin/sh
# Smoke test for the Docker image, no KX needed (mock data, throwaway container and volume).
#   sh scripts/docker-smoke.sh            builds the image first, then tests it
#   SKIP_BUILD=1 sh scripts/docker-smoke.sh
set -eu
cd "$(dirname "$0")/.."
NAME=kx-smoke; VOL=kx-smoke-data; PORT=${SMOKE_PORT:-3699}; B=http://127.0.0.1:$PORT; J='Content-Type: application/json'
PW='a long enough password'; CODE=smoke-setup-code
BODY="{\"username\":\"smoke\",\"password\":\"$PW\"}"
BODY_WITH_CODE="{\"username\":\"smoke\",\"password\":\"$PW\",\"token\":\"$CODE\"}"
fail() { echo "FAIL: $1"; docker logs "$NAME" 2>&1 | tail -15; cleanup; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
ok() { echo "ok   $1"; }
healthy() { i=0; while [ $i -lt 30 ]; do [ "$(docker inspect --format '{{.State.Health.Status}}' "$NAME")" = healthy ] && return 0; i=$((i+1)); sleep 2; done; return 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

[ "${SKIP_BUILD:-}" = 1 ] || docker build -q -t kx-console:latest . >/dev/null
cleanup
docker run -d --name "$NAME" -p 127.0.0.1:$PORT:3000 -e KX_MOCK=1 -e KX_SETUP_TOKEN=$CODE -v $VOL:/data kx-console:latest >/dev/null
healthy || fail "the container did not become healthy"; ok "starts and reports healthy"

[ "$(docker exec "$NAME" id -u)" != 0 ] || fail "runs as root"; ok "runs as an unprivileged user"
docker exec "$NAME" sh -c 'ls -A /app /app/public/native | grep -E "^(\.env|\.kx-|selftest|probe|input-check|hkc-capture)" ' && fail "secrets or developer tools in the image"; ok "no secrets or developer tools in the image"
r=$(code -H 'Accept: text/html' $B/); [ "$r" = 302 ] || fail "first launch should redirect to setup (got $r)"; ok "first launch goes to the setup page"
r=$(code -X POST -H "$J" -d "$BODY" $B/api/setup); [ "$r" = 403 ] || fail "setup without the code must be refused (got $r)"; ok "setup without the code is refused"
r=$(code -X POST -H "$J" -d "$BODY_WITH_CODE" $B/api/setup); [ "$r" = 200 ] || fail "setup with the code must work (got $r)"; ok "setup with the code creates the administrator"
docker exec "$NAME" sh -c 'test "$(stat -c %a /data/users.json)" = 600 && test "$(stat -c %U /data/users.json)" = node' || fail "accounts file must be owner-only"; ok "accounts are stored in the volume, owner-only"
docker restart "$NAME" >/dev/null; healthy || fail "no health after restart"
r=$(code -X POST -H "$J" -d "$BODY" $B/api/login); [ "$r" = 200 ] || fail "the account must survive a restart (got $r)"; ok "the account survives a restart"
docker exec "$NAME" node auth-cli.js reset smoke | grep -q 'Temporary password' || fail "CLI recovery"; ok "password recovery works through docker exec"
docker stop "$NAME" >/dev/null; [ "$(docker inspect --format '{{.State.ExitCode}}' "$NAME")" = 0 ] || fail "a stop should exit with code 0"; ok "stops cleanly (exit code 0)"
cleanup; echo "All Docker smoke checks passed."
