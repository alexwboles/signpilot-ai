#!/usr/bin/env bash
# e2e.sh — end-to-end flows against a live server on a scratch port.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT=3462
BASE="http://localhost:$PORT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== SignPilot AI end-to-end tests =="

# keep any real data safe
BACKUP=""
if [ -f "$DIR/data/documents.json" ]; then
  BACKUP=/tmp/signpilot-data-backup.json
  cp "$DIR/data/documents.json" "$BACKUP"
fi
echo "[]" > "$DIR/data/documents.json"

start_srv() {
  node "$DIR/server.js" >/tmp/signpilot-e2e.log 2>&1 &
  SRV=$!
  sleep 1
  kill -0 $SRV 2>/dev/null || { bad "server failed to boot"; cat /tmp/signpilot-e2e.log; return 1; }
}
stop_srv() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; }
trap 'stop_srv 2>/dev/null; if [ -n "$BACKUP" ]; then cp "$BACKUP" "$DIR/data/documents.json"; else echo "[]" > "$DIR/data/documents.json"; fi' EXIT

start_srv || { echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

SIG="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# ---- Flow 1: change-order full lifecycle to signed ----
C=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"change-order","title":"Smith bath — change order","fields":{"clientName":"Jane Smith","projectRef":"Q-2026-0007","changeDescription":"Add heated floor in master bath","costDelta":1200,"newTotal":9700}}')
ID=$(echo "$C" | py "d['document']['id']")
[ -n "$ID" ] || { bad "flow1: create failed: ${C:0:200}"; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
curl -s -X PATCH "$BASE/api/documents/$ID" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
curl -s -X POST "$BASE/api/documents/$ID/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"contractor\",\"name\":\"Alex Contractor\",\"signature\":\"$SIG\"}" >/dev/null
F1=$(curl -s -X POST "$BASE/api/documents/$ID/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Jane Smith\",\"signature\":\"$SIG\"}")
echo "$F1" | grep -q '"status":"signed"' && ok "flow1: change-order draft->sent->both-signed = signed" || bad "flow1 not signed: ${F1:0:200}"
echo "$F1" | py "d['document']['signedAt']" | grep -q 'T' && ok "flow1: signedAt timestamp set" || bad "flow1: no signedAt"

# ---- Flow 2: recall to draft ----
C2=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","title":"Jones roof — sign-off","fields":{"clientName":"Bob Jones","projectRef":"Q-2026-0008","workSummary":"Full roof replacement, 30yr shingles"}}')
ID2=$(echo "$C2" | py "d['document']['id']")
curl -s -X PATCH "$BASE/api/documents/$ID2" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
R2=$(curl -s -X PATCH "$BASE/api/documents/$ID2" -H 'Content-Type: application/json' -d '{"status":"draft"}')
echo "$R2" | grep -q '"status":"draft"' && ok "flow2: sent can be recalled to draft" || bad "flow2 recall failed: ${R2:0:200}"

# ---- Flow 3: invalid inputs rejected ----
B1=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' -d '{"template":"nope","fields":{}}')
echo "$B1" | grep -q 'Unknown template' && ok "flow3: unknown template rejected" || bad "flow3: $B1" | head -c 200
B2=$(curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d '{"role":"client","name":"Bob Jones","signature":"not-a-data-url"}')
echo "$B2" | grep -q 'must be sent before signing' && ok "flow3: signing a draft rejected" || bad "flow3: ${B2:0:200}"
curl -s -X PATCH "$BASE/api/documents/$ID2" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
B3=$(curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"\",\"signature\":\"$SIG\"}")
echo "$B3" | grep -q 'signer name required' && ok "flow3: empty signer name rejected" || bad "flow3: ${B3:0:200}"
B4=$(curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d '{"role":"client","name":"Bob Jones","signature":"data:image/jpeg;base64,AAA"}')
echo "$B4" | grep -q 'must be a PNG data URL' && ok "flow3: non-PNG signature rejected" || bad "flow3: ${B4:0:200}"
B5=$(curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"witness\",\"name\":\"W\",\"signature\":\"$SIG\"}")
echo "$B5" | grep -q 'role must be client or contractor' && ok "flow3: bad role rejected" || bad "flow3: ${B5:0:200}"

# ---- Flow 4: re-signing same role updates instead of duplicating ----
curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Bob Jones\",\"signature\":\"$SIG\"}" >/dev/null
R4=$(curl -s -X POST "$BASE/api/documents/$ID2/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Robert Jones\",\"signature\":\"$SIG\"}")
N=$(echo "$R4" | py "len([s for s in d['document']['signatures'] if s['role']=='client'])")
NM=$(echo "$R4" | py "[s for s in d['document']['signatures'] if s['role']=='client'][0]['name']")
[ "$N" = "1" ] && [ "$NM" = "Robert Jones" ] && ok "flow4: re-sign updates name, no duplicate" || bad "flow4: n=$N name=$NM"

# ---- Flow 5: list endpoint omits signature image data ----
L=$(curl -s "$BASE/api/documents")
echo "$L" | grep -q 'data:image' && bad "flow5: list leaks signature data" || ok "flow5: list omits signature image blobs"
echo "$L" | grep -q '"number":"SP-' && ok "flow5: list includes document numbers" || bad "flow5: no numbers"

# ---- Flow 6: audit trail order + terminal enforcement ----
A6=$(curl -s "$BASE/api/documents/$ID/audit")
EVS=$(echo "$A6" | python3 -c "import json,sys; print(','.join(e['event'] for e in json.load(sys.stdin)['audit']))")
echo "$EVS" | grep -q '^created,sent,signed,signed,completed' && ok "flow6: audit events in lifecycle order ($EVS)" || bad "flow6 order: $EVS"
T6=$(curl -s -X PATCH "$BASE/api/documents/$ID" -H 'Content-Type: application/json' -d '{"status":"sent"}')
echo "$T6" | grep -q 'invalid transition' && ok "flow6: signed doc refuses further transitions" || bad "flow6: ${T6:0:200}"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
