/** Planet Ops Phase 1b: quote and proposal layouts, separate terms, countersignature state. */
import { describe, expect, it } from "vitest";
import { CONTRACT_TERMS_PLACEHOLDER, agreementFacts, NARRATIVE_SECTIONS, PAYMENT_TERMS_PLACEHOLDER, isCompanyCountersignature, isPlaceholderTerms, isPresentation, narrativeSections, proposalSettings, readNarrative, signatureState, termsSections } from "../src/proposals";

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
    expect(proposalSettings({ quotes: { contract_terms: "C", payment_terms: "P", countersign_required: true } })).toEqual({ contractTerms: "C", paymentTerms: "P", countersignRequired: true, depositBeforeScheduling: false });
    // Until the business saves its approved wording: clearly marked placeholders. Saved empty: none.
    expect(proposalSettings(null)).toEqual({ contractTerms: CONTRACT_TERMS_PLACEHOLDER, paymentTerms: PAYMENT_TERMS_PLACEHOLDER, countersignRequired: false, depositBeforeScheduling: false });
    expect(proposalSettings({ quotes: { deposit_before_scheduling: true } }).depositBeforeScheduling).toBe(true);
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

describe("agreementFacts (Planet Ops 1d)", () => {
  const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
  const FP = "0123456789abcdef0123456789abcdef";
  const customer = { name: "Test Customer", signed_at: "2026-11-20T15:00:00Z", signature: PNG, fingerprint: FP };
  const company = { name: "Owner", user_id: "00000000-0000-4000-8000-000000000001", method: "drawn", signature: PNG, signed_at: "2026-11-20T16:00:00Z", fingerprint: FP };
  const base = { status: "approved", approval: customer, countersignRequired: false, depositBeforeScheduling: false, depositAsked: 0, depositPaid: null };

  it("keeps acceptance, countersignature, deposit and readiness apart", () => {
    expect(agreementFacts(base)).toEqual({ customerAccepted: true, countersign: "not_required", deposit: "none", readyToSchedule: true, waitingFor: [] });
    // Signing isn't paying: a deposit asked for is owed until its payments say otherwise.
    expect(agreementFacts({ ...base, depositAsked: 500 })).toMatchObject({ customerAccepted: true, deposit: "owed", readyToSchedule: true });
    expect(agreementFacts({ ...base, depositAsked: 500, depositPaid: 200 }).deposit).toBe("partly_paid");
    expect(agreementFacts({ ...base, depositAsked: 500, depositPaid: 500 }).deposit).toBe("received");
  });

  it("waits for a required countersignature, and the deposit only when the business says so", () => {
    expect(agreementFacts({ ...base, countersignRequired: true })).toMatchObject({ countersign: "waiting", readyToSchedule: false, waitingFor: ["countersign"] });
    expect(agreementFacts({ ...base, countersignRequired: true, approval: { ...customer, company } })).toMatchObject({ countersign: "done", readyToSchedule: true });
    expect(agreementFacts({ ...base, depositBeforeScheduling: true, depositAsked: 500 })).toMatchObject({ readyToSchedule: false, waitingFor: ["deposit"] });
    expect(agreementFacts({ ...base, depositBeforeScheduling: true, depositAsked: 500, depositPaid: 500 }).readyToSchedule).toBe(true);
    // An optional countersignature given is recorded, and needed by nothing.
    expect(agreementFacts({ ...base, approval: { ...customer, company } }).countersign).toBe("done");
  });

  it("isn't accepted without the customer's own signature", () => {
    expect(agreementFacts({ ...base, status: "sent", approval: null })).toMatchObject({ customerAccepted: false, readyToSchedule: false, waitingFor: ["customer"] });
    expect(agreementFacts({ ...base, approval: { name: "Owner", method: "manual" } })).toMatchObject({ customerAccepted: false, readyToSchedule: false });
  });
});
