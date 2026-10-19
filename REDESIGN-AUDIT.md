# SignPilot AI — Redesign Audit v2 (2026-10-19)

## Competitors studied

- **DocuSign** (via support.docusign.com "Adopt Your Signature", docusign.com "How does DocuSign eSignature work", step-by-step signing guides): Review documents → read the electronic-signature disclosure and agree → guided START/Next navigation → yellow "Sign Here" tags marking each action point → **Adopt Your Signature** dialog (predefined style / draw / upload; verify full name + initials; ADOPT AND SIGN) → FINISH → completion page + copy by email. Other-actions menu: View history, **View certificate**, Decline to sign.
- **Dropbox Sign (HelloSign)** (via faq.hellosign.com "The Signing Experience"): "Review & Sign" email → signer page with blue "Get Started" → guided field counter in the top-left + "Next" button walking the signer through every field → required fields marked with red asterisks → red banner alert for missed required fields → **Signature Creator popup** (draw / type / upload photo / phone camera) → top banner turns green and says Continue when everything is complete.
- **PandaDoc** (via esigncompare.com review, signeasy.com review roundup): starts at the blank page — block-based document editor → save as template → prefill forms → send by email or direct link → recipients sign the same document they negotiated → engagement analytics (who opened, time on pricing page) → payment capture in the same flow.

## Layout / IA / visual patterns worth borrowing

1. **Electronic-consent disclosure before signing (DocuSign).** Every ceremony opens with a short legal disclosure and an explicit "I agree to use electronic records and signatures" checkbox. It is the single cheapest trust signal in the category; we have none.
2. **Adopt Your Signature panel (DocuSign).** The signer reviews their full name, chooses a style (drawn or typed), sees a preview, and confirms with ADOPT AND SIGN. Our pad is good but goes straight from canvas to POST with no adoption ritual — it feels like a demo, not a legal instrument.
3. **Guided completion banner (Dropbox Sign).** The top of the ceremony shows a live status banner ("2 of 3 steps complete") that turns into a green Continue state when done. Our steps strip is static.
4. **Certificate of Completion (DocuSign "View certificate").** A printable, signer-facing completion record: document identity, signer events with timestamps, seal/hash numbers, audit summary. We have an audit trail and seal verification, but no ceremonial completion artifact.
5. **Sign Here flags (DocuSign).** Prominent flags mark exactly where the signer must act, so nobody scrolls past the action. Our "Sign here" heading is plain text above the pad.
6. **Prepare before send (DocuSign "Add recipients → Prepare → Send"; PandaDoc prefill).** The sender composes and previews the exact document before it goes out. We let you build from a template, but a draft's field values can never be corrected — the only fix is delete-and-recreate.

## Functional gaps closed in v2

1. **Draft preparation: edit field values on a draft** (new `PATCH /api/documents/:id` `{fields}` path, draft-only, validated, audit-logged) + live paper preview while composing a new document. Fixes the delete-and-recreate tax and matches the Prepare step.
2. **Consent + adopted-signature ceremony.** Signing view now opens with the electronic-signature disclosure (required checkbox), shows a guided status banner, renders Sign Here flags at the signature pad, and presents an adopted-signature confirmation panel (preview of the mark + printed name) before POSTing. Completion state: when both parties have signed, step 3 activates with a completion banner and the certificate.
3. **Certificate of Completion.** Signed documents get a printable certificate block: document identity, status, signer names/roles/timestamps, seal hashes, a seal-verification callout, and the audit summary — plus a Print button (print CSS shows paper + certificate only).

Deliberately not built: per-recipient signing links and signing order (our two-role client/contractor model is an intentional simplification for trade approvals); email delivery of notifications (local-first, no mailer by design); uploaded-signature images (draw/type covers the pad; upload is a future add).

## Visual identity v2 — "The signing room"

The notary/legal DNA stays (it reads as e-signature software) but the palette and
typography go up a level to feel like a private signing room, not a dashboard:

- **Ink green chrome** `#16382c` (deep ledger green) for the topbar, ceremony desk, and primary actions — green reads "executed / approved" and is uncommon in the category (DocuSign yellow/red, Dropbox Sign blue).
- **Brass foil** `#b08d2e` accents — segmented tabs' active states, certificate borders, seal-ring highlights, Sign Here flags. Gold = official certification.
- **Parchment** `#f7f3ea` app background; **paper white** `#fffdf8` documents.
- **Seal red** `#b91c1c` reserved strictly for stamps, seals, and destructive actions — so the stamp moment still hits.
- **Typography:** Playfair Display (high-contrast serif) for brand + page headings — legal-premium; Inter for UI chrome; Georgia for the document body (legal documents read in serif). No rounded edges anywhere (square everything), no gradients, no emoji in chrome.

## Layout changes v2

- **List:** a compact "desk" stats strip (Needs attention / Awaiting signatures / Completed this month) above the DocuSign-style segmented tabs + envelope table; table rows get signature-progress dots (kept) and a hover paper-lift.
- **Editor (New document):** two-column "Prepare" layout — template gallery + fields on the left, **live paper preview** on the right that re-renders as fields change (desktop); stacked on mobile.
- **Detail:** paper rendered as a **stacked sheet** (offset second sheet behind it); draft docs get an inline "Edit fields" panel in the rail; signed docs get the **Certificate of Completion** block below the paper; quotely linked-quote rail card preserved.
- **Signing ceremony:** dark ink-green room containing the cream document, a guided status banner, consent card, Sign Here flag pad, adopted-signature confirmation, and — when both parties have signed — a certificate panel with a brass seal stamp and one-click signed-PDF download.
- Fully responsive; print CSS limited to paper + certificate.

## QA notes

- Desktop 1440x900 + mobile 390x844 via shot.py with stubbed API; signing ceremony captured with a seeded sent document.
- Zero visual bugs, no error banners, no broken layouts before sign-off.
