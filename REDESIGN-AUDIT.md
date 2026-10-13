# SignPilot AI — Redesign Audit (2026-10-13)

Competitors researched: DocuSign (envelope flow: Add documents → Add recipients →
Prepare → Send; Manage page with status filter tabs Inbox/Drafts/Sent/Completed;
document table with status pills, recipients, last-change columns; yellow "Next"/"Send"
CTAs; certificate of completion audit), Dropbox Sign/HelloSign (Documents tab with
status tracking, reminders, expirations; Templates tab gallery; upload → recipients →
place fields → review-and-send flow; account-level branding settings).

## Visual gaps
- Generic dark topbar + "cards with left border" look shared with other portfolio apps —
  nothing reads as e-signature software.
- Document list is a card grid with no per-envelope signature progress (who has signed,
  whose turn it is) — DocuSign/HelloSign both show recipient/status per row.
- Filter is a plain dropdown; competitors use segmented status tabs with counts
  (Inbox / Drafts / Sent / Completed).
- Detail view stacks paper, actions, audit trail vertically — no document-centric
  layout; no recipient timeline showing who signed when (DocuSign's core mental model).
- Signing view is a plain form below the paper — not a "signing ceremony":
  no progress steps, no prominent sign-here treatment, no adopt-signature pattern.
- Paper rendering uses the same sans UI font — legal documents read in serif.

## Functional gaps
- No signature-progress indicator on list rows (1/2 signed, whose turn).
- No "needs your attention" concept (declined docs / waiting >7d surfaced like
  DocuSign's inbox).
- Template picker is a dropdown in the editor, not a HelloSign-style template gallery.
- No per-recipient status panel in detail (contractor vs client, signed-at times).
- Seal verification buried as a button in the action row; deserves its own card.

## Redesign concept — "The signing room"
Warm paper background (#faf7f2), ink-navy chrome (#1b2a4a), signature-blue accent
(#2b4fd8), seal-amber (#b45309) for seals/badges. Serif (Georgia) document paper
body; system sans for UI chrome. DocuSign-style segmented status tabs + envelope
table with signature-progress dots; two-column doc detail (paper left, right rail:
signing progress timeline, actions, seal verification, audit trail, PDF); signing
ceremony with progress steps (Review → Sign → Done) and a focused sign desk.
Template picker becomes a gallery. All features preserved (expiry badges, waiting
badges, nudges, decline flow, duplicate, CSV, verify seals, typed signatures).

## QA notes
- Desktop 1440 + mobile 390 screenshots; iterate until commercial-grade.
