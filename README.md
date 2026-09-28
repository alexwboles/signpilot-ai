# ✍️ SignPilot AI

Local-first e-signature and approval documents for tradespeople. Create a quote approval, change order, or work-completion sign-off, send it to the client, and capture legally-minded signatures — all in the browser. No accounts, no per-envelope fees, no cloud.

Built as a free alternative to paid e-signature tools (and to AGPL-licensed options we can't fork). 100% of your data stays on your machine.

## Features

- **3 document templates** — Quote Approval, Change Order, Work Completion Sign-off, each with field validation
- **Draw-to-sign canvas** — hand-rolled signature pad (no libraries), works with mouse, touch, and stylus
- **Approval pipeline** — draft → sent → signed, with recall-to-draft and terminal signed state
- **Signed PDF export** — generated locally in your browser with pdf-lib (MIT, vendored in `public/vendor/`); includes signatures and the full audit trail
- **Audit trail** — every lifecycle event timestamped (created, sent, signed, completed, recalled)
- **Shareable signing link** — open `#/sign/<id>` on the client's device on the same network, or hand them your device
- **Printable** — print CSS for paper copies

## Run it

```bash
node server.js            # serves on http://localhost:3000 (PORT env overrides)
# or
npm start
npm test                  # smoke + end-to-end tests
```

No API keys. No network calls. Optional `OPENAI_API_KEY` is not used by this app — there is nothing to enhance; the whole product is local by design.

## API

- `GET /api/health`
- `GET /api/templates` — template metadata + field definitions
- `GET /api/documents` — list (signature image blobs omitted for privacy)
- `POST /api/documents` — `{template, title, fields}` → draft document
- `GET /api/documents/:id`
- `PATCH /api/documents/:id` — `{status: "sent"|"draft"}` (signed is terminal)
- `POST /api/documents/:id/sign` — `{role: "client"|"contractor", name, signature}` (PNG data URL); both roles signed → `signed`
- `GET /api/documents/:id/audit` — timestamped event trail

## Notes

- Signatures are captured as PNG data URLs and stored in `data/documents.json` on your machine.
- This is a productivity tool, not legal advice. For high-stakes contracts, use a qualified e-signature provider.
- pdf-lib is MIT-licensed and vendored locally (`public/vendor/pdf-lib.min.js`) so the app works offline.

MIT licensed.
