# Planet Ops: Estimating and Quotes & Proposals mockups (Phase 0)

Low-fidelity wireframes for review before Phase 1 (customer documents) and Phase 3 (calculator).
They follow the confirmed workflow: **Estimating** is internal; **Quotes & Proposals** is customer-facing;
they are separate tabs with linked, independently versioned records. Names and amounts are
fictional.

## 1. Navigation

```text
┌──────────────────────┐
│ ◉ Planet Ops         │
│  Home                │
│  Requests            │
│  Pipeline            │
│  Estimating      NEW │  internal calculator (Phase 3)
│  Quotes & Proposals  │  customer documents (Phase 1; today's Quotes)
│  Jobs                │
│  Schedule            │
│  …                   │
└──────────────────────┘
```

## 2. Estimating (internal; never shown to customers)

```text
Estimating                                                     [ + New Estimate ]
┌──────────────────────────────────────────────────────────────────────────────┐
│ EST-1042 v3 · 123 Sample Rd · House demo · Estimator: Test Estimator · Draft │
├──────────────────────────────────────────────────────────────────────────────┤
│ 1 Request & site ✓  2 Survey ✓  3 Labor ✓  4 Equipment ●  5 Disposal  6 Other │
│ 7 Risk & pricing   8 Review                                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│ Equipment                                   unit   qty   rate (snap) total   │
│  Excavator 20t (owned)  incl. fuel? [ ] no  day    3     $___        $____   │
│  Transport (lowboy)                         trip   2     $___        $____   │
│  Missing inputs: ⚠ fuel basis for owned excavator                            │
├──────────────────────────────────────────────────────────────────────────────┤
│ Base cost $____ · Risk reserve $____ · Markup __% (not margin) · Owner pay   │
│ Calculated selling price $____ · Projected profit $____   (INTERNAL)         │
├──────────────────────────────────────────────────────────────────────────────┤
│ [ Save version ]  [ Request pricing approval ]  [ Create Quote / Proposal ▸ ] │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 3. Create Quote / Proposal handoff

```text
┌ Create a customer document from EST-1042 v3 ─────────────────────────────────┐
│ Layout:  (•) Line-item quote   ( ) Proposal                                  │
│ Price carried over: calculated selling price $____  (you can edit it in the  │
│ draft; the estimate keeps its own numbers)                                   │
│ Scope carried over: customer-facing scope only. Internal rates, wages,       │
│ markup, contingency and owner pay are NOT copied.                            │
│                                                                              │
│ Creates an UNSENT draft in Quotes & Proposals, linked to EST-1042 v3.        │
│ Nothing is sent.                         [ Cancel ]  [ Create draft ]        │
└──────────────────────────────────────────────────────────────────────────────┘
```

A later estimate edit never changes a sent or signed document. On an **unsigned draft**, an authorized
user can choose **Refresh from estimate**, which shows a difference preview first.

## 4. Quotes & Proposals: the customer document (staff editor)

```text
Quotes & Proposals › Q-2211 rev 2 · Draft · from EST-1042 v3     [ Preview ] [ Send ▸ ]
Layout: [ Line-item quote | Proposal ]   (switching keeps prices, scope and terms)
┌ Scope ─────────────────────────┐  ┌ Line items (quote layout) ───────────────┐
│ Overview / work order /        │  │ Demolish house, ~1,800 sq ft   1  $____   │
│ inclusions / exclusions /      │  │ Haul and dispose debris        1  $____   │
│ assumptions / alternates       │  │ Backfill and grade             1  $____   │
└────────────────────────────────┘  └───────────────────────── Total $____ ─────┘
┌ Contract Terms (template, editable per job) ┐ ┌ Payment Terms (separate) ──────┐
└─────────────────────────────────────────────┘ └────────────────────────────────┘
┌ Signatures / Acceptance: Customer ____  Company ____ (countersign: per setting) ┐
History: rev 1 sent → changes requested (note) → rev 2 draft
```

## 5. Customer view: Request changes

```text
Planet Demolition · Proposal Q-2211 (rev 1)
… scope, total, Contract Terms, Payment Terms (same as the PDF) …
[ Accept and sign ]   [ Request changes ]

┌ What would you like changed? (required) ────────────────────────────┐
│ Could you price leaving the detached garage slab in place?          │
└─────────────────────────────────────────────────────────────────────┘
                                                     [ Send request ]
✓ Your request was sent. We'll review it and send you an updated version.
```

Effects: the note is saved exactly, with customer identity, time, document ID and revision. The
document becomes **Changes requested**, signing of that revision pauses, the owner/estimator gets an
in-app notice and a follow-up task. Staff prepare rev 2, preview it and send it deliberately; rev 1
stays in history as **superseded** and can no longer be signed.

## 6. Change order: customer signature required to finalize

```text
Job J-305 › Change orders
 CO-1  Remove garage slab   −$____ credit   Finalized ✓ (signed by customer, rev 1)
 CO-2  Extra basement wall  +$____          Awaiting signature (rev 2)
 CO-3  Schedule only        $0.00           Draft

Original contract $____ · Approved changes −$____ · Revised contract $____
Invoiced $____ · Paid $____ · Remaining $____

CO-2 › [ Finalize ]  (disabled: "Needs the customer's signature on revision 2")
```

No staff toggle, API call, automation, customer note or verbal approval finalizes a change order. Only
the customer's signature on the exact current revision (and the company countersignature, if
configured) does, including for $0 and credit changes. A finalized revision applies its financial
effect once. A later material edit creates a new revision that needs a new signature.
