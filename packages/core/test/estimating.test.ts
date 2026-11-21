// Planet Ops Phase 3: the estimate's arithmetic, with fictional numbers (no business rates).
import { describe, expect, it } from "vitest";
import { calculateEstimate, parseDecimal, toCentsExact, type EstimateLineInput, type EstimatePricingInput } from "../src/estimating";

const markup = (pct: number | string, owner?: number | string): EstimatePricingInput => ({ method: "markup", pct, owner_pay: owner === undefined ? "none" : "percent_of_price", owner_pct: owner });
const line = (l: Partial<EstimateLineInput>): EstimateLineInput => ({ section: "other", name: "Line", unit: "each", unit_cost: 0, ...l });

describe("the bid workbook's order", () => {
  it("base → risk → subtotal → markup on the subtotal → owner pay on the price → selling price", () => {
    // Fictional: a 3-person crew 2 days at 8 h at $30, a line with a 10% reserve, 40% markup, 5% owner pay.
    const r = calculateEstimate(
      [
        line({ section: "labor", name: "Crew", count: 3, hours: 8, days: 2, unit: "hour", unit_cost: 30 }),
        line({ section: "disposal", name: "Debris", count: 4, unit: "ton", unit_cost: 95.5, risk_pct: 0.1 }),
        line({ section: "contingency", name: "Contingency", count: 1, unit: "lump", unit_cost: 250 }),
      ],
      markup(0.4, 0.05),
    );
    expect(r.base).toBe(1440 + 382 + 250);
    expect(r.risk).toBe(38.2);
    expect(r.subtotal).toBe(2110.2);
    expect(r.markup).toBe(844.08); // 2110.2 × 0.4
    expect(r.price_before_owner_pay).toBe(2954.28);
    expect(r.owner_pay).toBe(147.71); // 147.714 → half up
    expect(r.selling_price).toBe(3101.99); // 3101.994, rounded once from full precision
    expect(r.sheet_margin).toBeCloseTo(844.08 / 2954.28, 6);
    expect(r.profit_if_reserve_unused).toBe(882.28);
    expect(r.status).toBe("ok");
  });

  it("markup is charged on the risk reserve too, as in the workbook", () => {
    const r = calculateEstimate([line({ count: 1, unit_cost: 1000, risk_pct: 0.2 }), line({ section: "contingency", count: 0, unit_cost: 1 })], markup(0.5));
    expect(r.markup).toBe(600);
  });
});

describe("methods are explicit and exclusive", () => {
  const lines = [line({ count: 1, unit_cost: 700 }), line({ section: "contingency", count: 1, unit_cost: 50 })];
  it("target margin: price = subtotal ÷ (1 − margin), no markup on top", () => {
    const r = calculateEstimate(lines, { method: "margin", pct: 0.25, owner_pay: "none" });
    expect(r.price_before_owner_pay).toBe(1000);
    expect(r.markup).toBe(250);
    expect(r.sheet_margin).toBe(0.25);
  });
  it("a margin of 100% or more is refused, and the estimate is unresolved", () => {
    const r = calculateEstimate(lines, { method: "margin", pct: 1, owner_pay: "none" });
    expect(r.status).toBe("unresolved");
    expect(r.problems.map((p) => p.field)).toContain("Target margin");
  });
  it("owner pay on needs its percentage (0% is fine), and none means none", () => {
    expect(calculateEstimate(lines, { method: "markup", pct: 0, owner_pay: "percent_of_price" }).problems.map((p) => p.field)).toContain("Owner pay");
    expect(calculateEstimate(lines, { method: "markup", pct: 0, owner_pay: "percent_of_price", owner_pct: 0 }).status).toBe("ok");
    expect(calculateEstimate(lines, markup(0)).owner_pay).toBe(0);
  });
});

describe("units, rounding, zero and missing values", () => {
  it("exact decimals: no binary floating point", () => {
    const r = calculateEstimate([line({ count: 3, unit_cost: "0.1" }), line({ section: "contingency", count: 1, unit_cost: "0.2" })], markup(0));
    expect(r.base).toBe(0.5);
    expect(toCentsExact(parseDecimal("0.125")!)).toBe(13);
    expect(toCentsExact(parseDecimal("-0.125")!)).toBe(-13);
  });
  it("fractional quantities, and zero quantities price at zero", () => {
    const r = calculateEstimate([line({ count: 2.5, hours: 7.5, days: 0.5, unit: "hour", unit_cost: 41.2 }), line({ section: "contingency", count: 0, unit_cost: 300 })], markup(0));
    expect(r.base).toBe(386.25);
    expect(r.lines[1].base).toBe(0);
  });
  it("a missing rate leaves the estimate unresolved, naming the line", () => {
    const r = calculateEstimate([line({ name: "Excavator", unit_cost: null }), line({ section: "contingency", unit_cost: 1 })], markup(0.3));
    expect(r.status).toBe("unresolved");
    expect(r.problems[0].message).toMatch(/Excavator has no rate/);
  });
  it("negative and non-numeric inputs are refused; an unknown unit too", () => {
    const r = calculateEstimate([line({ count: -1, unit_cost: 5 }), line({ hours: "eight", unit_cost: 5 }), line({ unit: "bucket", unit_cost: 5 })], markup(0));
    expect(r.problems.map((p) => p.message)).toEqual(expect.arrayContaining(["Count can't be negative", "Hours isn't a number", '"bucket" isn\'t a unit the estimate knows']));
  });
  it("warns when there's no contingency line", () => {
    expect(calculateEstimate([line({ count: 1, unit_cost: 1 })], markup(0)).warnings.map((w) => w.field)).toContain("Contingency");
  });
});

describe("burden and fuel aren't charged twice", () => {
  it("burden applies only to labor whose rate excludes it", () => {
    const r = calculateEstimate(
      [
        line({ section: "labor", name: "Crew", count: 1, hours: 10, unit: "hour", unit_cost: 20 }),
        line({ section: "labor", name: "Loaded crew", count: 1, hours: 10, unit: "hour", unit_cost: 26, includes_burden: true }),
        line({ section: "equipment", name: "Loader", count: 1, unit: "day", unit_cost: 100 }),
        line({ section: "contingency", count: 0, unit_cost: 0 }),
      ],
      { method: "markup", pct: 0, owner_pay: "none", burden_pct: 0.3 },
    );
    expect(r.lines.map((l) => l.base)).toEqual([260, 260, 100, 0]);
  });
  it("a fuel line for equipment whose rate includes fuel is flagged", () => {
    const r = calculateEstimate(
      [
        line({ key: "loader", section: "equipment", name: "Loader", count: 1, unit: "day", unit_cost: 300, includes_fuel: true }),
        line({ section: "equipment", name: "Loader fuel", count: 5, unit: "gallon", unit_cost: 4, fuel_for: "loader" }),
        line({ section: "contingency", count: 0, unit_cost: 0 }),
      ],
      markup(0),
    );
    expect(r.warnings.map((w) => w.message)).toEqual([expect.stringMatching(/already includes fuel/)]);
  });
});

describe("each line's share of the selling price, for the customer document", () => {
  it("adds up to the selling price exactly", () => {
    const r = calculateEstimate(
      [line({ count: 1, unit_cost: 333.33 }), line({ count: 1, unit_cost: 333.33 }), line({ section: "contingency", count: 1, unit_cost: 333.34 })],
      markup(0.37, 0.07),
    );
    expect(Math.round(r.lines.reduce((s, l) => s + l.price, 0) * 100)).toBe(Math.round(r.selling_price * 100));
  });
});
