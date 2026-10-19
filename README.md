# ✍️ SignPilot AI

Local-first e-signature and approval documents for tradespeople. Create a quote approval, change order, or work-completion sign-off, send it to the client, and capture legally-minded signatures — all in the browser. No accounts, no per-envelope fees, no cloud.

Built as a free alternative to paid e-signature tools (and to AGPL-licensed options we can't fork). 100% of your data stays on your machine.

## Features

- **3 document templates** — Quote Approval, Change Order, Work Completion Sign-off, each with field validation
- **Draw-to-sign canvas** — hand-rolled signature pad (no libraries), works with mouse, touch, and stylus
- **Approval pipeline** — draft → sent → signed, with recall-to-draft and terminal signed state
- **Signed PDF export** — generated locally in your browser with pdf-lib (MIT, vendored in `public/vendor/`); includes signatures and the full audit trail
- **Audit trail** — every lifecycle event timestamped (created, edited, sent, signed, completed, recalled, duplicated, declined, nudge)
- **Duplicate documents** — one click clones any document into a fresh draft (new number, no signatures)
- **Prepare step** — correct a draft's field values before sending (draft-only, validated, audit-logged as `edited`); sent/signed/declined documents are permanent records and refuse edits
- **Live preview** — the New Document editor shows the exact paper updating as you type
- **Signing ceremony** — electronic-signature consent disclosure (required), a guided status banner, Sign Here flags, and an adopt-your-signature confirmation panel with a preview of the mark before it counts; when both parties sign, a completion panel shows the seals and offers the signed PDF
- **Certificate of completion** — printable completion record on every signed document: signer events with timestamps, seal hashes, and seal-verification callout (print CSS keeps paper + certificate only)
- **Desk stats strip** — Needs attention / Awaiting signatures / Fully executed counts that double as filter shortcuts
- **Quote expiry tracking** — quote-approval drafts show "expires in N days" badges and an in-document validity notice based on the quote's `validDays`
- **Search + status filter** — find documents by title, client, number, or template across the list
- **CSV export** — download the whole document ledger (`GET /api/documents/export.csv`) for bookkeeping; signature blobs never included
- **Delete drafts** — remove unneeded drafts (sent/signed documents are permanent records)
- **Shareable signing link** — open `#/sign/<id>` on the client's device on the same network, or hand them your device
- **Tamper-evident seal** — every signature gets a SHA-256 hash over a canonical snapshot of the document + signature bytes, stored on the server and shown in the doc view and the signed PDF export; any change to the document or signature invalidates the seal
- **Typed signatures** — signers can type their name instead of drawing; it renders in a script style on the pad (helps trackpads and accessibility)
- **Awaiting-signature tracking** — sent documents show a "waiting N days" badge in the list, and the contractor can record reminders ("Record reminder sent") — each nudge is written to the audit trail
- **Printable** — print CSS for paper copies

## Run it

```bash
node server.js            # serves on http://localhost:3000 (PORT env overrides)
# or
npm start
npm test                  # smoke + end-to-end tests
```

Pipeline wiring (optional): point `QUOTELY_URL` at your quotely-ai server
(e.g. `QUOTELY_URL=http://localhost:3001 node server.js`). Documents that
quotely-ai creates carry `quotelyQuoteId` / `quotelyPurpose`
(`approval`|`change-order`|`completion`) / `quotelyChangeOrderId` in their
fields; signing or declining such a document POSTs back to
`POST {QUOTELY_URL}/api/quotes/:id/signpilot-callback` so the quote's pipeline
status stays in sync (signed → approval recorded; declined approval → the
quote reopens to `sent`). Unlinked documents behave exactly as before, and a
failed callback never blocks signing.

No API keys. No network calls (except the optional quotely-ai callback above). Optional `OPENAI_API_KEY` is not used by this app — there is nothing to enhance; the whole product is local by design.

## API

- `GET /api/health`
- `GET /api/templates` — template metadata + field definitions
- `GET /api/documents` — list (signature image blobs omitted for privacy)
- `POST /api/documents` — `{template, title, fields}` → draft document
- `GET /api/documents/:id`
- `PATCH /api/documents/:id` — `{status: "sent"|"draft"}` (signed/declined are terminal) **or** `{fields: {...}}` to correct a draft's field values (draft-only, validated, audit-logged)
- `POST /api/documents/:id/sign` — `{role: "client"|"contractor", name, signature}` (PNG data URL); both roles signed → `signed`
- `POST /api/documents/:id/duplicate` — clone any document into a fresh draft (new id + number, no signatures)
- `DELETE /api/documents/:id` — delete a draft only (sent/signed are permanent records)
- `GET /api/documents/:id/audit` — timestamped event trail
- `GET /api/documents/export.csv` — whole ledger as CSV (signature image data never included)

## Notes

- Signatures are captured as PNG data URLs and stored in `data/documents.json` on your machine.
- This is a productivity tool, not legal advice. For high-stakes contracts, use a qualified e-signature provider.
- pdf-lib is MIT-licensed and vendored locally (`public/vendor/pdf-lib.min.js`) so the app works offline.

MIT licensed.
