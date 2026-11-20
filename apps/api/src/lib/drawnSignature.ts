/**
 * Planet Ops: is this really a drawn signature? (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3)
 *
 * A customer's signature, initials and a required company countersignature are drawings made on the
 * signature pad (apps/web/src/features/field/SignaturePad.tsx): a PNG the browser's canvas exports,
 * dark ink on a transparent (or white) background. This decodes the whole image, not just its
 * header, and refuses:
 *   - anything that isn't a PNG data URL (typed text, another picture type);
 *   - a malformed or truncated PNG (bad chunk checksums, missing image end, data that doesn't
 *     decompress to the size its header says);
 *   - an image too small to be a pad's (a one-pixel image), or larger than one;
 *   - a blank pad, or one with only a tap: too little ink, or ink in a speck rather than a stroke.
 * A short signature (two quick strokes) has plenty of ink to pass.
 *
 * The browser's canvas writes 8-bit, non-interlaced PNGs (RGBA, or RGB/grey on some browsers); other
 * kinds are refused rather than half-read. Node's zlib does the decompressing.
 */
import { inflateSync } from "node:zlib";

/** The smallest pad: the initials pad is 90 px tall at 1x and the narrowest phone is ~260 px wide. */
export const MIN_WIDTH = 120;
export const MIN_HEIGHT = 60;
/** The largest: the iPad's bigger signing pad at 3x, with room (as services/logo.ts has always allowed). */
export const MAX_WIDTH = 8000;
export const MAX_HEIGHT = 8000;
export const MAX_PIXELS = 8_000_000;
/** Ink: at least this many dark, visible pixels, spread over at least this many pixels one way. */
export const MIN_INK_PIXELS = 60;
export const MIN_INK_SPAN = 16;
/** A data URL a pad makes is a few to a few tens of kilobytes. */
export const MAX_DATA_URL_CHARS = 300_000;

const PREFIX = "data:image/png;base64,";
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export type DrawnCheck =
  | { ok: true; width: number; height: number; ink: number; span: number }
  | { ok: false; reason: "not_png" | "malformed" | "too_small" | "too_large" | "unsupported" | "blank" };

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();
function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** Checks a drawn signature's data URL, decoding the whole image. */
export function checkDrawnSignature(value: unknown): DrawnCheck {
  if (typeof value !== "string" || !value.startsWith(PREFIX) || value.length > MAX_DATA_URL_CHARS) return { ok: false, reason: "not_png" };
  const b64 = value.slice(PREFIX.length);
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return { ok: false, reason: "not_png" };
  const data = Buffer.from(b64, "base64");
  if (data.length < 8 || !data.subarray(0, 8).equals(PNG_SIGNATURE)) return { ok: false, reason: "not_png" };

  // Walk the chunks, checking each one's checksum, until IEND.
  let at = 8;
  let width = 0, height = 0, depth = 0, color = -1, interlace = 0;
  const idat: Buffer[] = [];
  let ended = false;
  while (at + 12 <= data.length) {
    const length = data.readUInt32BE(at);
    const type = data.toString("latin1", at + 4, at + 8);
    if (at + 12 + length > data.length) return { ok: false, reason: "malformed" };
    const body = data.subarray(at + 8, at + 8 + length);
    if (crc32(data.subarray(at + 4, at + 8 + length)) !== data.readUInt32BE(at + 8 + length)) return { ok: false, reason: "malformed" };
    if (type === "IHDR") {
      if (length !== 13 || at !== 8) return { ok: false, reason: "malformed" };
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      depth = body[8]!;
      color = body[9]!;
      interlace = body[12]!;
    } else if (type === "IDAT") {
      idat.push(body);
    } else if (type === "IEND") {
      ended = true;
      break;
    }
    at += 12 + length;
  }
  if (!ended || !width || !height || !idat.length) return { ok: false, reason: "malformed" };
  if (width < MIN_WIDTH || height < MIN_HEIGHT) return { ok: false, reason: "too_small" };
  if (width > MAX_WIDTH || height > MAX_HEIGHT || width * height > MAX_PIXELS) return { ok: false, reason: "too_large" };
  const channels = color === 6 ? 4 : color === 2 ? 3 : color === 4 ? 2 : color === 0 ? 1 : 0;
  if (depth !== 8 || interlace !== 0 || !channels) return { ok: false, reason: "unsupported" };

  const stride = width * channels;
  let raw: Buffer;
  try {
    raw = inflateSync(Buffer.concat(idat), { maxOutputLength: (stride + 1) * height + 1 });
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (raw.length !== (stride + 1) * height) return { ok: false, reason: "malformed" };

  // Undo the row filters and count ink: visible (alpha) and dark (not paper white).
  const prev = new Uint8Array(stride);
  const row = new Uint8Array(stride);
  let ink = 0, minX = width, maxX = -1, minY = height, maxY = -1;
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)]!;
    if (filter > 4) return { ok: false, reason: "malformed" };
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x]!;
      const a = x >= channels ? row[x - channels]! : 0;
      const b = prev[x]!;
      const c = x >= channels ? prev[x - channels]! : 0;
      let out: number;
      if (filter === 0) out = v;
      else if (filter === 1) out = v + a;
      else if (filter === 2) out = v + b;
      else if (filter === 3) out = v + ((a + b) >> 1);
      else {
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        out = v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
      }
      row[x] = out & 0xff;
    }
    for (let px = 0; px < width; px++) {
      const i = px * channels;
      const grey = channels >= 3 ? (row[i]! * 299 + row[i + 1]! * 587 + row[i + 2]! * 114) / 1000 : row[i]!;
      const alpha = channels === 4 ? row[i + 3]! : channels === 2 ? row[i + 1]! : 255;
      if (alpha > 96 && grey < 160) {
        ink++;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    prev.set(row);
  }
  const span = ink ? Math.max(maxX - minX + 1, maxY - minY + 1) : 0;
  if (ink < MIN_INK_PIXELS || span < MIN_INK_SPAN) return { ok: false, reason: "blank" };
  return { ok: true, width, height, ink, span };
}

export const isDrawnSignature = (value: unknown): value is string => checkDrawnSignature(value).ok;

/** What to tell the person signing when their drawing doesn't pass. */
export function drawnSignatureProblem(check: DrawnCheck): string | null {
  if (check.ok) return null;
  if (check.reason === "blank") return "Draw your signature in the box: it looks empty.";
  return "Draw your signature with your finger, mouse or stylus. A typed name or another picture can't be used.";
}
