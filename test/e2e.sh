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

# ---- Flow 10: tamper-evident signature seal ----
C10=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","title":"Seal test","fields":{"clientName":"Seal Guy","projectRef":"Q-9","workSummary":"x"}}')
ID10=$(echo "$C10" | py "d['document']['id']")
curl -s -X PATCH "$BASE/api/documents/$ID10" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
SIG2="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhgGAdGkH8AAAAABJRU5ErkJggg=="
H10=$(curl -s -X POST "$BASE/api/documents/$ID10/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"contractor\",\"name\":\"Alex Contractor\",\"signature\":\"$SIG\"}")
HASH=$(echo "$H10" | py "d['document']['signatures'][0]['hash']")
echo "$HASH" | grep -qE '^[0-9a-f]{64}$' && ok "flow10: seal is a 64-hex SHA-256" || bad "flow10: bad seal: ${HASH:0:40}"
SIGBLOB=$(echo "$H10" | py "d['document']['signatures'][0]['signature']")
echo "$SIGBLOB" | grep -q '^data:image' && ok "flow10: signature blob retained server-side" || bad "flow10: blob missing"
# seal must change when the signature image changes
H10B=$(curl -s -X POST "$BASE/api/documents/$ID10/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"contractor\",\"name\":\"Alex Contractor\",\"signature\":\"$SIG2\"}")
HASHB=$(echo "$H10B" | py "d['document']['signatures'][0]['hash']")
[ "$HASH" != "$HASHB" ] && [ -n "$HASHB" ] && ok "flow10: seal changes when signature bytes change" || bad "flow10: seal static"
# list endpoint omits blobs but carries the seal
L10=$(curl -s "$BASE/api/documents")
echo "$L10" | grep -q '"hash"' && ok "flow10: list exposes seal hashes" || bad "flow10: list missing hash"
echo "$L10" | grep -q 'data:image' && bad "flow10: list leaks blobs" || ok "flow10: list still omits blobs"

# ---- Flow 11: nudge / reminder bookkeeping on sent docs ----
C11=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","title":"Nudge test","fields":{"clientName":"Nudge Guy","projectRef":"Q-1","workSummary":"x"}}')
ID11=$(echo "$C11" | py "d['document']['id']")
N11A=$(curl -s -X POST "$BASE/api/documents/$ID11/nudge" -H 'Content-Type: application/json' -d '{"via":"text"}')
echo "$N11A" | grep -q 'only sent documents can be nudged' && ok "flow11: nudge on draft rejected" || bad "flow11: draft nudge: ${N11A:0:150}"
curl -s -X PATCH "$BASE/api/documents/$ID11" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
N11B=$(curl -s -X POST "$BASE/api/documents/$ID11/nudge" -H 'Content-Type: application/json' -d '{"via":"text"}')
echo "$N11B" | grep -q '"ok":true' && ok "flow11: nudge accepted on sent doc" || bad "flow11: nudge failed: ${N11B:0:150}"
A11=$(curl -s "$BASE/api/documents/$ID11/audit")
echo "$A11" | grep -q '"event":"nudge"' && ok "flow11: nudge written to audit trail" || bad "flow11: no audit event"
G11=$(curl -s "$BASE/api/documents/$ID11" | py "d['document']['sentAt']")
echo "$G11" | grep -q 'T' && ok "flow11: sentAt stamped on send" || bad "flow11: sentAt missing"

# ---- Flow 12: decline lifecycle ----
C12=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","title":"Decline test","fields":{"clientName":"Dan Client","projectRef":"Q-9","workSummary":"test work"}}')
ID12=$(echo "$C12" | py "d['document']['id']")
D12A=$(curl -s -X POST "$BASE/api/documents/$ID12/decline" -H 'Content-Type: application/json' -d '{"reason":"too expensive"}')
echo "$D12A" | grep -q 'only sent documents can be declined' && ok "flow12: decline on draft rejected" || bad "flow12: draft decline: ${D12A:0:150}"
curl -s -X PATCH "$BASE/api/documents/$ID12" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
D12B=$(curl -s -X POST "$BASE/api/documents/$ID12/decline" -H 'Content-Type: application/json' -d '{"reason":"Price too high"}')
echo "$D12B" | grep -q '"status":"declined"' && ok "flow12: sent doc declines with reason" || bad "flow12: decline failed: ${D12B:0:200}"
echo "$D12B" | grep -q 'Price too high' && ok "flow12: decline reason stored" || bad "flow12: reason missing"
echo "$D12B" | py "d['document']['declinedAt']" | grep -q 'T' && ok "flow12: declinedAt timestamp set" || bad "flow12: no declinedAt"
A12=$(curl -s "$BASE/api/documents/$ID12/audit")
echo "$A12" | grep -q '"event":"declined"' && ok "flow12: decline written to audit trail" || bad "flow12: no decline audit"
S12=$(curl -s -X POST "$BASE/api/documents/$ID12/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"client\",\"name\":\"Dan Client\",\"signature\":\"$SIG\"}")
echo "$S12" | grep -q 'must be sent before signing' && ok "flow12: declined doc cannot be signed" || bad "flow12: sign after decline: ${S12:0:150}"
R12=$(curl -s -X PATCH "$BASE/api/documents/$ID12" -H 'Content-Type: application/json' -d '{"status":"draft"}')
echo "$R12" | grep -q 'invalid transition: declined -> draft' && ok "flow12: declined is terminal (no recall)" || bad "flow12: recall: ${R12:0:150}"
DEL12=$(curl -s -X DELETE "$BASE/api/documents/$ID12")
echo "$DEL12" | grep -q 'only draft documents can be deleted' && ok "flow12: declined doc is a permanent record" || bad "flow12: delete: ${DEL12:0:150}"
DUP12=$(curl -s -X POST "$BASE/api/documents/$ID12/duplicate" -H 'Content-Type: application/json' -d '{}')
echo "$DUP12" | grep -q '"status":"draft"' && ok "flow12: declined doc duplicates into a fresh draft" || bad "flow12: dup: ${DUP12:0:150}"

# ---- Flow 13: seal verification endpoint ----
C13=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"completion","title":"Verify test","fields":{"clientName":"Vera","projectRef":"Q-10","workSummary":"original scope"}}')
ID13=$(echo "$C13" | py "d['document']['id']")
curl -s -X PATCH "$BASE/api/documents/$ID13" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
curl -s -X POST "$BASE/api/documents/$ID13/sign" -H 'Content-Type: application/json' \
  -d "{\"role\":\"contractor\",\"name\":\"Alex Contractor\",\"signature\":\"$SIG\"}" >/dev/null
V13=$(curl -s "$BASE/api/documents/$ID13/verify")
echo "$V13" | grep -q '"valid":true' && ok "flow13: seals verify clean on untouched doc" || bad "flow13: verify: ${V13:0:200}"
echo "$V13" | py "d['seals'][0]['role']" | grep -q 'contractor' && ok "flow13: seal detail names the role" || bad "flow13: seal detail"
# tamper with the document fields on disk, then verify again
python3 -c "
import json
p = '$DIR/data/documents.json'
docs = json.load(open(p))
for d in docs:
    if d['id'] == '$ID13': d['fields']['workSummary'] = 'TAMPERED scope'
json.dump(docs, open(p, 'w'), indent=2)
"
V13B=$(curl -s "$BASE/api/documents/$ID13/verify")
echo "$V13B" | grep -q '"valid":false' && ok "flow13: edited fields break the seal" || bad "flow13: tamper not detected: ${V13B:0:200}"
V13C=$(curl -s "$BASE/api/documents/$ID12/verify")
echo "$V13C" | grep -q '"valid":false' && ok "flow13: doc with no signatures reports valid:false" || bad "flow13: empty seals: ${V13C:0:200}"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
