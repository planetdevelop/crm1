// Planet Ops: the database's "someone else saved since you opened it" (code 40001, raised by
// save_estimate_version, approve_estimate_version, create_quote_from_estimate and
// refresh_quote_from_estimate) reaches the person as written, so they know to reload.
import { describe, expect, it } from "vitest";
import { friendlyDbError } from "../src/lib/errors";

describe("stale-save errors", () => {
  it("are shown as the database wrote them", () => {
    const e = friendlyDbError({ code: "40001", message: "Someone else saved this estimate since you opened it. Reload it to see their changes, then make yours." });
    expect(e.message).toMatch(/Someone else saved this estimate since you opened it/);
    expect(e.status).toBe(409);
  });
  it("but Postgres's own serialization failures aren't passed through", () => {
    expect(friendlyDbError({ code: "40001", message: "could not serialize access due to concurrent update" }).message).not.toMatch(/serialize/);
  });
});
