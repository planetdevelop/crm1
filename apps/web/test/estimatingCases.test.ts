// Planet Ops Phase 3: the screens' estimate arithmetic (packages/core calculateEstimate) against the
// fixed, fictional cases in supabase/tests/estimating_cases.json, whose expected figures were worked
// out apart from the app (Python Decimal, half up). The database runs the same cases in
// supabase/tests/planet_ops_estimating_cases_test.sql; this also checks that file holds exactly these.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { calculateEstimate, type EstimateLineInput, type EstimatePricingInput } from "@crewtavo/core/estimating";
import { describe, expect, it } from "vitest";

interface Case {
  name: string;
  pricing: { method: "markup" | "margin"; pct: string; owner_pay: "none" | "percent_of_price"; owner_pct?: string; burden_pct?: string };
  lines: EstimateLineInput[];
  expect: { base: number; risk: number; subtotal: number; markup: number; price_before_owner_pay: number; owner_pay: number; selling_price: number; line_prices: number[]; status: "ok" | "unresolved"; warnings: string[] };
}

const root = new URL("../../../supabase/tests/", import.meta.url);
const json = readFileSync(fileURLToPath(new URL("estimating_cases.json", root)), "utf8");
const cases = JSON.parse(json) as Case[];

describe("estimate arithmetic, fixed cases", () => {
  it("the database test runs these same cases", () => {
    const sql = readFileSync(fileURLToPath(new URL("planet_ops_estimating_cases_test.sql", root)), "utf8");
    const embedded = /\$cases\$([\s\S]*?)\$cases\$/.exec(sql)?.[1];
    expect(embedded && JSON.parse(embedded)).toEqual(cases);
  });

  it.each(cases.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    const pricing: EstimatePricingInput = { method: c.pricing.method, pct: c.pricing.pct, owner_pay: c.pricing.owner_pay, owner_pct: c.pricing.owner_pct, burden_pct: c.pricing.burden_pct };
    const r = calculateEstimate(c.lines, pricing);
    expect({ base: r.base, risk: r.risk, subtotal: r.subtotal, markup: r.markup, price_before_owner_pay: r.price_before_owner_pay, owner_pay: r.owner_pay, selling_price: r.selling_price }).toEqual({
      base: c.expect.base, risk: c.expect.risk, subtotal: c.expect.subtotal, markup: c.expect.markup, price_before_owner_pay: c.expect.price_before_owner_pay, owner_pay: c.expect.owner_pay, selling_price: c.expect.selling_price,
    });
    expect(r.lines.map((l) => l.price)).toEqual(c.expect.line_prices);
    expect(r.status).toBe(c.expect.status);
    expect([...new Set(r.warnings.map((w) => w.field))].sort()).toEqual([...c.expect.warnings].sort());
    // The customer lines (each line's share) add up to the selling price, to the cent.
    expect(Math.round(r.lines.reduce((a, l) => a + l.price * 100, 0))).toBe(Math.round(c.expect.selling_price * 100));
  });

  it("refuses what isn't a number or a percentage, as problems (the screen can't save them either)", () => {
    const line = (o: Partial<EstimateLineInput>): EstimateLineInput => ({ section: "labor", name: "Crew", unit: "hour", unit_cost: "25", ...o });
    const fields = (r: ReturnType<typeof calculateEstimate>) => r.problems.map((p) => p.field);
    expect(fields(calculateEstimate([line({ count: "2,5" })], { method: "markup", pct: "0.1", owner_pay: "none" }))).toContain("Count");
    expect(fields(calculateEstimate([line({ hours: -1 })], { method: "markup", pct: "0.1", owner_pay: "none" }))).toContain("Hours");
    expect(fields(calculateEstimate([line({ unit_cost: "-25" })], { method: "markup", pct: "0.1", owner_pay: "none" }))).toContain("Unit cost");
    expect(fields(calculateEstimate([line({ unit: "furlong" })], { method: "markup", pct: "0.1", owner_pay: "none" }))).toContain("Unit");
    expect(fields(calculateEstimate([line({})], { method: "margin", pct: "1", owner_pay: "none" }))).toContain("Target margin");
    expect(fields(calculateEstimate([line({})], { method: "markup", pct: "-0.1", owner_pay: "none" }))).toContain("Markup");
    expect(fields(calculateEstimate([line({ risk_pct: "abc" })], { method: "markup", pct: "0.1", owner_pay: "none" }))).toContain("Risk %");
  });
});
