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

# ---- Flow 7: duplicate a fully-signed doc -> clean draft copy ----
D7=$(curl -s -X POST "$BASE/api/documents/$ID/duplicate" -H 'Content-Type: application/json')
ID7=$(echo "$D7" | py "d['document']['id']")
N7=$(echo "$D7" | py "d['document']['number']")
G7=$(curl -s "$BASE/api/documents/$ID7")
echo "$G7" | grep -q '"status":"draft"' && ok "flow7: duplicate of signed doc is a draft" || bad "flow7 status: ${G7:0:200}"
echo "$G7" | py "d['document']['signatures']" | grep -q '\[\]' && ok "flow7: duplicate carries no signatures" || bad "flow7: signatures copied"
F7=$(echo "$G7" | py "d['document']['fields']['changeDescription']")
[ "$F7" = "Add heated floor in master bath" ] && ok "flow7: fields preserved in duplicate" || bad "flow7 fields: $F7"
A7=$(curl -s "$BASE/api/documents/$ID7/audit")
echo "$A7" | grep -q 'duplicated' && ok "flow7: audit records duplication" || bad "flow7 audit: ${A7:0:200}"

# ---- Flow 8: delete draft removes doc; unknown id 404s ----
D8=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"quote-approval","fields":{"clientName":"Gone Guy","workDescription":"x","total":10}}')
ID8=$(echo "$D8" | py "d['document']['id']")
R8=$(curl -s -X DELETE "$BASE/api/documents/$ID8")
echo "$R8" | grep -q "\"deleted\":\"$ID8\"" && ok "flow8: draft delete returns deleted id" || bad "flow8: ${R8:0:200}"
G8=$(curl -s "$BASE/api/documents/$ID8")
echo "$G8" | grep -q 'document not found' && ok "flow8: deleted doc no longer retrievable" || bad "flow8: ${G8:0:200}"
X8=$(curl -s -X DELETE "$BASE/api/documents/does-not-exist")
echo "$X8" | grep -q 'document not found' && ok "flow8: delete of unknown id 404s" || bad "flow8: ${X8:0:200}"

# ---- Flow 9: CSV export reflects the ledger (signers, statuses, no blobs) ----
CSV=$(curl -s "$BASE/api/documents/export.csv")
echo "$CSV" | grep -q 'Jane Smith' && ok "flow9: CSV names client signer" || bad "flow9: signer missing"
echo "$CSV" | grep -q 'signed' && ok "flow9: CSV records signed status" || bad "flow9: status missing"
echo "$CSV" | grep -q 'data:image' && bad "flow9: CSV leaks signature blobs" || ok "flow9: CSV omits signature blobs"
ROWS=$(echo "$CSV" | grep -c '^"SP-')
[ "$ROWS" -ge 2 ] && ok "flow9: CSV has $ROWS document rows" || bad "flow9: row count $ROWS"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
