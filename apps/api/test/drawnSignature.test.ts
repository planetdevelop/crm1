/**
 * Planet Ops: a signature is a real drawing from the signature pad (lib/drawnSignature.ts). The whole
 * image is decoded: blank pads, a tap, one-pixel, malformed or truncated images and typed text are
 * refused, and short signatures still pass. Fixtures were drawn on the app's own pad.
 */
import { describe, expect, it } from "vitest";
import { checkDrawnSignature, drawnSignatureProblem } from "../src/lib/drawnSignature";
import { initialsImage } from "../src/services/contracts";
import { signatureImage } from "../src/services/signing";
import { ONE_PIXEL, PAD_BLANK, PAD_DOT, PAD_FULL, PAD_INITIALS, PAD_SHORT } from "./fixtures/signaturePad";

const bytes = (dataUrl: string) => Buffer.from(dataUrl.slice("data:image/png;base64,".length), "base64");
const url = (b: Buffer) => `data:image/png;base64,${b.toString("base64")}`;

describe("a drawn signature", () => {
  it("accepts signatures drawn on the pad, a short one included", () => {
    expect(checkDrawnSignature(PAD_FULL)).toMatchObject({ ok: true, width: 840, height: 280 });
    expect(checkDrawnSignature(PAD_SHORT).ok).toBe(true);
    expect(checkDrawnSignature(PAD_INITIALS).ok).toBe(true);
    expect(signatureImage.safeParse(PAD_FULL).success).toBe(true);
    expect(signatureImage.safeParse(PAD_SHORT).success).toBe(true);
    expect(initialsImage.safeParse(PAD_INITIALS).success).toBe(true);
  });

  it("refuses a blank pad and a single tap", () => {
    expect(checkDrawnSignature(PAD_BLANK)).toEqual({ ok: false, reason: "blank" });
    expect(checkDrawnSignature(PAD_DOT)).toEqual({ ok: false, reason: "blank" });
    expect(signatureImage.safeParse(PAD_BLANK).success).toBe(false);
    expect(drawnSignatureProblem(checkDrawnSignature(PAD_BLANK))).toMatch(/looks empty/);
  });

  it("refuses a one-pixel image", () => {
    expect(checkDrawnSignature(ONE_PIXEL)).toEqual({ ok: false, reason: "too_small" });
    expect(signatureImage.safeParse(ONE_PIXEL).success).toBe(false);
  });

  it("refuses malformed and truncated images", () => {
    const full = bytes(PAD_FULL);
    expect(checkDrawnSignature(url(full.subarray(0, Math.floor(full.length * 0.6))))).toEqual({ ok: false, reason: "malformed" });
    const corrupted = Buffer.from(full);
    corrupted[200] = corrupted[200]! ^ 0xff;
    expect(checkDrawnSignature(url(corrupted))).toEqual({ ok: false, reason: "malformed" });
    // The end chunk cut off.
    expect(checkDrawnSignature(url(full.subarray(0, full.length - 12))).ok).toBe(false);
    expect(signatureImage.safeParse(url(corrupted)).success).toBe(false);
  });

  it("refuses typed text and other pictures", () => {
    for (const typed of ["Pat Customer", "data:text/plain;base64,UGF0", "data:image/jpeg;base64,/9j/4AAQSkZJRg==", "<svg><text>Pat</text></svg>"]) {
      expect(checkDrawnSignature(typed).ok, typed).toBe(false);
      expect(signatureImage.safeParse(typed).success, typed).toBe(false);
    }
  });
});
