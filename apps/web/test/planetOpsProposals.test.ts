/** Planet Ops Phase 1b: the customer document's layout, narrative and separate terms, as it prints. */
import { describe, expect, it } from "vitest";
import { quoteDocument } from "../src/features/documents/build";

const base = { number: 12, subtotal: 22000, discount_amount: 0, tax_amount: 0, total: 22000, title: "House demolition" };
const lines = [{ id: "l1", name: "Demolish house", description: null, quantity: 1, unit: "ea", unit_price: 18000, taxable: false, optional: false, selected: true, option_id: null, sort: 0 }];

describe("quote or proposal", () => {
  it("prints a line-item quote unless it's a proposal, with the same total", () => {
    const quote = quoteDocument({ ...base }, lines as never);
    const proposal = quoteDocument({ ...base, presentation: "proposal", narrative: { overview: "TEST overview", scope: "1. Demolish\n2. Haul" } }, lines as never);
    expect(quote.presentation).toBe("line_items");
    expect(proposal.presentation).toBe("proposal");
    expect(proposal.total).toBe(quote.total);
    expect(proposal.narrative).toEqual([
      { title: "Project overview", text: "TEST overview" },
      { title: "Scope of work", text: "1. Demolish\n2. Haul" },
    ]);
  });

  it("prints Contract Terms and Payment Terms as two separate sections", () => {
    const doc = quoteDocument({ ...base, contract_terms: "TEST contract terms", payment_terms: "TEST payment terms" }, lines as never);
    expect(doc.terms).toEqual([
      { title: "Contract Terms", text: "TEST contract terms" },
      { title: "Payment Terms", text: "TEST payment terms" },
    ]);
  });

  it("prints a signed agreement as it was signed, not as the quote reads now", () => {
    const approval = {
      name: "Test Customer",
      signed_at: "2026-11-20T15:00:00Z",
      document: { quote: { presentation: "proposal", narrative: { exclusions: "TEST asbestos" }, contract_terms: "TEST signed contract", payment_terms: "TEST signed payment" } },
    };
    const doc = quoteDocument({ ...base, status: "approved", approval, presentation: "line_items", contract_terms: "edited later", payment_terms: "edited later" }, lines as never);
    expect(doc.presentation).toBe("proposal");
    expect(doc.narrative).toEqual([{ title: "Not included", text: "TEST asbestos" }]);
    expect(doc.terms?.map((t) => t.text)).toEqual(["TEST signed contract", "TEST signed payment"]);
  });
});
