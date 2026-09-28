#!/usr/bin/env bash
# smoke.sh — quick checks: files, syntax, server boot, API endpoints.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-3461}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== SignPilot AI smoke tests =="

# 1. required files exist
for f in server.js package.json public/index.html public/app.js public/style.css public/templates.js public/vendor/pdf-lib.min.js README.md; do
  [ -f "$DIR/$f" ] && ok "file exists: $f" || bad "missing file: $f"
done

# 2-4. JS syntax
for f in server.js public/app.js public/templates.js; do
  node --check "$DIR/$f" >/dev/null 2>&1 && ok "syntax ok: $f" || bad "syntax error: $f"
done

# start server
export PORT
node "$DIR/server.js" >/tmp/signpilot-smoke.log 2>&1 &
SRV=$!
cleanup() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; }
trap cleanup EXIT
sleep 1
kill -0 $SRV 2>/dev/null || { bad "server process died on boot"; cat /tmp/signpilot-smoke.log; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

BASE="http://localhost:$PORT"

# 5. health
H=$(curl -s "$BASE/api/health")
echo "$H" | grep -q '"ok":true' && ok "GET /api/health ok" || bad "GET /api/health: $H"

# 6. templates list has all 3 templates
T=$(curl -s "$BASE/api/templates")
for t in quote-approval change-order completion; do
  echo "$T" | grep -q "\"id\":\"$t\"" && ok "template listed: $t" || bad "template missing: $t"
done

# 7. create a quote-approval document
D=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"quote-approval","title":"Smith kitchen — approval","fields":{"clientName":"Jane Smith","quoteNumber":"Q-2026-0007","workDescription":"Replace 10 cabinets and install quartz counters","total":8500,"validDays":30}}')
ID=$(echo "$D" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['id'])" 2>/dev/null)
NUM=$(echo "$D" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['number'])" 2>/dev/null)
[ -n "$ID" ] && ok "POST /api/documents created (id=$ID)" || bad "create failed: ${D:0:200}"
echo "$NUM" | grep -qE '^SP-2026-[0-9]{4}$' && ok "doc number format: $NUM" || bad "number bad: $NUM"
echo "$D" | grep -q '"status":"draft"' && ok "new doc starts as draft" || bad "status wrong: ${D:0:200}"

# 8. validation rejects missing required field
V=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"quote-approval","fields":{"quoteNumber":"Q-1"}}')
echo "$V" | grep -q 'Missing required field' && ok "validation rejects missing clientName" || bad "validation weak: ${V:0:200}"

# 9. signing before sent is rejected
SIG="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
S1=$(curl -s -X POST "$BASE/api/documents/$ID/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Jane Smith\",\"signature\":\"$SIG\"}")
echo "$S1" | grep -q 'must be sent before signing' && ok "sign-before-sent rejected" || bad "sign-before-sent allowed: ${S1:0:200}"

# 10. draft -> sent transition
P=$(curl -s -X PATCH "$BASE/api/documents/$ID" -H 'Content-Type: application/json' -d '{"status":"sent"}')
echo "$P" | grep -q '"status":"sent"' && ok "draft -> sent transition" || bad "transition failed: ${P:0:200}"

# 11. client signs; doc stays sent until both sign
S2=$(curl -s -X POST "$BASE/api/documents/$ID/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Jane Smith\",\"signature\":\"$SIG\"}")
echo "$S2" | grep -q '"status":"sent"' && ok "one signature keeps status=sent" || bad "status after 1 sig: ${S2:0:200}"

# 12. contractor signs; doc becomes signed
S3=$(curl -s -X POST "$BASE/api/documents/$ID/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"contractor\",\"name\":\"Alex Contractor\",\"signature\":\"$SIG\"}")
echo "$S3" | grep -q '"status":"signed"' && ok "both signatures -> status=signed" || bad "not signed: ${S3:0:200}"

# 13. audit trail has the full lifecycle
A=$(curl -s "$BASE/api/documents/$ID/audit")
for ev in created sent signed completed; do
  echo "$A" | grep -q "\"event\":\"$ev\"" && ok "audit has event: $ev" || bad "audit missing: $ev"
done

# 14. signed doc is terminal (no more transitions)
P2=$(curl -s -X PATCH "$BASE/api/documents/$ID" -H 'Content-Type: application/json' -d '{"status":"draft"}')
echo "$P2" | grep -q 'invalid transition' && ok "signed doc is terminal" || bad "terminal violated: ${P2:0:200}"

# 15. index page serves with pdf-lib vendored
curl -s "$BASE/" | grep -q 'vendor/pdf-lib.min.js' && ok "index references vendored pdf-lib" || bad "pdf-lib ref missing"
curl -s -o /dev/null -w "%{http_code}" "$BASE/vendor/pdf-lib.min.js" | grep -q '200' && ok "pdf-lib.min.js serves (200)" || bad "pdf-lib 404"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
