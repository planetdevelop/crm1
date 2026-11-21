// Hosted Supabase (pg-safeupdate) refuses an UPDATE or DELETE without a WHERE clause, even inside a
// function: plain Postgres in the database tests doesn't, so this keeps Planet Ops migrations safe.
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const dir = fileURLToPath(new URL("../../../supabase/migrations/", import.meta.url));
const files = readdirSync(dir).filter((f) => f >= "20261120000000" && f.endsWith(".sql"));

describe("Planet Ops migrations", () => {
  it("have no UPDATE or DELETE without a WHERE clause", () => {
    const bad: string[] = [];
    for (const f of files) {
      // Statements end at ';'; strip comments first.
      const sql = readFileSync(dir + f, "utf8").replace(/--[^\n]*/g, "");
      for (const stmt of sql.split(";")) {
        const s = stmt.trim().replace(/\s+/g, " ");
        if (/^(delete from|update) /i.test(s) && !/\bwhere\b/i.test(s) && !/^update [\w.]+ set .* from /i.test(s)) bad.push(`${f}: ${s.slice(0, 80)}`);
      }
    }
    expect(bad).toEqual([]);
  });
});
