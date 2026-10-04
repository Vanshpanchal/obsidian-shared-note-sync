#!/usr/bin/env bash
# Acceptance tests against a deployed shared-api function.
#
#   SHARED_URL=https://<function-domain> SHARED_API_KEY=... ./backend/scripts/acceptance.sh
#
# WARNING: this writes to the live shared document. It saves the current content
# first and restores it (force) at the end.
set -euo pipefail

# Load backend/.env if present.
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${SHARED_URL:?set SHARED_URL (function domain, no trailing /shared)}"
: "${SHARED_API_KEY:?set SHARED_API_KEY}"
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

URL="${SHARED_URL%/}/shared"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi
}
req() { # method [extra curl args...] -> prints status, body in $TMP/body
  local m=$1; shift
  curl -sS -o "$TMP/body" -w '%{http_code}' -X "$m" -H "x-api-key: $SHARED_API_KEY" -H 'content-type: application/json' "$@"
}

# 1. GET returns a document
s=$(req GET "$URL"); check "GET returns 200" 200 "$s"
cp "$TMP/body" "$TMP/original.json"
v=$(jq -r .version "$TMP/body")
echo "      current version: $v"

# 2. POST with correct baseVersion -> 200, version+1
jq -n --argjson v "$v" '{content:"acceptance test\r\nline 2 ✓ નમસ્તે हिंदी 🙏", baseVersion:$v, deviceId:"curl"}' > "$TMP/post.json"
s=$(req POST "$URL" --data-binary @"$TMP/post.json"); check "POST correct base -> 200" 200 "$s"
check "version incremented" $((v+1)) "$(jq -r .version "$TMP/body")"
req GET "$URL" >/dev/null
check "CRLF normalized, unicode intact" "$(printf 'acceptance test\nline 2 ✓ નમસ્તે हिंदी 🙏')" "$(jq -r .content "$TMP/body")"

# 3. Stale baseVersion -> 409 with server state
s=$(req POST "$URL" --data-binary @"$TMP/post.json"); check "POST stale base -> 409" 409 "$s"
check "409 body has server version" $((v+1)) "$(jq -r .version "$TMP/body")"

# 4. Wrong key -> 401
s=$(curl -sS -o /dev/null -w '%{http_code}' -H 'x-api-key: wrong' "$URL"); check "wrong key -> 401" 401 "$s"
s=$(curl -sS -o /dev/null -w '%{http_code}' "$URL"); check "missing key -> 401" 401 "$s"

# 5. 2 MB body rejected
head -c 2097152 /dev/zero | tr '\0' 'x' > "$TMP/big.txt"
jq -n --rawfile c "$TMP/big.txt" --argjson v $((v+1)) '{content:$c, baseVersion:$v}' > "$TMP/big.json"
s=$(req POST "$URL" --data-binary @"$TMP/big.json" || true)
if [[ "$s" =~ ^4 ]]; then check "2 MB body rejected (4xx)" ok ok; else check "2 MB body rejected (4xx)" 4xx "$s"; fi

# Restore original content
jq '{content, baseVersion:0, deviceId:"curl-restore"}' "$TMP/original.json" > "$TMP/restore.json"
s=$(req POST "$URL?force=true" --data-binary @"$TMP/restore.json"); check "restore original (force)" 200 "$s"

# ---------------------------------------------------------------- attachments
# Uploads throw-away files named acceptance-*.bin and deletes them afterwards.
# This is also how you find out what size your deployment really accepts: if the
# 2 MB or 9 MB round trip fails, lower ASSET_MAX_BYTES (function variable and bucket).
BASE="${SHARED_URL%/}/assets"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
areq() { # method path-suffix [curl args...] -> status; body in $TMP/body
  local m=$1 suffix=$2; shift 2
  curl -sS -o "$TMP/body" -w '%{http_code}' -X "$m" -H "x-api-key: $SHARED_API_KEY" "$BASE$suffix" "$@"
}

s=$(areq GET ""); check "GET /assets -> 200" 200 "$s"
max=$(jq -r .maxBytes "$TMP/body"); echo "      server max attachment size: $max bytes"
s=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE"); check "assets: missing key -> 401" 401 "$s"

roundtrip() { # size-in-bytes label
  local size=$1 name="acceptance-$2.bin"
  head -c "$size" /dev/urandom > "$TMP/up.bin"
  s=$(areq POST "/file?name=$name&overwrite=true" -H 'content-type: application/octet-stream' --data-binary @"$TMP/up.bin")
  check "upload $2 ($size bytes) -> 200/201" ok "$([[ $s == 200 || $s == 201 ]] && echo ok || echo "$s")"
  s=$(areq GET "/file?name=$name" -o "$TMP/down.bin"); check "download $2 -> 200" 200 "$s"
  check "round trip $2: identical bytes" "$(sha "$TMP/up.bin")" "$(sha "$TMP/down.bin")"
}
roundtrip 1024 1kb
roundtrip 2097152 2mb
if (( max >= 9437184 )); then roundtrip 9437184 9mb; fi

# Duplicate without overwrite -> 409; delete -> 200; gone -> 404
head -c 64 /dev/urandom > "$TMP/dup.bin"
s=$(areq POST "/file?name=acceptance-1kb.bin" --data-binary @"$TMP/dup.bin"); check "duplicate upload -> 409" 409 "$s"
s=$(areq POST "/file?name=a%2Fb.bin" --data-binary @"$TMP/dup.bin"); check "name with slash -> 400" 400 "$s"
head -c $((max + 1)) /dev/zero > "$TMP/over.bin"
s=$(areq POST "/file?name=acceptance-over.bin" --data-binary @"$TMP/over.bin" || true)
check "over the size limit -> 4xx" ok "$([[ $s =~ ^4 ]] && echo ok || echo "$s")"
for n in 1kb 2mb 9mb; do
  areq DELETE "/file?name=acceptance-$n.bin" >/dev/null || true
done
s=$(areq GET "/file?name=acceptance-1kb.bin"); check "deleted file -> 404" 404 "$s"

echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
