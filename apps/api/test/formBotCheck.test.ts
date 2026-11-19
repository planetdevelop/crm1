import { afterEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app";
import type { Env } from "../src/env";
import { encryptJson, verifyToken } from "../src/lib/crypto";
import { CHECK_MIN_AGE_MS, CHECK_USES, CHECK_VALID_SECONDS, checkScript, CLOUDFLARE_UNREACHABLE, CLOUDFLARE_UNSURE, newCheckToken, SECRET_WRONG, SITE_KEY_WRONG } from "../src/services/formBotCheck";

// A website form's bot check (services/formBotCheck.ts): Crewtavo's own script, or Cloudflare
// Turnstile with the business's keys, on contact and careers forms. A check only watches, noting
// what passed and what didn't, until an owner or admin tells the form to refuse messages without
// it. The database's part (who chooses the check, that only the server notes, counts and makes a
// form refuse, where the keys are kept) is in supabase/tests/form_bot_checks_test.sql. Cloudflare
// is never asked for real here.

const current = vi.hoisted(() => ({ db: null as unknown, background: [] as Array<Promise<unknown>>, emails: [] as Array<Record<string, unknown>> }));
vi.mock("../src/lib/supabase", async (original) => ({
  ...(await original<typeof import("../src/lib/supabase")>()),
  adminClient: () => current.db,
  userClient: () => current.db,
}));
vi.mock("../src/lib/background", () => ({
  runInBackground: (_c: unknown, work: Promise<unknown>) => void current.background.push(work),
  kickAutomations: () => undefined,
}));
vi.mock("../src/lib/notify", async (original) => ({
  ...(await original<typeof import("../src/lib/notify")>()),
  emailReady: async () => true,
  sendEmail: async (_env: unknown, message: Record<string, unknown>) => {
    current.emails.push(message);
    return { sent: true, id: "e1" };
  },
}));
vi.mock("../src/services/external", async (original) => ({ ...(await original<typeof import("../src/services/external")>()), geocodeAddress: async () => null }));

const env: Env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ENCRYPTION_KEY: btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i * 7))),
  APP_URL: "https://crm.greenlawn.example",
};
const COMPANY = "00000000-0000-4000-8000-000000000001";
const FORM_ID = "00000000-0000-4000-8000-0000000000f1";
const REQUEST_ID = "00000000-0000-4000-8000-0000000000e1";
const USER = "00000000-0000-4000-8000-0000000000aa";
const KEY = "3fa9c2d71b";
/** A form an owner or admin told to refuse: a message passed its check, and refusing was turned on. */
const ARMED = "2026-11-17T12:00:00.000Z";
const REFUSING = { bot_check_passed_at: "2026-11-17T11:00:00.000Z", bot_check_armed_at: ARMED };
const SITE_KEY = "0x4AAAAAAAB1cDeFgHiJkLmN";
const SECRET = "0x4AAAAAAAsecretsecretsecretsecret";

interface Query { table: string; calls: Array<[string, ...any[]]> }

const form = (changes: Record<string, unknown> = {}) => ({
  id: FORM_ID, key: KEY, kind: "contact", name: "Contact form", email_to: ["office@greenlawn.example"], redirect_url: null, allowed_sites: [],
  bot_check: "script", bot_check_armed_at: null,
  company: { id: COMPANY, name: "Green Lawn", settings: { website_forms: { enabled: true }, careers: { enabled: true } } },
  ...changes,
});

/** A database with Storage that answers by table and function, and remembers what was asked of it. It counts limits as the real limiter does. `role`: who's signed in (the owner, unless said). */
function fakeDb(answers: { tables?: Record<string, (q: Query) => unknown>; rpc?: Record<string, (args: any) => unknown>; role?: string } = {}) {
  const queries: Query[] = [];
  const rpcs: Array<{ name: string; args: any }> = [];
  const uploads: string[] = [];
  const hits = new Map<string, number>();
  const chain = (q: Query): unknown =>
    new Proxy(
      {},
      {
        get: (_, name) =>
          name === "then"
            ? (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) =>
                Promise.resolve()
                  .then(() => {
                    if (q.table === "memberships") return { data: { role: answers.role ?? "owner", role_id: null }, error: null };
                    const result = answers.tables?.[q.table]?.(q);
                    return result && typeof result === "object" && "error" in result ? result : { data: result ?? null, error: null };
                  })
                  .then(resolve, reject)
            : (...args: unknown[]) => {
                q.calls.push([String(name), ...args]);
                return chain(q);
              },
      },
    );
  current.db = {
    from: (table: string) => {
      const q: Query = { table, calls: [] };
      queries.push(q);
      return chain(q);
    },
    rpc: async (name: string, args: any) => {
      rpcs.push({ name, args });
      const fn = answers.rpc?.[name];
      if (fn) {
        const result = fn(args);
        return result && typeof result === "object" && "error" in (result as object) ? result : { data: result, error: null };
      }
      if (name === "rate_limit_hit") {
        const count = (hits.get(args.p_key) ?? 0) + 1;
        hits.set(args.p_key, count);
        return { data: count <= args.p_max, error: null };
      }
      return { data: null, error: null };
    },
    storage: {
      from: () => ({
        upload: async (path: string) => {
          uploads.push(path);
          return { data: { path }, error: null };
        },
        remove: async () => ({ data: [], error: null }),
      }),
    },
    auth: { getClaims: async () => ({ data: { claims: { sub: USER } }, error: null }) },
  };
  const named = (name: string) => rpcs.filter((r) => r.name === name);
  /** What was noted about the messages that were kept: each one's check, address and whether it passed. */
  const noted = () => named("website_form_check_noted").map((r) => r.args);
  /** What the form's row was changed to, if anything. */
  const formUpdates = () => queries.filter((q) => q.table === "website_forms").flatMap((q) => q.calls.filter(([call]) => call === "update").map(([, values]) => ({ values, calls: q.calls })));
  return { queries, rpcs, uploads, named, noted, formUpdates };
}

/** The business's form with its check, a database that makes the request, and its Turnstile keys when it has them. */
async function withForm(changes: Record<string, unknown> = {}, keys: boolean | "unreadable" = false, rpc: Record<string, (args: any) => unknown> = {}) {
  // Unreadable: sealed with another server's key, as after ENCRYPTION_KEY changed.
  const ciphertext = keys === "unreadable" ? await encryptJson({ ...env, ENCRYPTION_KEY: btoa("another server's key, 32 bytes!!x") }, { secret: SECRET }) : keys ? await encryptJson(env, { secret: SECRET }) : null;
  return fakeDb({
    tables: { website_forms: () => form(changes), website_form_turnstile: () => (ciphertext ? { site_key: SITE_KEY, ciphertext } : null) },
    rpc: {
      website_form_request: () => ({ request_id: REQUEST_ID, number: 7, client_id: "c1", property_id: null, new_property: false, matched: false }),
      job_application: (args) => ({ applicant_id: args.p_id }),
      ...rpc,
    },
  });
}

const post = (body: string | Record<string, unknown>, headers: Record<string, string> = {}) =>
  app.request(
    `/f/${KEY}`,
    {
      method: "POST",
      headers: { "Content-Type": typeof body === "string" ? "application/x-www-form-urlencoded" : "application/json", Origin: "https://www.greenlawn.example", ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    },
    env,
  );
const fields = (values: Record<string, string>) => new URLSearchParams(values).toString();
/** A token from a page that loaded this long ago. */
const tokenFrom = (msAgo = 60_000, key = KEY) => newCheckToken(env, key, null, Date.now() - msAgo);
/** The page asks for a token, handing over the one it has when it has one. */
const askToken = (was?: string, headers: Record<string, string> = {}) =>
  app.request(
    `/f/${KEY}/check`,
    { method: "POST", headers: { Origin: "https://www.greenlawn.example", ...(was === undefined ? {} : { "Content-Type": "application/x-www-form-urlencoded" }), ...headers }, body: was === undefined ? undefined : new URLSearchParams({ was }).toString() },
    env,
  );
const PASSED = { p_form: FORM_ID, p_check: "script", p_key: KEY, p_passed: true };
const MISSED = { ...PASSED, p_passed: false };
const settled = () => Promise.all(current.background);

/** Cloudflare, answering every ask the same way and remembering what it was asked. */
function cloudflare(answer: (() => Response) | "down") {
  const asked: Array<{ url: string; body: URLSearchParams }> = [];
  vi.stubGlobal("fetch", async (url: string, init?: { body?: URLSearchParams }) => {
    asked.push({ url: String(url), body: new URLSearchParams(init?.body) });
    if (answer === "down") throw new TypeError("fetch failed");
    return answer();
  });
  return asked;
}
const says = (body: unknown, status = 200) => () => Response.json(body, { status });

afterEach(() => {
  current.background.length = 0;
  current.emails.length = 0;
  vi.unstubAllGlobals();
});

describe("Crewtavo's own check", () => {
  it("only watches when it's turned on: a message without it is kept, and noted", async () => {
    const db = await withForm();
    const res = await post("email=jane%40example.com&message=Hi");
    expect(res.status).toBe(303);
    // Nor a forged one: the page may not have the line yet, and the message is still a lead.
    expect((await post(fields({ email: "gil@example.com", _check: "made.up" }))).status).toBe(303);
    expect(db.named("website_form_request")).toHaveLength(2);
    await settled();
    expect(db.noted()).toEqual([MISSED, MISSED]);
    expect(db.named("website_form_blocked")).toEqual([]);
    expect(db.formUpdates()).toEqual([]);
  });

  it("notes each message that passes, and never starts refusing by itself, however many pass", async () => {
    const db = await withForm();
    for (let i = 0; i < 6; i++) expect((await post(fields({ email: `jane${i}@example.com`, service: "Mowing", _check: await tokenFrom() }))).status).toBe(303);
    const made = db.named("website_form_request");
    expect(made).toHaveLength(6);
    // The token never becomes an answer.
    expect(made[0]!.args.p_answers).toEqual({ service: "Mowing" });
    await settled();
    expect(db.noted()).toEqual(Array(6).fill(PASSED));
    // Nothing writes to the form: refusing is an owner's or admin's to turn on, on the app's page.
    expect(db.formUpdates()).toEqual([]);
  });

  it("notes a pass only once the message is kept", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const db = await withForm({}, false, { website_form_request: () => ({ data: null, error: { message: "the database is away" } }) });
      expect((await post(fields({ email: "jane@example.com", _check: await tokenFrom() }))).status).toBe(500);
      await settled();
      expect(db.noted()).toEqual([]);
      // Nor for one that was sent back to the form.
      expect((await post(fields({ name: "Jane", _check: await tokenFrom() }))).status).toBe(422);
      await settled();
      expect(db.noted()).toEqual([]);
    } finally {
      error.mockRestore();
    }
  });

  it("once told to refuse, takes a message with a good token, from a form or from fetch()", async () => {
    const db = await withForm(REFUSING);
    expect((await post(fields({ email: "jane@example.com", _check: await tokenFrom() }))).status).toBe(303);
    const json = await post({ email: "kit@example.com", _check: await tokenFrom() }, { Accept: "application/json" });
    expect(json.status).toBe(200);
    expect(db.named("website_form_request")).toHaveLength(2);
    await settled();
    expect(db.noted()).toEqual([PASSED, PASSED]);
    expect(db.formUpdates()).toEqual([]);
  });

  it("once told to refuse, turns away a message without a token, in plain words with another way to reach the business, and counts it", async () => {
    const db = await withForm(REFUSING);
    const page = await post("email=jane%40example.com&message=Hi");
    expect(page.status).toBe(403);
    const html = await page.text();
    expect(html).toContain("Your message wasn't sent");
    expect(html).toContain("We couldn't check that a person sent this. Go back, reload the page and send it again, with JavaScript turned on in your browser. Or call us.");
    expect(html).toContain("Go back to the form");

    const json = await post({ email: "jane@example.com" }, { Accept: "application/json" });
    expect(json.status).toBe(403);
    expect(((await json.json()) as { ok: boolean }).ok).toBe(false);
    expect(json.headers.get("access-control-allow-origin")).toBe("*");

    expect(db.named("website_form_request")).toEqual([]);
    expect(current.emails).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked").map((r) => r.args)).toEqual([{ p_form: FORM_ID }, { p_form: FORM_ID }]);
    // Turned away, not kept: nothing to note about a kept message.
    expect(db.noted()).toEqual([]);
  });

  it("refuses a forged token, another form's, one that has run out, and one this server didn't sign", async () => {
    const db = await withForm(REFUSING);
    const good = await tokenFrom();
    const [body, mac] = good.split(".");
    const forged = `${btoa(JSON.stringify({ k: "form-check", f: KEY, n: "x", b: 0, exp: 9_999_999_999 })).replace(/=+$/, "")}.${mac}`;
    const otherServer = await newCheckToken({ ...env, ENCRYPTION_KEY: btoa("another server's key, 32 bytes!!x") }, KEY, null, Date.now() - 60_000);
    const ranOut = await tokenFrom((CHECK_VALID_SECONDS + 60) * 1000);
    for (const token of [forged, `${body}.AAAA`, "nonsense", await tokenFrom(60_000, "0therf0rm1"), otherServer, ranOut, "x".repeat(900)]) {
      const res = await post(fields({ email: "jane@example.com", _check: token }));
      expect(res.status, token.slice(0, 30)).toBe(403);
    }
    expect(db.named("website_form_request")).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked")).toHaveLength(7);
  });

  it("refuses one from a page that only just opened, and takes it a moment later", async () => {
    const db = await withForm(REFUSING);
    const token = await newCheckToken(env, KEY);
    const fast = await post(fields({ email: "jane@example.com", _check: token }));
    expect(fast.status).toBe(429);
    expect(await fast.text()).toContain("That was sent too fast for us to check it. Wait a few seconds and send it again, or call us.");
    expect(db.named("website_form_request")).toEqual([]);

    // The same token, once its page is old enough: being too fast didn't use it up.
    vi.useFakeTimers({ now: Date.now() + CHECK_MIN_AGE_MS + 500, toFake: ["Date"] });
    try {
      expect((await post(fields({ email: "jane@example.com", _check: token }))).status).toBe(303);
    } finally {
      vi.useRealTimers();
    }
    expect(db.named("website_form_request")).toHaveLength(1);
  });

  it("lets one page send three messages (a second one, a double-click, a try again), then asks for a reload", async () => {
    const db = await withForm(REFUSING);
    const token = await tokenFrom();
    expect(CHECK_USES).toBe(3);
    for (let i = 0; i < 3; i++) expect((await post(fields({ email: "jane@example.com", _check: token }))).status, `message ${i + 1}`).toBe(303);
    const fourth = await post(fields({ email: "jane@example.com", _check: token }));
    expect(fourth.status).toBe(403);
    expect(await fourth.text()).toContain("This page has sent as many messages as it can. To send another, go back, reload the page and send it again, or call us.");
    expect(db.named("website_form_request")).toHaveLength(3);
    const uses = db.named("rate_limit_hit").filter((r) => r.args.p_key.startsWith("form-check-used:"));
    expect(uses).toHaveLength(4);
    expect(new Set(uses.map((r) => `${r.args.p_key}|${r.args.p_max}|${r.args.p_window_seconds}`)).size).toBe(1);
    expect([uses[0]!.args.p_max, uses[0]!.args.p_window_seconds]).toEqual([3, 43_200]);
  });

  it("doesn't take a use from a token for a message that wasn't ready to keep", async () => {
    const db = await withForm(REFUSING);
    const token = await tokenFrom();
    // No email or phone: sent back to the form, where the same page sends it again.
    expect((await post(fields({ name: "Jane", _check: token }))).status).toBe(422);
    expect(db.named("rate_limit_hit").some((r) => r.args.p_key.startsWith("form-check-used:"))).toBe(false);
    expect((await post(fields({ name: "Jane", email: "jane@example.com", _check: token }))).status).toBe(303);
    expect(db.named("website_form_request")).toHaveLength(1);
  });

  it("counts a message with the hidden field filled in, whatever the form's check", async () => {
    for (const check of ["off", "script"]) {
      const db = await withForm({ bot_check: check, ...(check === "off" ? {} : REFUSING) });
      const res = await post("email=bot%40spam.example&_gotcha=x");
      expect(res.status).toBe(303);
      expect(db.named("website_form_request")).toEqual([]);
      await settled();
      expect(db.named("website_form_blocked")).toHaveLength(1);
      expect(db.noted()).toEqual([]);
    }
  });

  it("checks nothing on a form with no check, and neither notes nor counts there", async () => {
    const db = await withForm({ bot_check: "off" });
    expect((await post("email=jane%40example.com")).status).toBe(303);
    expect((await post("name=Jane")).status).toBe(422);
    expect(db.formUpdates()).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked")).toEqual([]);
    expect(db.noted()).toEqual([]);
    // A form from before the check (an older database) reads as no check.
    const old = await withForm({ bot_check: undefined, bot_check_armed_at: undefined });
    expect((await post("email=jane%40example.com")).status).toBe(303);
    expect(old.named("website_form_request")).toHaveLength(1);
  });

  it("gives a message its place in the business's limit only after the check", async () => {
    // A hundred an hour for the business: what the check turns away doesn't count toward it.
    const db = await withForm(REFUSING);
    await post("email=jane%40example.com");
    expect(db.named("rate_limit_hit").some((r) => r.args.p_key.startsWith("website-form:company:"))).toBe(false);
    await post(fields({ email: "jane@example.com", _check: await tokenFrom() }));
    expect(db.named("rate_limit_hit").some((r) => r.args.p_key.startsWith("website-form:company:"))).toBe(true);
  });
});

describe("a page that asks for a new token", () => {
  type Read = { k: string; f: string; n: string; b: number; exp: number };
  const read = (token: string) => verifyToken<Read>(env, token);
  const asked = async (was?: string) => ((await (await askToken(was)).json()) as { token: string }).token;

  it("keeps its age when it hands over the one it has: Back, the half-hourly refresh and a tab waking up aren't a new page", async () => {
    const db = await withForm(REFUSING);
    const first = await tokenFrom(45_000);
    const second = await asked(first);
    expect(second).not.toBe(first);
    const [was, now] = [await read(first), await read(second)];
    expect(now!.b).toBe(was!.b);
    expect(now!.n).not.toBe(was!.n);
    expect(now!.exp).toBeGreaterThan(was!.exp);
    // Sent at once with the new token: not "too fast", though the token is a moment old.
    expect((await post(fields({ email: "jane@example.com", _check: second }))).status).toBe(303);
    // And again from the token after that.
    expect((await read(await asked(second)))!.b).toBe(was!.b);
    expect(db.named("website_form_request")).toHaveLength(1);
  });

  it("keeps its age from a token that has run out, as after a night with the tab asleep", async () => {
    await withForm(REFUSING);
    const old = await tokenFrom((CHECK_VALID_SECONDS + 3600) * 1000);
    // Run out: it sends nothing itself any more.
    expect(await read(old)).toBeNull();
    expect((await post(fields({ email: "jane@example.com", _check: old }))).status).toBe(403);
    const fresh = await asked(old);
    const born = (await verifyToken<Read>(env, old, { expired: true }))!.b;
    expect((await read(fresh))!.b).toBe(born);
    expect((await post(fields({ email: "jane@example.com", _check: fresh }))).status).toBe(303);
  });

  it("starts as a new page with no token, or one that isn't this form's", async () => {
    await withForm(REFUSING);
    const before = Date.now();
    const forged = `${btoa(JSON.stringify({ k: "form-check", f: KEY, n: "x", b: 0, exp: 9_999_999_999 })).replace(/=+$/, "")}.AAAA`;
    const otherServer = await newCheckToken({ ...env, ENCRYPTION_KEY: btoa("another server's key, 32 bytes!!x") }, KEY, null, 0);
    for (const was of [undefined, "", "nonsense", forged, otherServer, await tokenFrom(60_000, "0therf0rm1"), "x".repeat(5000)]) {
      const token = await asked(was);
      expect((await read(token))!.b, String(was).slice(0, 20)).toBeGreaterThanOrEqual(before);
    }
    // So a message sent the moment it arrives is still too fast.
    expect((await post(fields({ email: "jane@example.com", _check: await asked("nonsense") }))).status).toBe(429);
    // A token that says it was born tomorrow isn't believed either.
    const tomorrow = await newCheckToken(env, KEY, null, Date.now() + 86_400_000);
    expect((await read(await asked(tomorrow)))!.b).toBeLessThan(Date.now() + 1000);
  });
});

describe("a careers form's check", () => {
  const apply = (values: Record<string, string | File>) => {
    const body = new FormData();
    for (const [name, value] of Object.entries(values)) body.append(name, value);
    return app.request(`/f/${KEY}`, { method: "POST", headers: { Origin: "https://www.greenlawn.example" }, body }, env);
  };
  const resume = () => new File([new Uint8Array(2048)], "Resume.pdf", { type: "application/pdf" });

  it("once told to refuse, turns away an application without the check before any file is stored", async () => {
    const db = await withForm({ kind: "careers", ...REFUSING });
    const res = await apply({ name: "Jane Smith", email: "jane@example.com", resume: resume() });
    expect(res.status).toBe(403);
    const html = await res.text();
    expect(html).toContain("Your application wasn't sent");
    expect(html).toContain("Or call us.");
    expect(db.uploads).toEqual([]);
    expect(db.named("job_application")).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked")).toHaveLength(1);
  });

  it("takes one with a good token, résumé and all, and notes it; and keeps and notes one without while it only watches", async () => {
    const db = await withForm({ kind: "careers" });
    const res = await apply({ name: "Jane Smith", email: "jane@example.com", resume: resume(), _check: await tokenFrom() });
    expect(res.status).toBe(303);
    expect(db.uploads).toHaveLength(1);
    const made = db.named("job_application");
    expect(made).toHaveLength(1);
    expect(made[0]!.args.p_answers).toEqual({});
    expect((await apply({ name: "Gil Park", email: "gil@example.com", resume: resume() })).status).toBe(303);
    expect(db.uploads).toHaveLength(2);
    await settled();
    expect(db.noted()).toEqual([PASSED, MISSED]);
    expect(db.formUpdates()).toEqual([]);
  });

  it("says how many applications a page can send", async () => {
    await withForm({ kind: "careers", ...REFUSING });
    const token = await tokenFrom();
    for (let i = 0; i < 3; i++) expect((await apply({ name: "Jane Smith", email: "jane@example.com", _check: token })).status).toBe(303);
    expect(await (await apply({ name: "Jane Smith", email: "jane@example.com", _check: token })).text()).toContain("This page has sent as many applications as it can.");
  });

  it("counts a filled-in hidden field", async () => {
    const db = await withForm({ kind: "careers", bot_check: "off" });
    expect((await apply({ name: "Bot", email: "bot@spam.example", _gotcha: "x" })).status).toBe(303);
    expect(db.named("job_application")).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked")).toHaveLength(1);
  });
});

describe("Cloudflare Turnstile", () => {
  const answered = { email: "jane@example.com", "cf-turnstile-response": "widget-answer" };
  const T_PASSED = { ...PASSED, p_check: "turnstile" };
  const T_MISSED = { ...MISSED, p_check: "turnstile" };

  it("asks Cloudflare with the business's secret key, and notes a message it vouches for", async () => {
    const db = await withForm({ bot_check: "turnstile" }, true);
    const asked = cloudflare(says({ success: true }));
    const res = await post(fields(answered), { "X-Forwarded-For": "203.0.113.7" });
    expect(res.status).toBe(303);
    expect(asked).toHaveLength(1);
    expect(asked[0]!.url).toBe("https://challenges.cloudflare.com/turnstile/v0/siteverify");
    expect(asked[0]!.body.get("secret")).toBe(SECRET);
    expect(asked[0]!.body.get("response")).toBe("widget-answer");
    const made = db.named("website_form_request");
    expect(made).toHaveLength(1);
    expect(made[0]!.args.p_answers).toEqual({});
    await settled();
    expect(db.noted()).toEqual([T_PASSED]);
    // Passing doesn't make the form refuse.
    expect(db.formUpdates()).toEqual([]);
  });

  it("only watches when it's turned on: messages Cloudflare doesn't vouch for are kept, and noted", async () => {
    const db = await withForm({ bot_check: "turnstile" }, true);
    const asked = cloudflare(says({ success: false, "error-codes": ["invalid-input-response"] }));
    expect((await post("email=jane%40example.com")).status).toBe(303);
    expect((await post(fields(answered))).status).toBe(303);
    expect(asked).toHaveLength(1);
    expect(db.named("website_form_request")).toHaveLength(2);
    await settled();
    expect(db.noted()).toEqual([T_MISSED, T_MISSED]);
    expect(db.formUpdates()).toEqual([]);
  });

  it("once told to refuse, turns away a message Cloudflare doesn't vouch for, or one with no answer, and says what to do", async () => {
    const db = await withForm({ bot_check: "turnstile", ...REFUSING }, true);
    const asked = cloudflare(says({ success: false, "error-codes": ["timeout-or-duplicate"] }));
    const failed = await post(fields(answered));
    expect(failed.status).toBe(403);
    // A spent answer looks finished to the visitor: reload, and another way if the check never shows.
    expect(await failed.text()).toContain("We couldn't confirm you're a person. Go back, reload the page, finish the check above the button and send it again. If no check shows up there, call us instead.");
    const none = await post("email=jane%40example.com");
    expect(none.status).toBe(403);
    // Nothing to ask Cloudflare about.
    expect(asked).toHaveLength(1);
    expect(db.named("website_form_request")).toEqual([]);
    await settled();
    expect(db.named("website_form_blocked")).toHaveLength(2);
    expect(db.noted()).toEqual([]);
  });

  it("lets a message through when Cloudflare can't be reached or the keys stopped working, and notes nothing: a lead matters more than a bot", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      for (const answer of ["down", says({ success: false, "error-codes": ["invalid-input-secret"] }), says({ success: false, "error-codes": ["internal-error"] }), says("<html>Bad gateway</html>", 502)] as const) {
        const db = await withForm({ bot_check: "turnstile", ...REFUSING }, true);
        cloudflare(answer);
        expect((await post(fields(answered))).status).toBe(303);
        expect(db.named("website_form_request")).toHaveLength(1);
        await settled();
        expect(db.named("website_form_blocked")).toEqual([]);
        // Not a pass, and not a page without the line: nothing was learned.
        expect(db.noted()).toEqual([]);
      }
      expect(warn).toHaveBeenCalledTimes(4);
    } finally {
      warn.mockRestore();
    }
  });

  it("checks nothing for a business whose keys are gone, and says so loudly when they're there but can't be read", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const gone = await withForm({ bot_check: "turnstile", ...REFUSING }, false);
      const asked = cloudflare(says({ success: true }));
      expect((await post("email=jane%40example.com")).status).toBe(303);
      expect(gone.named("website_form_request")).toHaveLength(1);
      expect(warn).not.toHaveBeenCalled();

      // Sealed with a key this server doesn't have any more.
      const unreadable = await withForm({ bot_check: "turnstile", ...REFUSING }, "unreadable");
      expect((await post(fields(answered))).status).toBe(303);
      expect(unreadable.named("website_form_request")).toHaveLength(1);
      expect(warn).toHaveBeenCalledTimes(1);
      expect(String(warn.mock.calls[0]![0])).toContain("can't be read any more");
      expect(asked).toEqual([]);
      await settled();
      expect(unreadable.noted()).toEqual([]);
    } finally {
      warn.mockRestore();
    }
  });
});

describe("the script on the business's page", () => {
  it("is served as JavaScript any website can load, for a form that's taking messages", async () => {
    await withForm();
    const res = await app.request(`/f/${KEY}/check.js`, {}, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/javascript; charset=utf-8");
    expect(res.headers.get("cache-control")).toBe("public, max-age=300");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("cross-origin-resource-policy")).toBeNull();
    const js = await res.text();
    expect(js).toContain(`"https://crm.greenlawn.example/f/${KEY}/check"`);
    expect(js).toContain('"_check"');

    fakeDb({ tables: { website_forms: () => null } });
    const gone = await app.request(`/f/${KEY}/check.js`, {}, env);
    expect(gone.status).toBe(404);
    expect(gone.headers.get("content-type")).toBe("text/javascript; charset=utf-8");
  });

  /** A page with this form and another service's, a clock, and what the script asked for. `storage`: the tab's sessionStorage, when the browser allows one. */
  function page(storage?: Map<string, string> | "refused") {
    const makeForm = (action: string) => {
      const inputs: Array<{ type: string; name: string; value: string }> = [];
      return { inputs, getAttribute: (name: string) => (name === "action" ? action : null), querySelector: () => inputs.find((i) => i.name === "_check") ?? null, appendChild: (input: { type: string; name: string; value: string }) => void inputs.push(input) };
    };
    const forms = [makeForm(`https://crm.greenlawn.example/f/${KEY}`), makeForm("https://formspree.io/f/abcdwxyz")];
    const listeners: Record<string, Array<(event: { persisted?: boolean; target?: unknown }) => void>> = {};
    const listen = (name: string, fn: (event: { persisted?: boolean; target?: unknown }) => void) => void (listeners[name] ??= []).push(fn);
    const asks: Array<{ url: string; method?: string; type?: string; body?: string }> = [];
    const timers: Array<{ fn: () => void; ms: number }> = [];
    const state = { now: Date.UTC(2026, 10, 17), n: 0, failing: false };
    class Clock { getTime() { return state.now; } }
    const fetch = async (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }) => {
      asks.push({ url, method: init?.method, type: init?.headers?.["Content-Type"], body: init?.body });
      if (state.failing) throw new TypeError("offline");
      return { ok: true, json: async () => ({ token: `token-${++state.n}` }) };
    };
    const win: Record<string, unknown> = { fetch: true, addEventListener: listen };
    // Some browsers throw at the very mention of storage (cookies blocked, a sandboxed frame).
    if (storage === "refused") Object.defineProperty(win, "sessionStorage", { get: () => { throw new Error("SecurityError"); } });
    else if (storage) win.sessionStorage = { getItem: (key: string) => storage.get(key) ?? null, setItem: (key: string, value: string) => void storage.set(key, value) };
    const run = () => {
      new Function("document", "window", "fetch", "setInterval", "setTimeout", "Date", checkScript(`https://crm.greenlawn.example/f/${KEY}/check`, KEY))(
        { getElementsByTagName: () => forms, createElement: () => ({ type: "", name: "", value: "" }), addEventListener: listen },
        win,
        fetch,
        () => 0,
        (fn: () => void, ms: number) => void timers.push({ fn, ms }),
        Clock,
      );
    };
    const fire = (name: string, event: { persisted?: boolean; target?: unknown } = {}) => { for (const fn of listeners[name] ?? []) fn(event); };
    const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
    return { forms, makeForm, asks, timers, state, run, fire, tick };
  }

  it("gets a token as the page loads and puts it in this form, and only this form, including one drawn later", async () => {
    const p = page();
    p.run();
    await p.tick();
    // The first ask is a bare POST: nothing to hand over yet.
    expect(p.asks).toEqual([{ url: `https://crm.greenlawn.example/f/${KEY}/check`, method: "POST", type: undefined, body: undefined }]);
    expect(p.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-1" }]);
    expect(p.forms[1]!.inputs).toEqual([]);

    // A form drawn after the page loaded gets its field as it's sent.
    const later = p.makeForm(`/f/${KEY}`);
    p.forms.push(later);
    p.fire("submit", { target: later });
    expect(later.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-1" }]);
  });

  it("asks for a new token a moment after the form is sent, handing over the one it has, so a page that stays open can send again", async () => {
    const p = page();
    p.run();
    await p.tick();
    // Another service's form being sent is none of its business.
    p.fire("submit", { target: p.forms[1] });
    expect(p.timers).toEqual([]);
    p.fire("submit", { target: p.forms[0] });
    expect(p.timers.map((t) => t.ms)).toEqual([1500]);
    // Not yet: what's being sent goes with the token it has.
    expect(p.asks).toHaveLength(1);
    p.timers[0]!.fn();
    await p.tick();
    // A plain form post, which any website may send without asking first.
    expect(p.asks[1]).toEqual({ url: `https://crm.greenlawn.example/f/${KEY}/check`, method: "POST", type: "application/x-www-form-urlencoded", body: "was=token-1" });
    expect(p.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-2" }]);
  });

  it("asks again when the page comes Back, and when its token is half an hour old, with the old one each time", async () => {
    const p = page();
    p.run();
    await p.tick();
    p.fire("pageshow", { persisted: false });
    p.fire("focusin");
    expect(p.asks).toHaveLength(1);
    p.fire("pageshow", { persisted: true });
    await p.tick();
    expect(p.asks[1]!.body).toBe("was=token-1");
    p.state.now += 31 * 60_000;
    p.fire("focusin");
    await p.tick();
    expect(p.asks[2]!.body).toBe("was=token-2");
    expect(p.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-3" }]);
  });

  it("keeps its token for the tab, so a page loaded afresh on Back or reloaded hands over the one it had", async () => {
    const tab = new Map<string, string>();
    const first = page(tab);
    first.run();
    await first.tick();
    expect([...tab]).toEqual([[`crewtavo-check:/f/${KEY}`, "token-1"]]);
    // The same tab loads the page again: a new page to the script, but not to the server.
    const again = page(tab);
    again.run();
    await again.tick();
    expect(again.asks).toEqual([{ url: `https://crm.greenlawn.example/f/${KEY}/check`, method: "POST", type: "application/x-www-form-urlencoded", body: "was=token-1" }]);
    expect(again.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-1" }]);

    // A browser that won't give it storage: it works as a new page each time, and nothing breaks.
    const strict = page("refused");
    strict.run();
    await strict.tick();
    expect(strict.asks).toEqual([{ url: `https://crm.greenlawn.example/f/${KEY}/check`, method: "POST", type: undefined, body: undefined }]);
    expect(strict.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-1" }]);
  });

  it("waits a minute after an ask that failed, so a page can't use up its visitor's asks", async () => {
    const p = page();
    p.state.failing = true;
    p.run();
    await p.tick();
    expect(p.asks).toHaveLength(1);
    // Every click into the form would ask again.
    for (let i = 0; i < 20; i++) p.fire("focusin");
    await p.tick();
    expect(p.asks).toHaveLength(1);
    p.state.now += 61_000;
    p.state.failing = false;
    p.fire("focusin");
    await p.tick();
    expect(p.asks).toHaveLength(2);
    expect(p.forms[0]!.inputs).toEqual([{ type: "hidden", name: "_check", value: "token-1" }]);
    // Coming Back to the page asks at once, whatever failed before.
    p.state.failing = true;
    p.state.now += 31 * 60_000;
    p.fire("focusin");
    await p.tick();
    expect(p.asks).toHaveLength(3);
    p.state.failing = false;
    p.fire("pageshow", { persisted: true });
    await p.tick();
    expect(p.asks).toHaveLength(4);
  });

  it("is given a token signed for this form, from any website", async () => {
    await withForm();
    const before = Date.now();
    const res = await askToken();
    expect(res.status).toBe(200);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    expect(res.headers.get("cache-control")).toBe("no-store");
    const { token } = (await res.json()) as { token: string };
    const read = await verifyToken<{ k: string; f: string; n: string; b: number; exp: number }>(env, token);
    expect(read).toMatchObject({ k: "form-check", f: KEY });
    expect(read!.b).toBeGreaterThanOrEqual(before);
    expect(read!.exp - Math.floor(read!.b / 1000)).toBe(12 * 60 * 60);
    expect(read!.n).toMatch(/^[\w-]{12}$/);

    const preflight = await app.request(`/f/${KEY}/check`, { method: "OPTIONS", headers: { Origin: "https://www.greenlawn.example" } }, env);
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("gives none to a website the form doesn't list, an address that isn't a form, or a visitor who asks without end", async () => {
    await withForm({ allowed_sites: ["greenlawn.example"] });
    expect((await askToken()).status).toBe(200);
    const elsewhere = await askToken(undefined, { Origin: "https://copycat.example" });
    expect(elsewhere.status).toBe(403);
    expect(await elsewhere.json()).toEqual({ ok: false, error: "This form only takes messages from its own website." });

    fakeDb({ tables: { website_forms: () => null } });
    expect((await app.request(`/f/${KEY}/check`, { method: "POST" }, env)).status).toBe(404);

    const db = await withForm();
    let last = 0;
    for (let i = 0; i < 61; i++) last = (await app.request(`/f/${KEY}/check`, { method: "POST" }, env)).status;
    expect(last).toBe(429);
    const limit = db.named("rate_limit_hit")[0]!.args;
    expect(limit.p_key).toMatch(/^form-check:ip:/);
    expect([limit.p_max, limit.p_window_seconds]).toEqual([60, 3600]);
  });
});

describe("the app's page", () => {
  const headers = { Authorization: "Bearer token", "X-Company-Id": COMPANY, "Content-Type": "application/json" };
  const row = {
    id: FORM_ID, key: KEY, name: "Contact form", email_to: [], redirect_url: null, allowed_sites: [], bot_check: "script",
    bot_check_passed_at: "2026-11-17T11:00:00.000Z", bot_check_missed: 4, bot_check_missed_at: "2026-11-17T10:00:00.000Z", bot_check_armed_at: null as string | null,
    bots_blocked: 12, last_blocked_at: ARMED, created_at: "2026-10-26T00:00:00Z",
  };
  const patch = (body: Record<string, unknown>) => app.request(`/api/website-forms/${FORM_ID}`, { method: "PATCH", headers, body: JSON.stringify(body) }, env);
  /** A form's row that changes as it's written to, so what's read after is what was saved. */
  const kept = (start: Record<string, unknown>) => {
    const state = { ...start };
    return (q: Query) => {
      const update = q.calls.find(([call]) => call === "update");
      if (update) Object.assign(state, update[1]);
      return state;
    };
  };

  it("lists each form's check and what it has seen, with the business's site key and never its secret", async () => {
    const ciphertext = await encryptJson(env, { secret: SECRET });
    fakeDb({
      tables: {
        companies: () => ({ settings: { website_forms: { enabled: true } } }),
        website_forms: () => [row],
        website_form_turnstile: () => ({ site_key: SITE_KEY, ciphertext }),
      },
    });
    const res = await app.request("/api/website-forms", { headers }, env);
    const body = (await res.json()) as { turnstile_site_key: string; turnstile_keys_unreadable: boolean; forms: Array<Record<string, unknown>> };
    expect(body.turnstile_site_key).toBe(SITE_KEY);
    expect(body.turnstile_keys_unreadable).toBe(false);
    expect(body.forms[0]).toMatchObject({ bot_check: "script", bot_check_passed_at: row.bot_check_passed_at, bot_check_missed: 4, bot_check_missed_at: row.bot_check_missed_at, bot_check_armed_at: null, bots_blocked: 12, last_blocked_at: ARMED });
    expect(JSON.stringify(body)).not.toContain(ciphertext);
    expect(JSON.stringify(body)).not.toContain(SECRET);
  });

  it("says when the business's keys are saved but can't be read any more, so the page asks for them again", async () => {
    const ciphertext = await encryptJson({ ...env, ENCRYPTION_KEY: btoa("another server's key, 32 bytes!!x") }, { secret: SECRET });
    const tables = { companies: () => ({ settings: { website_forms: { enabled: true } } }), website_forms: () => [row], website_form_turnstile: () => ({ site_key: SITE_KEY, ciphertext }) };
    fakeDb({ tables });
    const body = (await (await app.request("/api/website-forms", { headers }, env)).json()) as { turnstile_site_key: string; turnstile_keys_unreadable: boolean };
    expect(body).toMatchObject({ turnstile_site_key: SITE_KEY, turnstile_keys_unreadable: true });

    // And Turnstile can't be turned on for a form until they are.
    const db = fakeDb({ tables: { ...tables, website_forms: () => row } });
    const res = await patch({ bot_check: "turnstile" });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toBe("This Planet Ops can't read your Turnstile keys any more. Enter them again, then turn it on for this form.");
    expect(db.formUpdates()).toEqual([]);

    fakeDb({ tables: { companies: tables.companies, website_forms: tables.website_forms } });
    expect(await (await app.request("/api/website-forms", { headers }, env)).json()).toMatchObject({ turnstile_site_key: null, turnstile_keys_unreadable: false });
  });

  it("saves a form's check, and Turnstile only once the business has keys", async () => {
    const db = fakeDb({ tables: { website_forms: () => row } });
    expect((await patch({ bot_check: "script" })).status).toBe(200);
    expect(db.formUpdates().map((u) => u.values)).toEqual([{ bot_check: "script" }]);

    const none = await patch({ bot_check: "turnstile" });
    expect(none.status).toBe(400);
    expect(((await none.json()) as { error: string }).error).toBe("Add your Cloudflare Turnstile keys first, then turn it on for this form.");
    expect(db.formUpdates()).toHaveLength(1);
    expect((await patch({ bot_check: "captcha" })).status).toBe(400);

    const ciphertext = await encryptJson(env, { secret: SECRET });
    const withKeys = fakeDb({ tables: { website_forms: () => row, website_form_turnstile: () => ({ site_key: SITE_KEY, ciphertext }) } });
    expect((await patch({ bot_check: "turnstile" })).status).toBe(200);
    expect(withKeys.formUpdates().map((u) => u.values)).toEqual([{ bot_check: "turnstile" }]);
  });

  describe("refusing messages without the check", () => {
    it("is turned on by an owner or admin, once a message has come through with it", async () => {
      const db = fakeDb({ tables: { website_forms: kept(row) } });
      const res = await patch({ bot_check_refuses: true });
      expect(res.status).toBe(200);
      const saved = (await res.json()) as { bot_check_armed_at: string; url: string };
      expect(Date.parse(saved.bot_check_armed_at)).toBeGreaterThan(Date.now() - 5000);
      expect(saved.url).toBe(`https://crm.greenlawn.example/f/${KEY}`);
      const writes = db.formUpdates();
      expect(writes).toHaveLength(1);
      expect(Object.keys(writes[0]!.values)).toEqual(["bot_check_armed_at"]);
      // For this business's form only, while it still has a check a message has passed, and not again once it's on.
      expect(writes[0]!.calls).toEqual(expect.arrayContaining([
        ["eq", "id", FORM_ID], ["eq", "company_id", COMPANY], ["neq", "bot_check", "off"], ["not", "bot_check_passed_at", "is", null], ["is", "bot_check_armed_at", null],
      ]));
    });

    it("can't be turned on before a message has passed the check, on a form with no check, or along with a new check", async () => {
      const said = async (res: Response) => [res.status, ((await res.json()) as { error: string }).error];
      const waiting = fakeDb({ tables: { website_forms: kept({ ...row, bot_check_passed_at: null }) } });
      expect(await said(await patch({ bot_check_refuses: true }))).toEqual([400, "No message has come through with the check yet. Send a test from your website first, then turn this on."]);
      expect(waiting.formUpdates()).toEqual([]);

      const off = fakeDb({ tables: { website_forms: kept({ ...row, bot_check: "off", bot_check_passed_at: null }) } });
      expect(await said(await patch({ bot_check_refuses: true }))).toEqual([400, "This form has no check for a message to come without. Choose one first."]);
      expect(off.formUpdates()).toEqual([]);

      const ciphertext = await encryptJson(env, { secret: SECRET });
      const changing = fakeDb({ tables: { website_forms: kept(row), website_form_turnstile: () => ({ site_key: SITE_KEY, ciphertext }) } });
      expect(await said(await patch({ bot_check: "turnstile", bot_check_refuses: true }))).toEqual([400, "A check that was just changed hasn't seen a message yet. Save it, send a test from your website, then turn this on."]);
      // Neither half was saved.
      expect(changing.formUpdates()).toEqual([]);

      // The check changed between the look and the write (the database started it over): it didn't take, and says so.
      const raced = fakeDb({ tables: { website_forms: (q) => (q.calls.some(([call]) => call === "update") ? null : row) } });
      expect(await said(await patch({ bot_check_refuses: true }))).toEqual([400, "No message has come through with the check yet. Send a test from your website first, then turn this on."]);
      expect(raced.formUpdates()).toHaveLength(1);
    });

    it("is turned off again, and other changes save alongside either", async () => {
      const db = fakeDb({ tables: { website_forms: kept({ ...row, bot_check_armed_at: ARMED }) } });
      const res = await patch({ bot_check_refuses: false, name: "Quote form" });
      expect(res.status).toBe(200);
      expect(await res.json()).toMatchObject({ name: "Quote form", bot_check_armed_at: null });
      expect(db.formUpdates().map((u) => u.values)).toEqual([{ name: "Quote form" }, { bot_check_armed_at: null }]);
      expect(db.formUpdates()[1]!.calls).toEqual(expect.arrayContaining([["eq", "id", FORM_ID], ["eq", "company_id", COMPANY]]));

      // Saying the same check again isn't changing it.
      fakeDb({ tables: { website_forms: kept(row) } });
      expect((await patch({ bot_check: "script", bot_check_refuses: true })).status).toBe(200);
    });

    it("isn't for office staff or crews: only the people who connect apps decide what a form refuses", async () => {
      for (const role of ["office", "estimator", "crew_lead", "field_crew"]) {
        const db = fakeDb({ role, tables: { website_forms: kept(row) } });
        expect((await patch({ bot_check_refuses: true })).status, role).toBe(403);
        expect((await patch({ bot_check_refuses: false })).status, role).toBe(403);
        expect(db.formUpdates()).toEqual([]);
      }
    });
  });

  describe("the business's Turnstile keys", () => {
    const put = (body: Record<string, unknown>) => app.request("/api/website-forms/turnstile", { method: "PUT", headers, body: JSON.stringify(body) }, env);
    const saves = (db: ReturnType<typeof fakeDb>) => db.queries.filter((q) => q.table === "website_form_turnstile").flatMap((q) => q.calls.filter(([call]) => call === "upsert").map(([, values]) => values));

    it("are saved once Cloudflare has taken the secret key, which is kept encrypted", async () => {
      const db = fakeDb();
      // A made-up answer: a good secret is told the answer is wrong, not the secret.
      const asked = cloudflare(says({ success: false, "error-codes": ["invalid-input-response"] }));
      const res = await put({ site_key: ` ${SITE_KEY} `, secret_key: ` ${SECRET} ` });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ turnstile_site_key: SITE_KEY });
      expect(asked).toHaveLength(1);
      expect(asked[0]!.body.get("secret")).toBe(SECRET);
      expect(asked[0]!.body.get("response")).toBe("test");
      const saved = saves(db);
      expect(saved).toHaveLength(1);
      expect(saved[0]).toMatchObject({ company_id: COMPANY, site_key: SITE_KEY });
      expect(saved[0].ciphertext).toMatch(/^v1\./);
      expect(JSON.stringify(saved[0])).not.toContain(SECRET);

      // Cloudflare's own test keys pass any answer: proof enough too.
      const testing = fakeDb();
      cloudflare(says({ success: true }));
      expect((await put({ site_key: "1x00000000000000000000AA", secret_key: "1x0000000000000000000000000000000AA" })).status).toBe(200);
      expect(saves(testing)).toHaveLength(1);
    });

    it("aren't saved unless Cloudflare proved the secret key: not when it doesn't know it, can't be reached, or answers something else", async () => {
      const db = fakeDb();
      const said = async (res: Response) => [res.status, ((await res.json()) as { error: string }).error];
      cloudflare(says({ success: false, "error-codes": ["invalid-input-secret"] }));
      expect(await said(await put({ site_key: SITE_KEY, secret_key: "not-the-secret" }))).toEqual([400, SECRET_WRONG]);

      cloudflare("down");
      expect(await said(await put({ site_key: SITE_KEY, secret_key: SECRET }))).toEqual([502, CLOUDFLARE_UNREACHABLE]);

      // Cloudflare's own trouble, or an answer nobody expected, proves nothing about the key.
      for (const answer of [says({ success: false, "error-codes": ["internal-error"] }), says({ success: false, "error-codes": [] }), says({ success: false })]) {
        cloudflare(answer);
        expect(await said(await put({ site_key: SITE_KEY, secret_key: SECRET }))).toEqual([502, CLOUDFLARE_UNSURE]);
      }
      cloudflare(says("<html>Bad gateway</html>", 502));
      expect(await said(await put({ site_key: SITE_KEY, secret_key: SECRET }))).toEqual([502, CLOUDFLARE_UNREACHABLE]);

      const asked = cloudflare(says({ success: false, "error-codes": ["invalid-input-response"] }));
      expect(await said(await put({ site_key: 'key" onload="x', secret_key: SECRET }))).toEqual([400, SITE_KEY_WRONG]);
      expect(asked).toEqual([]);
      expect((await put({ site_key: SITE_KEY })).status).toBe(400);
      expect(saves(db)).toEqual([]);
    });

    it("are removed for the whole business", async () => {
      const db = fakeDb();
      const res = await app.request("/api/website-forms/turnstile", { method: "DELETE", headers }, env);
      expect(res.status).toBe(204);
      expect(db.queries.find((q) => q.table === "website_form_turnstile")!.calls).toEqual([["delete"], ["eq", "company_id", COMPANY]]);
    });

    it("are for owners and admins who connect apps: nobody else saves or removes them, and nobody without a sign-in", async () => {
      // These two routes write with the server's own key, so who may call them is all that guards them.
      for (const role of ["office", "estimator", "crew_lead", "field_crew", "subcontractor"]) {
        const db = fakeDb({ role });
        const asked = cloudflare(says({ success: false, "error-codes": ["invalid-input-response"] }));
        expect((await put({ site_key: SITE_KEY, secret_key: SECRET })).status, role).toBe(403);
        expect((await app.request("/api/website-forms/turnstile", { method: "DELETE", headers }, env)).status, role).toBe(403);
        expect(asked).toEqual([]);
        expect(db.queries.filter((q) => q.table === "website_form_turnstile")).toEqual([]);
        vi.unstubAllGlobals();
      }
      // An admin may.
      const admin = fakeDb({ role: "admin" });
      cloudflare(says({ success: false, "error-codes": ["invalid-input-response"] }));
      expect((await put({ site_key: SITE_KEY, secret_key: SECRET })).status).toBe(200);
      expect(saves(admin)).toHaveLength(1);

      fakeDb();
      expect((await app.request("/api/website-forms/turnstile", { method: "PUT", headers: { "Content-Type": "application/json" }, body: "{}" }, env)).status).toBe(401);
      expect((await app.request("/api/website-forms/turnstile", { method: "DELETE" }, env)).status).toBe(401);
    });
  });
});
