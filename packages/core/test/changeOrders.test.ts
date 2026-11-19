/** Planet Ops Phase 1: a change order is finalized only with the customer's signature on its exact version. */
import { describe, expect, it } from "vitest";
import { CHANGE_ORDER_CHANGED_SINCE_SIGNED, CHANGE_ORDER_NEEDS_SIGNATURE, changeOrderBlocker, changeOrderSignature } from "../src/changeOrders";

const co = (approval: unknown, total: number | string = 2500) => ({ change_order_for: "job-1", status: "sent", total, approval });
const signed = { name: "Test Customer", signed_at: "2026-11-20T15:00:00Z", total: 2500 };

describe("changeOrderSignature", () => {
  it("counts the customer's own signature on this version", () => {
    expect(changeOrderSignature(co(signed))).toEqual({ signed: true });
    expect(changeOrderSignature(co({ ...signed, method: "in_person", total: "2500.00" }, "2500"))).toEqual({ signed: true });
  });

  it("never counts a staff approval, however complete it looks", () => {
    expect(changeOrderSignature(co({ ...signed, method: "manual" }))).toEqual({ signed: false, reason: "staff_approval" });
  });

  it("needs a signer and a time", () => {
    expect(changeOrderSignature(co(null))).toEqual({ signed: false, reason: "no_signature" });
    expect(changeOrderSignature(co({ ...signed, name: "  " }))).toEqual({ signed: false, reason: "no_signature" });
    expect(changeOrderSignature(co({ name: "Test Customer", total: 2500 }))).toEqual({ signed: false, reason: "no_signature" });
  });

  it("is for the exact version: a different total needs a new signature", () => {
    expect(changeOrderSignature(co(signed, 2600))).toEqual({ signed: false, reason: "changed_since_signed" });
  });

  it("applies to credits and $0 changes too", () => {
    expect(changeOrderSignature(co(null, -800)).signed).toBe(false);
    expect(changeOrderSignature(co(null, 0)).signed).toBe(false);
    expect(changeOrderSignature(co({ ...signed, total: -800 }, -800))).toEqual({ signed: true });
    expect(changeOrderSignature(co({ ...signed, total: 0 }, 0))).toEqual({ signed: true });
  });

  it("explains what the office has to do", () => {
    expect(changeOrderBlocker(co(null))).toBe(CHANGE_ORDER_NEEDS_SIGNATURE);
    expect(changeOrderBlocker(co(signed, 99))).toBe(CHANGE_ORDER_CHANGED_SINCE_SIGNED);
    expect(changeOrderBlocker(co(signed))).toBeNull();
    expect(changeOrderBlocker({ change_order_for: null, status: "sent", total: 1, approval: null })).toBeNull();
  });
});
