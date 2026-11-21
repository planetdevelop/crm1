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
overwrite their changes. Someone with *Approve estimates* approves it on **Versions and documents**:
the first approved version is the estimate's **original baseline** and is frozen.

## 6. Make the customer's draft

Press **Create quote / proposal**, choose a **proposal** (the customer scope and the total) or a
**line-item quote** (each customer line with its price). It opens as an **unsent draft** in Quotes &
Proposals with only the customer lines and their selling prices; no wage, cost, rate, markup, reserve
or internal note goes with it. Review it there, adjust if you negotiate, and send it from there with
the usual signature rules.

## 7. Revisions and lost bids

- **Revise** (on an approved estimate) makes the next version as a draft, with your reason. The
  baseline stays as it was, and rate changes in Settings never change a saved estimate.
- A quote or proposal doesn't change when the estimate does. On the quote, **Refresh from
  estimate…** shows the differences first; a signed document is never refreshed.
- Negotiating the customer's price never changes the estimate's costs.
- A lost or unanswered bid keeps its estimate and its **Summary** (the Summary button): the scope,
  costs, every version, what was sent and accepted, and the request's outcome. Nothing is guessed
  about why a customer went quiet.
