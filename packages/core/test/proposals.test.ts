/** Planet Ops Phase 1b: quote and proposal layouts, separate terms, countersignature state. */
import { describe, expect, it } from "vitest";
import { NARRATIVE_SECTIONS, isPresentation, narrativeSections, proposalSettings, readNarrative, signatureState, termsSections } from "../src/proposals";

describe("proposal narrative", () => {
  it("keeps only its own sections, trimmed, in print order", () => {
    expect(readNarrative({ scope: "  Demolish  ", warranty: "nope", overview: "", inclusions: 3 })).toEqual({ scope: "Demolish" });
    expect(narrativeSections({ exclusions: "Asbestos", overview: "House demo" }).map((s) => s.title)).toEqual(["Project overview", "Not included"]);
    expect(NARRATIVE_SECTIONS.map((s) => s.key)).toEqual(["overview", "scope", "inclusions", "exclusions", "assumptions", "alternates"]);
  });

  it("reads anything that isn't an object as empty", () => {
    expect(readNarrative(null)).toEqual({});
    expect(readNarrative(["x"])).toEqual({});
  });
});

describe("layouts", () => {
  it("knows the two layouts", () => {
    expect(isPresentation("proposal")).toBe(true);
    expect(isPresentation("line_items")).toBe(true);
    expect(isPresentation("letter")).toBe(false);
  });
});

describe("Contract Terms and Payment Terms", () => {
  it("are two separate sections, each only when it has words", () => {
    expect(termsSections({ contract_terms: "TEST contract", payment_terms: "TEST payment" })).toEqual([
      { key: "contract", title: "Contract Terms", text: "TEST contract" },
      { key: "payment", title: "Payment Terms", text: "TEST payment" },
    ]);
    expect(termsSections({ contract_terms: "  ", payment_terms: "TEST payment" }).map((s) => s.key)).toEqual(["payment"]);
  });

  it("come from the company's defaults, with countersignature off unless set", () => {
    expect(proposalSettings({ quotes: { contract_terms: "C", payment_terms: "P", countersign_required: true } })).toEqual({ contractTerms: "C", paymentTerms: "P", countersignRequired: true });
    expect(proposalSettings(null)).toEqual({ contractTerms: "", paymentTerms: "", countersignRequired: false });
    expect(proposalSettings({ quotes: { countersign_required: "true" } }).countersignRequired).toBe(false);
  });
});

describe("signatureState", () => {
  const customer = { name: "Test Customer", signed_at: "2026-11-20T15:00:00Z" };
  it("keeps customer acceptance and company countersignature separate", () => {
    expect(signatureState({ status: "sent", approval: null, countersignRequired: true })).toBe("unsigned");
    expect(signatureState({ status: "approved", approval: customer, countersignRequired: true })).toBe("awaiting_countersign");
    expect(signatureState({ status: "approved", approval: { ...customer, company: { name: "Owner" } }, countersignRequired: true })).toBe("signed");
    expect(signatureState({ status: "approved", approval: customer, countersignRequired: false })).toBe("signed");
  });

  it("doesn't call a staff approval a signature", () => {
    expect(signatureState({ status: "approved", approval: { name: "Owner", method: "manual" }, countersignRequired: false })).toBe("unsigned");
  });
});
