

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="hw3check-$$"
APP_PORT=$((20000 + $$ % 20000))
export APP_PORT

BASE="http:"'//'127.0.0.1:"$APP_PORT"
BODY="$(mktemp)"

COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/compose.yaml")

cleanup() {
    echo "Cleaning up test project..."
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f "$BODY"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "ERROR: $*"
    exit 1
}

get_code() {
    curl -sS -o "$BODY" -w '%{http_code}' \
        --connect-timeout 2 --max-time 4 "$1" || true
}

wait_code() {
    local url="$1"
    local expected="$2"
    local i
    local code

    for i in $(seq 1 45); do
        code="$(get_code "$url")"
        if [ "$code" = "$expected" ]; then
            return 0
        fi
        sleep 1
    done

    echo "Expected HTTP $expected, got $code"
    cat "$BODY" || true
    return 1
}

check_count() {
    local expected="$1"

    if ! grep -Eq "\"count\"[[:space:]]*:[[:space:]]*$expected([,}])" "$BODY"; then
        echo "Expected counter: $expected"
        echo "Actual response:"
        cat "$BODY"
        return 1
    fi
}

echo "1. Starting isolated Compose project..."
"${COMPOSE[@]}" up -d --build

echo "2. Waiting for application..."
wait_code "$BASE/readyz" 200 || fail "Application did not become ready"

echo "3. Checking empty counter..."
code="$(get_code "$BASE/")"
[ "$code" = "200" ] || fail "GET / returned HTTP $code"
check_count 0 || fail "Initial counter is not zero"

echo "4. Incrementing counter three times..."
for expected in 1 2 3; do
    code="$(curl -sS -o "$BODY" -w '%{http_code}' \
        --max-time 4 -X POST "$BASE/increment")"
    [ "$code" = "200" ] || fail "POST returned HTTP $code"
    check_count "$expected" || fail "Incorrect counter after increment"
done

echo "5. Recreating only the app container..."
"${COMPOSE[@]}" up -d --no-deps --force-recreate app
wait_code "$BASE/readyz" 200 || fail "App did not recover after recreation"

code="$(get_code "$BASE/")"
[ "$code" = "200" ] || fail "GET / returned HTTP $code"
check_count 3 || fail "Counter was not preserved after app recreation"

echo "6. Stopping Redis..."
"${COMPOSE[@]}" stop redis

wait_code "$BASE/healthz" 200 || fail "/healthz should return 200"
wait_code "$BASE/readyz" 503 || fail "/readyz should return 503"

code="$(curl -sS -o "$BODY" -w '%{http_code}' \
    --max-time 4 -X POST "$BASE/increment" || true)"
[ "$code" = "503" ] || fail "POST should return 503 when Redis is stopped"

echo "7. Starting Redis again..."
"${COMPOSE[@]}" start redis
wait_code "$BASE/readyz" 200 || fail "Redis did not recover"

code="$(get_code "$BASE/")"
[ "$code" = "200" ] || fail "GET / failed after Redis recovery"
check_count 3 || fail "Counter was not preserved after Redis recovery"

code="$(curl -sS -o "$BODY" -w '%{http_code}' \
    --max-time 4 -X POST "$BASE/increment")"
[ "$code" = "200" ] || fail "POST failed after Redis recovery"
check_count 4 || fail "Counter did not increment to 4"

echo "8. Creating a consistent Redis backup..."
"${COMPOSE[@]}" stop app redis

REDIS_CID="$("${COMPOSE[@]}" ps --all -q redis)"

[ -n "$REDIS_CID" ] || fail "Redis container not found"

VOLUME="$(docker inspect "$REDIS_CID" \
    --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')"

[ -n "$VOLUME" ] || fail "Redis data volume not found"

mkdir -p "$ROOT/backups"
BACKUP_NAME="redis-backup-${PROJECT}.tar.gz"

docker run --rm --entrypoint sh \
    -v "$VOLUME:/data:ro" \
    -v "$ROOT/backups:/backup" \
    redis:7.4-alpine \
    -c "tar czf '/backup/$BACKUP_NAME' -C /data ."

[ -s "$ROOT/backups/$BACKUP_NAME" ] || fail "Backup file is empty"

echo "9. All checks passed!"
echo "Backup: backups/$BACKUP_NAME"
