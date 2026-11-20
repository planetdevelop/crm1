/**
 * Drawn signatures and initials for the tests: real, complete PNG data URLs (8-bit RGBA, every chunk
 * with its checksum) of `width` x `height` with an ink stroke across them, as the signature pad
 * makes, so the server's full check (lib/drawnSignature.ts) decodes and accepts them. `tag` goes in a
 * text chunk so two drawings can be told apart. Sizes the pad never makes (too small, too large) are
 * still real PNG headers, refused by that check.
 *
 * test/fixtures/signaturePad.ts has signatures captured from the app's own pad.
 */
import { deflateSync } from "node:zlib";

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();
const crc32 = (bytes: Uint8Array) => {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
function chunk(type: string, body: Buffer) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(body.length, 0);
  head.write(type, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])), 0);
  return Buffer.concat([head, body, crc]);
}

/** A drawn signature of `width` x `height`: a stroke of ink across a transparent pad. */
export function drawnPng(width = 600, height = 180, tag = "") {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  // Sizes no pad makes: only the header and the end, refused before anything is decoded.
  const real = width > 0 && height > 0 && width * height <= 4_000_000;
  const parts = [Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr)];
  if (tag) parts.push(chunk("tEXt", Buffer.from(`Comment\0${tag}`, "latin1")));
  if (real) {
    const stride = width * 4 + 1;
    const raw = Buffer.alloc(stride * height);
    // A thick wavy stroke from left to right through the middle, in the pad's ink colour.
    const thick = Math.max(2, Math.round(height / 40));
    for (let x = Math.round(width * 0.1); x < Math.round(width * 0.9); x++) {
      const cy = Math.round(height / 2 + Math.sin(x / Math.max(8, width / 20)) * height * 0.2);
      for (let y = cy - thick; y <= cy + thick; y++) {
        if (y < 0 || y >= height) continue;
        const i = y * stride + 1 + x * 4;
        raw[i] = 0x0f;
        raw[i + 1] = 0x2a;
        raw[i + 2] = 0x35;
        raw[i + 3] = 255;
      }
    }
    parts.push(chunk("IDAT", deflateSync(raw)));
  }
  parts.push(chunk("IEND", Buffer.alloc(0)));
  return `data:image/png;base64,${Buffer.concat(parts).toString("base64")}`;
}
