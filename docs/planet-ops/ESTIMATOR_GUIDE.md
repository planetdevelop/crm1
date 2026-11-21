# Estimating: a short guide for estimators

A walk through one fictional job, from a request to a customer draft. Everything here uses made-up
numbers: your business's own rates go in Settings → Estimating.

**The idea:** *Estimating* is the business's internal calculator: costs, rates and profit live there
and never reach a customer. *Quotes & Proposals* holds what the customer sees. You build the price in
Estimating, then make a quote or proposal from it, review it, and send it from Quotes & Proposals.
Saving or calculating an estimate never sends anything.

## 1. Start from the request

Open the request (say, *"Garage demolition"* for a fictional customer at 9 Test Court). Under
**Estimates**, press **Start estimate**. The estimate takes the request's customer, property and
title. Pressing twice, or retrying after a dropped connection, opens the same estimate.

## 2. Project and site

Step 1 is everything about the site, before any cost:

- **Structures and measurements**: a 480 sq ft detached garage, one story. Measure: the bid
  checklist's lessons are about quantities that weren't captured.
- **Materials and layers**, **foundation** (a 4" slab), **access** (a narrow driveway),
  **utilities** (who disconnects what), **hazards** and **testing assumptions** (an asbestos test is
  assumed clear; say what happens if it isn't).
- **Included / not included** (internal), and **For the customer's document**: the overview, scope,
  inclusions, exclusions and assumptions written for the customer. A proposal says these words.
- **Supporting files**: links to photos and plans.
- **Assumption log**: every assumption the price rests on and where it came from ("4 tons of debris:
  the photos and the garage's size").

## 3. Build the costs

Each line is **count × hours × days × unit cost** in a named unit. Pick a rate from Settings, or type
a cost.

- **Labor**: 2 people × 8 hours × 1 day at the crew rate. Tick *rate already includes burden* if the
  rate is fully loaded, so burden isn't added twice.
- **Equipment**: a skid steer for 1 day, owned or rented. If its rate *already includes fuel*, don't
  add a fuel line for it (the editor warns you).
- **Disposal and hauling**: price by what's billed: 3 tons at the transfer station's per-ton fee.
  Keep the **estimated tons**, **estimated loose CY**, **container CY** and **expected loads** in their
  own fields: a 20-yard container is the container's size, not 20 measured yards of debris.
- **Other costs**: permits and testing, subcontractors (get a quote), materials, PPE, and always a
  **contingency** line.
- Each line can say what it's called **on the customer's document** ("Demolition", "Haul-off and
  disposal"); lines with the same name are one customer line.

## 4. Review the price

**Pricing review** shows every figure with what it means:

- *Base cost*, *risk reserve* (each line's risk %), *subtotal*.
- The **pricing method**: *markup on cost* (the bid workbook's way: a % of the subtotal) **or** a
  *target margin* (the price is set so the fee is that % of the price). Never both.
- **Owner pay**: none, or a % of the price before it, added on top. Each estimate says which.
- *Calculated selling price*, *profit if the reserve isn't used*, *sheet margin*, and *price per sq ft*.

The side panel shows the price as you type and lists anything missing (a line with no rate, owner pay
on without its %). An incomplete estimate can be saved, but not approved.

Fictional example: labor $400 + disposal $240 + contingency $100 = $740 base; 30% markup = $222; no
owner pay; calculated selling price **$962**.

## 5. Save and approve

**Save** stores the version. If someone else saved meanwhile, you're asked to reload rather than
overwrite their changes (copy anything you typed first; reloading shows their version). Someone with
*Approve estimates* approves it on **Versions and documents**: the first approved version is the
estimate's **original baseline** and is frozen. Approval is of the version the approver was looking
at: if anyone saved after they opened it, they're asked to reload and review it before approving.

If you can't see costs (*Prepare internal estimates* without *See estimating costs*), you can change
the scope, quantities and lines and pick a current rate; the costs, risk %, burden and pricing stay as
someone with cost access set them.

## 6. Make the customer's draft

If your business doesn't require approval (Settings → Estimating), a saved, complete draft can be
used. Making the document **locks that version exactly as it is**: the estimate then says *used for
a customer document, kept exactly as it was (it isn't approved)*. To change anything, press
**Revise**. Locking isn't approval: nobody is recorded as having approved it, and someone with
*Approve estimates* can still approve it later as it is.


Press **Create quote / proposal**, choose a **proposal** (the customer scope and the total) or a
**line-item quote** (each customer line with its price). It opens as an **unsent draft** in Quotes &
Proposals with only the customer lines and their selling prices; no wage, cost, rate, markup, reserve
or internal note goes with it. Review it there, adjust if you negotiate, and send it from there with
the usual signature rules.

## 7. Revisions and lost bids

- **Revise** (on an approved estimate) makes the next version as a draft, with your reason. The
  baseline stays as it was, and rate changes in Settings never change a saved estimate.
- A quote or proposal doesn't change when the estimate does. On the quote, **Refresh from
  estimate…** shows the differences first; if the quote or the estimate changes before you confirm,
  you're asked to **review the differences again**. A signed document is never refreshed.
- Negotiating the customer's price never changes the estimate's costs.
- A lost or unanswered bid keeps its estimate and its **Summary** (the Summary button): the scope,
  costs, every version, what was sent and accepted, and the request's outcome. Nothing is guessed
  about why a customer went quiet.

## 8. A worked example (fictional)

*Elm Street garage* (480 sq ft, one story, 4" slab, narrow driveway). Approval required (the default).

| Line | Section | Quantity | Rate | Base |
| --- | --- | --- | --- | --- |
| Crew (rate excludes burden) | Labor | 2 people × 8 h × 1 day | $25.00/h, 20% burden | $480.00 |
| Operator (fully loaded rate) | Labor | 1 × 8 h | $45.00/h | $360.00 |
| Skid steer (rate includes fuel) | Equipment | 1 day | $300.00/day | $300.00 |
| Mixed C&D (3.4 est. tons, 12 loose CY, one 20 CY container) | Disposal | 3.4 tons | $85.00/ton | $289.00 |
| Container haul | Hauling | 1 haul | $275.00 | $275.00 |
| Demolition permit | Permits | 1 | $350.00 | $350.00 |
| Contingency | Contingency | 1 | $150.00 | $150.00 |

- **Base cost** $2,204.00; risk 0% on every line → **subtotal** $2,204.00.
- **Markup 25%** → $551.00; **price before owner pay** $2,755.00; owner pay none.
- **Calculated selling price $2,755.00**; $5.74 per sq ft.
- The skid steer's rate includes fuel: adding "Skid steer fuel" for it would show *Fuel may be counted
  twice* (a warning: you can still save and approve, but you should remove the line).
- Saved, then approved by the owner: version 1 is the **original baseline**.
- **Create quote / proposal → Proposal**: an unsent draft with the customer scope and $2,755.00 (plus
  any sales tax your settings add). The internal names ("rate excludes burden", "C&D") don't go.
- The customer asks for the shed too: **Revise** ("Customer added the shed") → version 2; add a line;
  save; approve. The proposal still says $2,755.00 until you press **Refresh from estimate…** on it
  and confirm the differences. After signing and converting, the job points at the version the signed
  proposal was made from.
