/** Planet Ops Phase 1b: quote and proposal layouts, separate terms, countersignature state. */
import { describe, expect, it } from "vitest";
import { CONTRACT_TERMS_PLACEHOLDER, NARRATIVE_SECTIONS, PAYMENT_TERMS_PLACEHOLDER, isCompanyCountersignature, isPlaceholderTerms, isPresentation, narrativeSections, proposalSettings, readNarrative, signatureState, termsSections } from "../src/proposals";

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
    // Until the business saves its approved wording: clearly marked placeholders. Saved empty: none.
    expect(proposalSettings(null)).toEqual({ contractTerms: CONTRACT_TERMS_PLACEHOLDER, paymentTerms: PAYMENT_TERMS_PLACEHOLDER, countersignRequired: false });
    expect(isPlaceholderTerms(CONTRACT_TERMS_PLACEHOLDER) && isPlaceholderTerms(PAYMENT_TERMS_PLACEHOLDER)).toBe(true);
    expect(proposalSettings({ quotes: { contract_terms: "", payment_terms: "" } })).toMatchObject({ contractTerms: "", paymentTerms: "" });
    expect(proposalSettings({ quotes: { countersign_required: "true" } }).countersignRequired).toBe(false);
  });
});

describe("signatureState", () => {
  const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
  const FP = "0123456789abcdef0123456789abcdef";
  const customer = { name: "Test Customer", signed_at: "2026-11-20T15:00:00Z", signature: PNG, fingerprint: FP };
  const company = { name: "Owner", user_id: "00000000-0000-4000-8000-000000000001", method: "drawn", signature: PNG, signed_at: "2026-11-20T16:00:00Z", fingerprint: FP };
  it("keeps customer acceptance and company countersignature separate", () => {
    expect(signatureState({ status: "sent", approval: null, countersignRequired: true })).toBe("unsigned");
    expect(signatureState({ status: "approved", approval: customer, countersignRequired: true })).toBe("awaiting_countersign");
    expect(signatureState({ status: "approved", approval: { ...customer, company }, countersignRequired: true })).toBe("signed");
    // Their own saved signature, applied on purpose, counts too.
    expect(signatureState({ status: "approved", approval: { ...customer, company: { ...company, method: "saved" } }, countersignRequired: true })).toBe("signed");
    // A required countersignature is drawn: a name alone doesn't complete it.
    expect(signatureState({ status: "approved", approval: { ...customer, company: { name: "Owner" } }, countersignRequired: true })).toBe("awaiting_countersign");
    // An old-style one (no signer, how or time) or one for another version doesn't either.
    expect(signatureState({ status: "approved", approval: { ...customer, company: { name: "Owner", signature: PNG } }, countersignRequired: true })).toBe("awaiting_countersign");
    expect(signatureState({ status: "approved", approval: { ...customer, company: { ...company, fingerprint: "f".repeat(32) } }, countersignRequired: true })).toBe("awaiting_countersign");
    expect(isCompanyCountersignature({ ...customer, company: { ...company, method: "auto" } })).toBe(false);
    expect(signatureState({ status: "approved", approval: customer, countersignRequired: false })).toBe("signed");
  });

  it("doesn't call a typed name a customer signature", () => {
    expect(signatureState({ status: "approved", approval: { name: "Test Customer", signed_at: "2026-11-20T15:00:00Z" }, countersignRequired: false })).toBe("unsigned");
  });

  it("doesn't call a staff approval a signature", () => {
    expect(signatureState({ status: "approved", approval: { name: "Owner", method: "manual" }, countersignRequired: false })).toBe("unsigned");
  });
});
