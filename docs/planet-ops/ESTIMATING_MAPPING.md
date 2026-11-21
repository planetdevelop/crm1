# Estimating workbook mapping (Phase 3)

How the business's estimating workbooks calculate a bid, cell by cell, and what the app's
Estimating tab does with each piece. This is a reference and formula-mapping exercise, not an
import: no job, customer or rate from the workbooks is copied into the app or this repository.

**Read on 2026-11-21** from XLSX exports of the owner's Google Sheets (read-only; nothing in them was
changed): the primary bid workbook (tab **Bid Template**, its 50 job tabs, **old Bid Template**,
**Market Rates – NorCal 2026**, **Willow Valley Expenses**, **Willow Valley Loads**) and the
completed-job reference workbook (**Completed Job History**, **Benchmarks & Lessons**, **Future Bid
Checklist**, **SF & CY Benchmarks**). Formulas were read as well as displayed values. Private links,
customer names and the business's rate values are deliberately left out of this public file; they
stay in the workbooks. Where a value matters, it's named by cell (for example "the crew rate in C8").

Legend: **V** verified against the workbook; **R** an app implementation rule; **P** a proposed change
for the owner to decide (the app does not silently apply it).

## 1. Bid Template layout

| Area | Cells | Meaning | Unit | Input / formula |
| --- | --- | --- | --- | --- |
| Header | B3/E3 (after the A3 "Client Name:", D3 "Project / Address:" labels), B4/E4 | Client, contact phone, project address, city/county | text | Input |
| Header | I3 (label H3 "Bid Date:") | Bid date | date | Input |
| Header | I4 (label H4 "Est. Sq Ft:") | Estimated area | sq ft | Input |
| Header | K3 / K4 | Job type / Asbestos test? | text | Input |
| Rate settings | B8 Foreman, C8 Crew, D8 Crew OT | Hourly labor rates | $/hour | Input (formatted `$#,##0`) |
| Rate settings | E8 Fuel | Fuel price | $/gallon | Input (`$#,##0`, so cents don't show) |
| Rate settings | F8 Travel | Travel rate | $/mile | Input, **formatted as a percentage** (see §4) |
| Rate settings | G8 Markup %, H8 Risk Reserve %, I8 Owner % | Pricing percentages | fraction | Input |
| Line grid | rows 13–50, columns B–E | Count, Hrs, Days, Unit $ | per line | Input (E is `=$B$8` etc. for the labor and fuel lines) |
| Line grid | F | Base cost `=B*C*D*E` | $ | Formula |
| Line grid | G | Line risk reserve % | fraction | Input per line |
| Line grid | H | Subtotal `=F*(1+G)` | $ | Formula |
| Line grid | I | Markup (fee) `=H*$G$8` | $ | Formula |
| Line grid | J | Grand total `=H+I` | $ | Formula |
| Line grid | K | Unit price `=IF($I$3>0,J/$I$3,"")` | $/? | Formula (see §4: divides by the bid date cell) |
| Line grid | L | Notes | text | Input |
| Totals | F51, H51, I51, J51 | `=SUM(F12:F50)` etc.: base, subtotal, markup, price before owner pay | $ | Formula |
| Totals | J52 | Owner pay `=J51*$I$8` | $ | Formula |
| Totals | J53 | Final bid price `=J51+J52` | $ | Formula |
| Summary | D56 `=F51`, D57 `=I51`, D58 `=J51`, D59 `=IFERROR(I51/J51,0)`, D60 `=IF(I4>0,J51/I4,"N/A")` | Base cost, markup, project price, "profit margin (approx)", price per sq ft | $, %, $/sq ft | Formula |
| Benchmarks | F55–I60 | "Quick market benchmarks" ranges by job type | text | Input (reference text) |
| Closeout | D64 `=J53`, D65 sold bid, D66 actual cost, D67–D69, I64–I69 | Calculated vs sold vs actual, gross profit, margin, cost ratio, markup on cost, per-sq-ft | $, % | Formula / input |

Line sections (row labels in column A): Labor (Foreman, Crew, Crew OT, Prevailing wage adder),
Travel (Truck fuel, Hotel / per diem), Heavy equipment (two excavator classes, excavator transport,
excavator fuel, breaker attachment, track loader, skid steer, loader fuel, skid-steer transport,
operator), Disposal (20- and 40-yard dumpster hauls, dump-truck C&D hauls, C&D tons, concrete by
trailer and by truck, fire debris tons, hazmat/asbestos, metal hauling), Materials / other (fill
dirt loads, rentals, gravel/base loads, lumber/shoring, PPE/site materials, air-quality report,
permits & testing, subcontractor/other, contingency).

## 2. Calculation order (V)

For each line: **base** = Count × Hrs × Days × Unit $ → **subtotal** = base × (1 + line risk %) →
**markup** = subtotal × markup % → **line total** = subtotal + markup. Then: Σ base (F51), Σ subtotal
(H51), Σ markup (I51), Σ line totals = **price before owner pay** (J51) → **owner pay** = J51 × owner %
(J52) → **final bid price** = J51 + J52 (J53).

Consequences the app keeps (V):
- Markup is applied to the subtotal, so it is charged on the risk reserve too.
- Owner pay is a percentage of the price *after* markup and is added on top.
- The "profit margin (approx)" is markup ÷ price before owner pay; it treats the risk reserve as a
  cost and leaves owner pay out entirely.
- The labor, fuel and travel rates are copied from row 8 into each line's Unit $; the other Unit $
  values are typed per line, so rates change bid by bid (the job tabs carry different row-8 values:
  markup, owner % and fuel all vary between jobs).
- **Rounding**: none. No `ROUND` anywhere; amounts keep full precision and the money format shows
  whole dollars (`$#,##0`), so a displayed total can differ from the sum of displayed lines.

## 3. App rules (R)

- The app follows the order in §2 exactly, with exact decimals (Postgres `numeric`, and the same
  arithmetic in `packages/core/src/estimating.ts`): no binary floating point in money.
- Rounding: every intermediate keeps full precision, as the sheet does; each stored and displayed
  amount is rounded **half up to the cent** once, from the unrounded value. A line's displayed total
  and the estimate's totals are each rounded from full precision, so a total can differ by a cent from
  the sum of rounded lines (as in the sheet, but to the cent instead of the dollar).
- A line is *count × hours × days × unit cost* (any factor a line doesn't use is 1), with its unit
  named (hour, day, ton, CY, load, haul, mile, gallon, each, lump sum).
- Rates are records with a unit, cost and effective dates; each saved estimate version keeps a
  **snapshot** of every rate it used, so changing a rate never changes an earlier estimate.
- **Risk reserve** is per line, as in the sheet. The estimate's default risk % (the role H8 appears
  to have been meant for) only pre-fills new lines; it is never applied on top.
- **Pricing method** is explicit and exclusive: *markup on subtotal* (the sheet's method) or *target
  margin* (price = subtotal ÷ (1 − margin)). Only one applies.
- **Owner pay** is configurable per estimate: *none*, or *percent of the price before owner pay,
  added on top* (the sheet's method). There is no default percentage: each estimate states it.
- **Labor burden** (payroll taxes, workers' comp, etc.) is not in the sheet. The app offers an
  optional burden % per estimate, applied only to labor lines whose rate is marked "excludes burden";
  a rate marked "includes burden" is never burdened again. Workers' comp classifications are not
  modeled (Phase 6).
- **Fuel**: an equipment rate can be marked "includes fuel"; adding a separate fuel line for the same
  equipment is flagged as a likely double charge.
- **Disposal**: estimated tons, estimated loose CY, container capacity and expected loads are kept
  as separate fields; the cost line's own count (tons, hauls or loads) is what's priced. A container's
  capacity is never treated as measured debris.
- Profit metrics are labelled with their definitions: *markup* (the sheet's fee), *sheet margin* =
  markup ÷ price before owner pay (verified), and *projected profit if the risk reserve isn't used* =
  markup + risk reserve. Owner pay is shown separately.
- Saving or calculating never sends anything; only Quotes & Proposals sends customer documents.

## 4. Verified issues in the current workbook (V) and what the app does

| # | Where | What the workbook does | App | Owner decision |
| --- | --- | --- | --- | --- |
| 1 | K13:K53 | Unit price divides by `$I$3`, the **bid date** cell, not the area in I4. D60 divides by I4 correctly. Some later job tabs were hand-corrected to `$I$4`; the older layouts used I3 in the summary too | Price per sq ft uses the estimate's area (a correction, labelled as such); per-line unit prices are not shown as sheet parity | **P1**: confirm per-sq-ft uses the estimated area |
| 2 | F8 | Travel `$/mile` is formatted `0%`, so it displays as a percentage. It is no longer used: the current template's travel line was replaced by "Truck Fuel" | The rate is a $/mile rate with its unit; travel is its own line | **P2**: keep a mileage line, fuel only, or both |
| 3 | row 18 | "Truck Fuel" multiplies Count by the **fuel $/gal** (E8), but its note still says "Round-trip miles × IRS rate". The old template's line ("Travel (miles RT)") used the $/mile rate | Fuel lines are gallons × $/gal; mileage lines are miles × $/mile; each says its unit | **P3**: confirm the truck-fuel quantity is gallons |
| 4 | A51 / L51, A53 / L53 | "TOTAL PROJECT COST" is the price *with markup* (L51 calls it "Price Before Owner Pay"); "Final Cost" is the final *bid price* (L53) | Labels say what each is: base cost, subtotal, price before owner pay, owner pay, calculated selling price | **P4**: approve the clearer labels |
| 5 | H8 | The global Risk Reserve % is never referenced; each line's risk % (G) is typed by hand | Per-line risk; the estimate default only pre-fills new lines | **P5**: confirm a global reserve isn't meant to apply on top |
| 6 | L15 | Note says "Half-time OT rate", but D8 is an overtime hourly rate (not half of C8) | OT is an hourly rate line; no half-time rule | **P6**: confirm what the OT rate means |
| 7 | F65 / I65 | Labelled "Sold vs **Sent** Variance %" but compares sold with the *calculated* bid; with no sold bid it shows **−100%** (I64 correctly shows blank) | Sent, sold and calculated prices are kept apart; no variance shown without both values | **P7**: none needed beyond the fix |
| 8 | row 50 | "Contingency — Always include" has a count of 0 by default, so it adds nothing unless edited | Contingency is a normal line; validation warns when an estimate has none | **P8**: confirm contingency is a line, the risk reserve, or both |
| 9 | D59 | "Profit Margin (approx)" excludes owner pay and treats risk reserve as cost | Shown as "Sheet margin" with its definition, beside the other metrics | **P9**: say whether owner pay is a cost or profit |
| 10 | display | Money shows whole dollars; fuel $/gal shows whole dollars | Cents shown | none |

## 5. Other tabs

- **Willow Valley Loads** (V): tons = net pounds ÷ 2000; container capacity CY is recorded as a
  nominal capacity ("not measured debris volume"); metal loads are listed with unknown weight and
  excluded from the weighed tonnage; each load's cost links to an expense row so it's counted once.
  These are *actuals* (Phase 4); they confirm the app's rule to keep weight, volume and capacity
  apart.
- **Willow Valley Expenses** (V): receipt total vs job-allocated vs excluded per receipt, with
  workers' comp accruals added to the job cost. Actual costs are Phase 4; not imported.
- **Market Rates – NorCal 2026** (V): market ranges and "suggested defaults" as text. Reference only:
  the app does not load them as approved rates.
- **Completed Job History, Benchmarks & Lessons, SF & CY Benchmarks** (V): per-job revenue, cost,
  margin, tons, CY and per-SF intensity (lb/SF, CY/100 SF, $/SF), with confidence notes. Benchmarks
  are Phase 8; nothing is imported. The app's estimate keeps area, tons and CY so these comparisons
  can be made later.
- **Future Bid Checklist** (V): the inputs a bid needs by section (client/site, scope endpoint,
  dimensions, schedule, labor with burden, equipment rented vs owned, fuel/travel, disposal by weight
  and volume, masonry, imported fill with contingency, pool geometry, mobile homes, exterior
  envelope). The estimating workspace's sections and validation follow it.

## 6. Parity check

`scripts/estimating-parity.mjs` reads an XLSX export of the bid workbook (given on the command
line; never committed), runs each job tab's inputs through the app's calculation, and compares base
cost, markup, price before owner pay, owner pay and final price with the workbook's own values. It
prints counts only.

**Result on 2026-11-21** (`node --experimental-strip-types scripts/estimating-parity.mjs <export>`):
57 tabs; 45 laid out like the current Bid Template (12 older layouts skipped: totals in another row,
markup at I8, or a different grid). **44 of 45 match to the cent** on base cost, markup, price before
owner pay, owner pay and final price. The one that doesn't has a base cost typed over its formula on
one line (F25 holds a number, not `=B*C*D*E`); the app always calculates a line from its inputs, so a
hand-typed base is entered as a lump-sum line instead. The 12 older layouts are not claimed as parity.
