#!/usr/bin/env node
/**
 * Planet Ops Phase 3: does the app's estimate arithmetic (packages/core/src/estimating.ts) give the
 * same totals as the bid workbook? Reads an XLSX export of the workbook (never committed: it holds
 * the business's rates and customers), takes each job tab laid out like the current Bid Template,
 * runs its inputs (row 8's markup and owner %, and each line's Count, Hrs, Days, Unit $ and risk %)
 * through calculateEstimate, and compares base cost (F), markup (I), price before owner pay (J51),
 * owner pay (J52) and the final price (J53) with the workbook's own cached values, to the cent.
 * Prints counts and, for a mismatch, the tab's position and which figure differs (never its name).
 *
 *   node --experimental-strip-types scripts/estimating-parity.mjs path/to/bid-workbook.xlsx
 */
import { readFileSync } from "node:fs";
import JSZip from "jszip";
import { calculateEstimate } from "../packages/core/src/estimating.ts";

const path = process.argv[2];
if (!path) {
  console.error("Usage: node --experimental-strip-types scripts/estimating-parity.mjs <bid workbook .xlsx>");
  process.exit(2);
}
const zip = await JSZip.loadAsync(readFileSync(path));
const text = async (name) => (await zip.file(name)?.async("string")) ?? "";
const shared = [...(await text("xl/sharedStrings.xml")).matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => [...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join(""));
const workbook = await text("xl/workbook.xml");
const rels = await text("xl/_rels/workbook.xml.rels");
const sheets = [...workbook.matchAll(/<sheet [^>]*name="([^"]*)"[^>]*r:id="([^"]*)"/g)].map(([, name, rid]) => ({
  name,
  file: "xl/" + new RegExp(`Id="${rid}"[^>]*Target="([^"]*)"`).exec(rels)?.[1]?.replace(/^\/?xl\//, ""),
}));

/** A tab's cells: coordinate → cached value (number or string). */
async function cells(file) {
  const xml = await text(file);
  const out = new Map();
  for (const m of xml.matchAll(/<c r="([A-Z]+\d+)"([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
    const [, ref, attrs, body = ""] = m;
    const v = /<v>([\s\S]*?)<\/v>/.exec(body)?.[1];
    const inline = /<is>[\s\S]*?<t[^>]*>([\s\S]*?)<\/t>/.exec(body)?.[1];
    if (v === undefined && inline === undefined) continue;
    const type = /t="([^"]+)"/.exec(attrs)?.[1];
    out.set(ref, type === "s" ? shared[Number(v)] : type === "str" || type === "inlineStr" ? (v ?? inline) : Number(v));
  }
  return out;
}

const cents = (x) => Math.round(Number(x) * 100);
let compared = 0;
let matched = 0;
let skipped = 0;
const mismatches = [];
for (const [index, sheet] of sheets.entries()) {
  const c = await cells(sheet.file);
  // The current template's layout: rate settings in row 8, lines in rows 13–50, totals in row 51.
  const layout = c.get("A51") === "TOTAL PROJECT COST" && c.get("G7") === "Markup %" && c.get("I7") === "Owner %" && typeof c.get("J53") === "number";
  if (!layout) {
    skipped++;
    continue;
  }
  const lines = [];
  for (let row = 13; row <= 50; row++) {
    const hasInputs = ["B", "C", "D", "E"].some((col) => typeof c.get(`${col}${row}`) === "number");
    if (!hasInputs) continue;
    lines.push({ section: "other", name: String(c.get(`A${row}`) ?? `row ${row}`), count: c.get(`B${row}`) ?? 0, hours: c.get(`C${row}`) ?? 0, days: c.get(`D${row}`) ?? 0, unit: "each", unit_cost: c.get(`E${row}`) ?? 0, risk_pct: c.get(`G${row}`) ?? 0 });
  }
  const r = calculateEstimate(lines, { method: "markup", pct: c.get("G8") ?? 0, owner_pay: "percent_of_price", owner_pct: c.get("I8") ?? 0 });
  const want = { base: c.get("F51"), markup: c.get("I51"), price_before_owner_pay: c.get("J51"), owner_pay: c.get("J52"), selling_price: c.get("J53") };
  const off = Object.entries(want).filter(([k, v]) => typeof v === "number" && cents(v) !== cents(r[k]));
  compared++;
  if (off.length) mismatches.push({ tab: index + 1, figures: off.map(([k, v]) => `${k} (workbook ${cents(v) / 100}, app ${r[k]})`) });
  else matched++;
}
console.log(`Tabs in the workbook: ${sheets.length}. In the current template's layout: ${compared} (others skipped: ${skipped}).`);
console.log(`Matched to the cent on base, markup, price before owner pay, owner pay and final price: ${matched} of ${compared}.`);
for (const m of mismatches) console.log(`  tab #${m.tab}: ${m.figures.join("; ")}`);
