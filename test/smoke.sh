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

# 21. new UI: waiting badge, typed signature, seal display, nudge button wired
grep -q 'waitingBadge' "$DIR/public/app.js" && ok "app.js uses waitingBadge" || bad "app.js missing waitingBadge"
grep -q 'pad.stamp' "$DIR/public/app.js" && ok "app.js uses pad.stamp (typed signature)" || bad "app.js missing pad.stamp"
grep -q 'btn-stamp-sig' "$DIR/public/index.html" && ok "index.html has typed-signature button" || bad "index.html missing typed-signature button"
grep -q 'seal' "$DIR/public/app.js" && ok "app.js shows signature seal" || bad "app.js missing seal display"
grep -q 'nudge' "$DIR/public/app.js" && ok "app.js wires nudge action" || bad "app.js missing nudge"
grep -q 'nudge' "$DIR/server.js" && ok "server.js has nudge endpoint" || bad "server.js missing nudge"

# 22. sweep-2: decline endpoint, verify endpoint, UI wiring
grep -q 'decline' "$DIR/server.js" && ok "server.js has decline endpoint" || bad "server.js missing decline"
grep -q 'sub === "verify"' "$DIR/server.js" && ok "server.js has verify endpoint" || bad "server.js missing verify"
grep -q 'btn-decline' "$DIR/public/index.html" && ok "index.html has decline button" || bad "index.html missing decline button"
grep -q 'btn-decline' "$DIR/public/app.js" && ok "app.js wires decline action" || bad "app.js missing decline"
grep -q 'verify-box' "$DIR/public/index.html" && ok "index.html has verify result box" || bad "index.html missing verify box"
grep -q 'Verify seals' "$DIR/public/index.html" && ok "index.html has Verify seals button" || bad "index.html missing Verify seals button"
grep -q 'btn-verify' "$DIR/public/app.js" && ok "app.js wires seal verification" || bad "app.js missing verify"
grep -q 'pill.declined' "$DIR/public/style.css" && ok "style.css has declined pill" || bad "style.css missing declined pill"
grep -q 'declineNote' "$DIR/public/app.js" && ok "app.js shows declined banner" || bad "app.js missing declined banner"

# 23. quotely pipeline link fields are stored on the document
DQ=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"quote-approval","title":"Pipeline link test","fields":{"clientName":"Link Guy","workDescription":"x","total":100,"quotelyQuoteId":"q_abc123","quotelyQuoteNumber":"Q-2026-0042","quotelyPurpose":"approval"}}')
DQID=$(echo "$DQ" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['id'])" 2>/dev/null)
echo "$DQ" | grep -q '"quotelyQuoteId":"q_abc123"' && ok "quotely link fields stored on document" || bad "link fields: ${DQ:0:200}"
echo "$DQ" | grep -q '"quotelyPurpose":"approval"' && ok "quotely purpose stored" || bad "purpose missing"

# 24. pipeline UI wiring
grep -q 'quote-link-box' "$DIR/public/index.html" && ok "index.html has linked-quote rail card" || bad "index.html missing quote-link-box"
grep -q 'quote-link-box' "$DIR/public/app.js" && ok "app.js populates linked-quote card" || bad "app.js missing quote link"
grep -q 'quotelyQuoteId' "$DIR/public/app.js" && ok "app.js reads quotely link fields" || bad "app.js missing field read"
grep -q 'notifyQuotely' "$DIR/server.js" && ok "server.js notifies quotely on sign/decline" || bad "server.js missing notifyQuotely"
grep -q 'QUOTELY_URL' "$DIR/server.js" && ok "server.js honors QUOTELY_URL" || bad "server.js missing QUOTELY_URL"

# 25. v2: draft field correction (prepare step)
ED=$(curl -s -X POST "$BASE/api/documents" -H 'Content-Type: application/json' \
  -d '{"template":"quote-approval","title":"Edit test","fields":{"clientName":"Eddy","workDescription":"paint fence","total":500}}')
EID=$(echo "$ED" | python3 -c "import json,sys; print(json.load(sys.stdin)['document']['id'])" 2>/dev/null)
PATCH_OK=$(curl -s -X PATCH "$BASE/api/documents/$EID" -H 'Content-Type: application/json' \
  -d '{"fields":{"clientName":"Eddy Fixed","workDescription":"paint fence + gate","total":650,"validDays":30}}')
echo "$PATCH_OK" | grep -q 'Eddy Fixed' && ok "PATCH fields updates a draft" || bad "field edit: ${PATCH_OK:0:200}"
echo "$PATCH_OK" | grep -q '"status":"draft"' && ok "field edit keeps status=draft" || bad "status changed: ${PATCH_OK:0:120}"
AUD_ED=$(curl -s "$BASE/api/documents/$EID/audit")
echo "$AUD_ED" | grep -q '"event":"edited"' && ok "field edit writes audit event" || bad "no edited audit: ${AUD_ED:0:150}"
PATCH_BAD=$(curl -s -X PATCH "$BASE/api/documents/$EID" -H 'Content-Type: application/json' \
  -d '{"fields":{"clientName":"","workDescription":"x","total":1}}')
echo "$PATCH_BAD" | grep -q 'Missing required field' && ok "field edit validates required fields" || bad "no validation: ${PATCH_BAD:0:150}"
curl -s -X PATCH "$BASE/api/documents/$EID" -H 'Content-Type: application/json' -d '{"status":"sent"}' >/dev/null
PATCH_SENT=$(curl -s -X PATCH "$BASE/api/documents/$EID" -H 'Content-Type: application/json' \
  -d '{"fields":{"clientName":"Nope","workDescription":"x","total":1}}')
echo "$PATCH_SENT" | grep -q 'only draft documents can be edited' && ok "field edit rejected on sent doc" || bad "sent edit: ${PATCH_SENT:0:150}"
PATCH_STATUS=$(curl -s -X PATCH "$BASE/api/documents/$EID" -H 'Content-Type: application/json' -d '{"status":"draft"}')
echo "$PATCH_STATUS" | grep -q '"status":"draft"' && ok "status PATCH still works alongside fields PATCH" || bad "status patch: ${PATCH_STATUS:0:150}"

# 26. v2: signing-room UI wiring
for needle in "consent-card:Electronic signature consent card" "consent-check:consent checkbox" "adopted-panel:adopted-signature panel" "btn-adopt-confirm:Adopt and sign button" "btn-adopt:continue-to-adopt button" "completion-panel:completion panel" "cert-section:certificate of completion" "btn-print-cert:print certificate button" "edit-preview:live preview pane" "statstrip:desk stats strip" "signhere-flag:Sign here flag" "ceremony-banner:guided ceremony banner" "edit-fields-panel:draft field-correction panel" "btn-save-fields:save field corrections"; do
  id="${needle%%:*}"; label="${needle#*:}"
  grep -q "$id" "$DIR/public/index.html" && ok "index.html has $label" || bad "index.html missing $id"
done
for needle in "ceremony-banner:ceremony banner" "showCompletion:completion renderer" "renderCertificate:certificate renderer" "updatePreview:live preview updater" "collectFields:field collector" "btn-save-fields:field-save wiring" "btn-print-cert:print wiring" "btn-completion-pdf:completion PDF wiring" "exportPdf:shared PDF export"; do
  id="${needle%%:*}"; label="${needle#*:}"
  grep -q "$id" "$DIR/public/app.js" && ok "app.js has $label" || bad "app.js missing $id"
done
grep -q 'only draft documents can be edited' "$DIR/server.js" && ok "server.js has draft-only field edit" || bad "server.js missing field edit"
grep -q 'Playfair' "$DIR/public/index.html" && ok "v2 loads Playfair Display" || bad "display font missing"
grep -q '\-\-pine' "$DIR/public/style.css" && ok "v2 identity: ink-green palette" || bad "pine palette missing"
grep -q '\-\-brass' "$DIR/public/style.css" && ok "v2 identity: brass foil palette" || bad "brass palette missing"
# true circles (50%) are excepted per standing design rule; only px radii count.
if grep -E 'border-radius:[^;]*[1-9][0-9]*px' "$DIR/public/style.css" | grep -qv 'border-radius: 0'; then
  bad "rounded edges found in style.css"
else
  ok "no rounded edges in style.css"
fi
# ruled notebook lines on the sigpad use repeating-linear-gradient; any other
# linear-gradient (color wash) would violate the design rules.
if grep 'linear-gradient(' "$DIR/public/style.css" | grep -vq 'repeating-linear-gradient'; then
  bad "color gradient found in style.css"
else
  ok "no color gradients (sigpad ruled lines only)"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
