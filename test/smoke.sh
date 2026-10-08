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

# 16. CSV export downloads the ledger without signature blobs
curl -s -D /tmp/sp-hdrs.txt "$BASE/api/documents/export.csv" -o /tmp/sp-export.csv
grep -qi 'text/csv' /tmp/sp-hdrs.txt && ok "CSV export content-type is text/csv" || bad "CSV content-type: $(head -1 /tmp/sp-hdrs.txt)"
head -1 /tmp/sp-export.csv | grep -q 'number.*title.*status' && ok "CSV has header row" || bad "CSV header: $(head -1 /tmp/sp-export.csv)"
grep -q "$NUM" /tmp/sp-export.csv && ok "CSV includes created document $NUM" || bad "CSV missing doc $NUM"
grep -q 'data:image' /tmp/sp-export.csv && bad "CSV leaks signature blobs" || ok "CSV omits signature image blobs"

# 17. duplicate creates a fresh draft copy
DUP=$(curl -s -X POST "$BASE/api/documents/$ID/duplicate" -H 'Content-Type: application/json')
DID=$(echo "$DUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['id'])" 2>/dev/null)
DNUM=$(echo "$DUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['number'])" 2>/dev/null)
[ -n "$DID" ] && [ "$DID" != "$ID" ] && ok "duplicate returns new id" || bad "duplicate failed: ${DUP:0:200}"
echo "$DUP" | grep -q '"status":"draft"' && ok "duplicate starts as draft" || bad "duplicate status: ${DUP:0:200}"
echo "$DUP" | grep -q '(copy)' && ok "duplicate title marked (copy)" || bad "dup title: ${DUP:0:120}"
[ "$DNUM" != "$NUM" ] && ok "duplicate gets new number ($DNUM)" || bad "dup number unchanged"

# 18. delete draft succeeds; deleting sent/signed docs is rejected
curl -s -X PATCH "$BASE/api/documents/$DID" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
DN=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","fields":{"clientName":"Temp T","projectRef":"Q-9","workSummary":"wip"}}')
NDID=$(echo "$DN" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['id'])" 2>/dev/null)
DEL_OK=$(curl -s -X DELETE "$BASE/api/documents/$NDID")
echo "$DEL_OK" | grep -q '"ok":true' && ok "delete of draft doc succeeds" || bad "draft delete failed: ${DEL_OK:0:200}"
DEL1=$(curl -s -X DELETE "$BASE/api/documents/$DID")
echo "$DEL1" | grep -q 'only draft documents' && ok "delete of sent doc rejected" || bad "sent doc deleted: ${DEL1:0:200}"
DEL2=$(curl -s -X DELETE "$BASE/api/documents/$ID")
echo "$DEL2" | grep -q 'only draft documents' && ok "delete of signed doc rejected" || bad "signed doc deleted: ${DEL2:0:200}"

# 19. list includes fields (client name search + quote expiry need it)
curl -s "$BASE/api/documents" | grep -q '"fields"' && ok "list includes document fields" || bad "list missing fields"

# 20. quote expiry helpers (node)
node -e "
var T=require('$DIR/public/templates.js');
var e=T.expiryInfo('quote-approval', new Date().toISOString(), {validDays:'30'});
if(!e||e.daysLeft!==30) throw new Error('expiry '+JSON.stringify(e));
if(T.expiryInfo('completion', new Date().toISOString(), {})!==null) throw new Error('non-quote should be null');
if(T.quoteExpiryDate(new Date().toISOString(), {})===null) throw new Error('default validDays broken');
" && ok "quote expiry helpers work (30d default, non-quote null)" || bad "expiry helpers broken"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
