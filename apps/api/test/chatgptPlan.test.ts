/**
 * A person's own ChatGPT plan (integrations/chatgptPlan.ts and its routes in routes/chatgpt.ts):
 * the sign-in address, the pasted address that finishes it, the tokens (sealed, refreshed once at a
 * time, signed out), who may connect one, and that nothing secret ever comes back. OpenAI is a
 * stubbed fetch built to its documentation (fixtures/openaiSignIn.ts) and the database is kept in
 * memory: nothing here has run against the real service.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { decryptJson, encryptJson } from "../src/lib/crypto";
import { HttpError } from "../src/lib/http";
import { memoryDb, type MemoryDb, type Row } from "./fixtures/memoryDb";
import { idToken, LISTED, openai, planFunctions, SCOPE, type OpenAiWorld } from "./fixtures/openaiSignIn";

const world = vi.hoisted(() => ({ db: null as unknown as MemoryDb, viewer: "" }));
vi.mock("../src/lib/supabase", async () => {
  const { memoryClient } = await import("./fixtures/memoryDb");
  return { adminClient: () => memoryClient(() => world.db), userClient: () => memoryClient(() => world.db, () => ({ sub: world.viewer })), publishableKey: () => "key" };
});
const plans = await import("../src/integrations/chatgptPlan");
const { adminClient } = await import("../src/lib/supabase");
const { app } = await import("../src/app");
const { CRON_TASKS, runTask, TASKS } = await import("../src/tasks");

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ENCRYPTION_KEY: btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i * 7))),
  APP_URL: "https://ops.example.com",
} as Env;
const CO = "00000000-0000-4000-8000-0000000000c1";
// Pat owns Poplar Paving, Olive is in its office, Cruz is on a crew and Sal is a subcontractor's sign-in.
const PAT = "00000000-0000-4000-8000-0000000000e1";
const OLIVE = "00000000-0000-4000-8000-0000000000e2";
const CRUZ = "00000000-0000-4000-8000-0000000000e3";
const SAL = "00000000-0000-4000-8000-0000000000e4";
const pat = { userId: PAT, companyId: CO };
const olive = { userId: OLIVE, companyId: CO };
const admin = adminClient(env);

const CALLBACK = "http://127.0.0.1:1455/auth/callback";
const GRANTED = "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke";
let ai: OpenAiWorld;

/** Step one for a person: the address to open, and the one-time values in it. */
async function begin(person = pat, options: { fresh?: boolean } = {}) {
  const started = await plans.startSignIn(env, admin, person, options);
  const url = new URL(started.authorization_url);
  return { started, url, state: url.searchParams.get("state")!, nonce: url.searchParams.get("nonce")! };
}
/** The address the browser lands on after approving: on the person's own computer, where nothing answers. */
const landed = (state: string, more: Record<string, string> = {}) => `${CALLBACK}?${new URLSearchParams({ code: "code-pat-1", scope: GRANTED, state, client_id: "oaiapp_pat", ...more })}`;
/** What the token endpoint answers a good exchange or refresh with. */
const issued = async (n: number, nonce: string, more: Row = {}) => ({
  access_token: `access-token-${n}`,
  refresh_token: `refresh-token-${n}`,
  id_token: await idToken({ aud: "oaiapp_pat", sub: "user-pat-at-openai", email: "pat@poplar.test", nonce }),
  token_type: "Bearer",
  expires_in: 3600,
  scope: SCOPE,
  earliest_refresh_at: Math.floor(Date.now() / 1000) + 1800,
  ...more,
});
/** Pat signs in from start to finish. */
async function connect(person = pat) {
  const { state, nonce } = await begin(person);
  ai.token = () => issued(1, nonce);
  return plans.finishSignIn(env, admin, person, landed(state));
}
const refusal = async (run: Promise<unknown>) => {
  const error = await run.then(() => null, (e: unknown) => e);
  return error instanceof HttpError ? [error.status, error.message] : error;
};
const tokens = async (person = pat) => {
  const row = world.db.tables.chatgpt_plan_secrets!.find((r) => r.user_id === person.userId);
  return row ? decryptJson<Row>(env, row.ciphertext) : null;
};
const planRow = (person = pat) => world.db.tables.chatgpt_plans!.find((r) => r.user_id === person.userId);
/** The access token's hour is up. */
async function expire(person = pat) {
  const row = world.db.tables.chatgpt_plan_secrets!.find((r) => r.user_id === person.userId)!;
  row.ciphertext = await encryptJson(env, { ...(await decryptJson<Row>(env, row.ciphertext)), expires_at: Date.now() - 1000 });
}
const request = (who: string, method: string, path: string, body?: unknown) => {
  world.viewer = who;
  return app.request(`/api${path}`, { method, headers: { Authorization: "Bearer token", "X-Company-Id": CO, "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }, env);
};

beforeEach(() => {
  const member = (user_id: string, role: string) => ({ company_id: CO, user_id, active: true, role, role_id: null, subcontractor_id: role === "subcontractor" ? "sub-1" : null });
  world.db = memoryDb({
    memberships: [member(PAT, "owner"), member(OLIVE, "office"), member(CRUZ, "field_crew"), member(SAL, "subcontractor")],
    companies: [{ id: CO, name: "Poplar Paving", settings: {} }],
    integrations: [],
    integration_secrets: [],
    calendar_sources: [],
  });
  planFunctions(world.db);
  world.db.rpc.merge_company_settings = (args, db) => {
    const company = db.tables.companies!.find((c) => c.id === args.p_company)!;
    for (const [key, value] of Object.entries(args.p_settings as Row)) company.settings[key] = { ...(company.settings[key] ?? {}), ...(value as Row) };
    return null;
  };
  plans.forgetOpenAiSignIn();
  ai = openai();
});
afterEach(() => vi.unstubAllGlobals());

describe("the sign-in address", () => {
  it("has every part OpenAI asks for the first time, and keeps the secrets of the attempt on the server", async () => {
    const { started, url, state, nonce } = await begin();
    expect(url.origin + url.pathname).toBe("https://auth.openai.com/api/accounts/authorize");
    const params = Object.fromEntries(url.searchParams);
    expect(params).toEqual({
      response_type: "code",
      client_id: "dynamic_agent_client",
      agent_name_hint: "Planet Ops",
      ext_agent_host_id: "urn:uuid:6f1b8f0e-3c59-4d0a-9d55-1f2a3b4c5d6e",
      redirect_uri: CALLBACK,
      scope: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
      resource: "https://api.openai.com/v1",
      state,
      nonce,
      code_challenge_method: "S256",
      code_challenge: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });
    expect(started.redirect_uri).toBe(CALLBACK);
    // The attempt is kept sealed, for ten minutes: the code verifier is nowhere in what goes to the browser.
    const attempt = world.db.tables.chatgpt_sign_ins![0]!;
    const sealed = await decryptJson<Row>(env, attempt.ciphertext);
    expect(attempt).toMatchObject({ state, user_id: PAT, company_id: CO });
    expect(Date.parse(attempt.expires_at) - Date.now()).toBeGreaterThan(9 * 60_000);
    expect(Date.parse(attempt.expires_at) - Date.now()).toBeLessThanOrEqual(10 * 60_000);
    expect(sealed.verifier).toMatch(/^[A-Za-z0-9_-]{43,128}$/);
    expect(JSON.stringify(started)).not.toContain(sealed.verifier);
    // The challenge is the verifier's SHA-256, as S256 means.
    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sealed.verifier))).toString("base64url");
    expect(params.code_challenge).toBe(digest);
    // Nothing is asked of OpenAI until the person comes back.
    expect(ai.calls).toEqual([]);
  });

  it("is for the client OpenAI registered before on a later sign-in, with the account's email as a hint and no name hint", async () => {
    await connect();
    await plans.disconnectPlan(env, admin, pat);
    const { url } = await begin();
    const params = Object.fromEntries(url.searchParams);
    expect(params).toMatchObject({ client_id: "oaiapp_pat", login_hint: "pat@poplar.test", ext_agent_host_id: "urn:uuid:6f1b8f0e-3c59-4d0a-9d55-1f2a3b4c5d6e" });
    expect(params.agent_name_hint).toBeUndefined();
    // No token ever goes into an address, not even as a hint.
    expect(params.id_token_hint).toBeUndefined();
    // Use a different account starts a new registration.
    const fresh = Object.fromEntries((await begin(pat, { fresh: true })).url.searchParams);
    expect(fresh).toMatchObject({ client_id: "dynamic_agent_client", agent_name_hint: "Planet Ops" });
    expect(fresh.login_hint).toBeUndefined();
  });

  it("is one attempt at a time for a person: starting again forgets the last", async () => {
    const first = await begin();
    const second = await begin();
    expect(world.db.tables.chatgpt_sign_ins!.map((r) => r.state)).toEqual([second.state]);
    ai.token = () => issued(1, first.nonce);
    expect((await refusal(plans.finishSignIn(env, admin, pat, landed(first.state)))) as unknown[]).toEqual([400, expect.stringMatching(/isn't from the sign-in you just started/)]);
  });
});

describe("pasting the address the browser landed on", () => {
  it("connects the plan once the code is exchanged, the sign-in is OpenAI's, plan use is granted and the models are listed", async () => {
    const { state, nonce } = await begin();
    ai.token = () => issued(1, nonce);
    const row = await plans.finishSignIn(env, admin, pat, landed(state));
    expect(row).toMatchObject({ status: "connected", client_id: "oaiapp_pat", account_sub: "user-pat-at-openai", account_email: "pat@poplar.test", model: "gpt-6.1-sol", models: LISTED, problem: null });
    // The exchange, as OpenAI documents it: form-encoded, the issued client, the verifier, no secret.
    const exchange = ai.calls.find((c) => c.url.endsWith("/oauth/token"))!;
    const sealed = exchange.form.code_verifier;
    expect(exchange.form).toEqual({ grant_type: "authorization_code", client_id: "oaiapp_pat", code: "code-pat-1", code_verifier: sealed, redirect_uri: CALLBACK, resource: "https://api.openai.com/v1" });
    expect(exchange.method).toBe("POST");
    // The models were asked for with the new access token.
    expect(ai.calls.find((c) => c.url.endsWith("/v1/models"))!.bearer).toBe("access-token-1");
    // Tokens are sealed where they're kept; the plan's own row holds none.
    expect(await tokens()).toMatchObject({ access_token: "access-token-1", refresh_token: "refresh-token-1", scope: SCOPE });
    expect(JSON.stringify(world.db.tables)).not.toMatch(/access-token-1|refresh-token-1/);
    // The attempt is gone: used once.
    expect(world.db.tables.chatgpt_sign_ins).toEqual([]);
  });

  it("takes the whole address or just what follows its question mark", async () => {
    let attempt = await begin();
    ai.token = () => issued(1, attempt.nonce);
    expect((await plans.finishSignIn(env, admin, pat, `  ${landed(attempt.state).split("?")[1]}  `)).status).toBe("connected");
    attempt = await begin();
    ai.token = () => issued(2, attempt.nonce);
    expect((await plans.finishSignIn(env, admin, pat, `?${landed(attempt.state).split("?")[1]}#top`)).status).toBe("connected");
    expect(plans.pastedParams("http://127.0.0.1:1455/auth/callback")).toBeNull();
    expect(plans.pastedParams("hello")).toBeNull();
    expect(await refusal(plans.finishSignIn(env, admin, pat, "https://chatgpt.com/"))).toEqual([400, expect.stringMatching(/isn't the address from ChatGPT's sign-in/)]);
  });

  it("refuses a state that isn't this person's pending attempt: made up, someone else's, used already or too old", async () => {
    const { state, nonce } = await begin();
    ai.token = () => issued(1, nonce);
    const not = expect.stringMatching(/isn't from the sign-in you just started/);
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed("made-up-state-made-up-state")))).toEqual([400, not]);
    // Olive pastes Pat's address: it isn't hers, and Pat's attempt is still there for Pat.
    expect(await refusal(plans.finishSignIn(env, admin, olive, landed(state)))).toEqual([400, not]);
    expect((await plans.finishSignIn(env, admin, pat, landed(state))).status).toBe("connected");
    // Used once: pasting it again does nothing more.
    const exchanges = ai.calls.filter((c) => c.url.endsWith("/oauth/token")).length;
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(state)))).toEqual([400, not]);
    expect(ai.calls.filter((c) => c.url.endsWith("/oauth/token"))).toHaveLength(exchanges);

    const late = await begin();
    world.db.tables.chatgpt_sign_ins![0]!.expires_at = new Date(Date.now() - 1000).toISOString();
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(late.state)))).toEqual([400, not]);
  });

  it("says so when the person declined, and exchanges nothing", async () => {
    const { state } = await begin();
    expect(await refusal(plans.finishSignIn(env, admin, pat, `${CALLBACK}?error=access_denied&state=${state}`))).toEqual([400, "You declined on ChatGPT's page, so your plan wasn't connected."]);
    expect(ai.calls).toEqual([]);
    expect(planRow()).toBeUndefined();
    // The attempt is used up all the same.
    expect(world.db.tables.chatgpt_sign_ins).toEqual([]);
  });

  it("treats a first sign-in that comes back without a registered client as unfinished", async () => {
    for (const client_id of ["", "dynamic_agent_client"]) {
      const { state } = await begin();
      const address = `${CALLBACK}?${new URLSearchParams({ code: "code-pat-1", scope: GRANTED, state, ...(client_id ? { client_id } : {}) })}`;
      expect(await refusal(plans.finishSignIn(env, admin, pat, address))).toEqual([400, "ChatGPT didn't finish registering Crewtavo for your account. Press Continue with ChatGPT and try again."]);
    }
    expect(ai.calls).toEqual([]);
    expect(planRow()).toBeUndefined();
  });

  it("on a later sign-in keeps the saved client when the address names none, and refuses a different one", async () => {
    await connect();
    await plans.disconnectPlan(env, admin, pat);
    let attempt = await begin();
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(attempt.state, { client_id: "oaiapp_someone_else" })))).toEqual([400, expect.stringMatching(/different registration/)]);
    expect(planRow()).toMatchObject({ status: "disconnected", client_id: "oaiapp_pat" });

    attempt = await begin();
    ai.calls.length = 0;
    ai.token = () => issued(2, attempt.nonce);
    const address = `${CALLBACK}?${new URLSearchParams({ code: "code-pat-2", scope: GRANTED, state: attempt.state })}`;
    expect(await plans.finishSignIn(env, admin, pat, address)).toMatchObject({ status: "connected", client_id: "oaiapp_pat" });
    expect(ai.calls.find((c) => c.url.endsWith("/oauth/token"))!.form.client_id).toBe("oaiapp_pat");
  });

  it("refuses another ChatGPT account on a registration made for the first one", async () => {
    await connect();
    await plans.disconnectPlan(env, admin, pat);
    const { state, nonce } = await begin();
    ai.token = async () => issued(2, nonce, { id_token: await idToken({ aud: "oaiapp_pat", sub: "someone-else-at-openai", email: "else@example.test", nonce }) });
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(state)))).toEqual([400, expect.stringMatching(/different ChatGPT account/)]);
    expect(await tokens()).toBeNull();
    // The tokens that came back are signed out again rather than left alive.
    expect(ai.calls.filter((c) => c.url.endsWith("/oauth/revoke")).at(-1)!.form).toEqual({ token: "refresh-token-2", token_type_hint: "refresh_token", client_id: "oaiapp_pat" });
  });

  it("isn't connected when the code is spent, and says to start again", async () => {
    const { state } = await begin();
    ai.token = () => ({ status: 400, body: { error: "invalid_grant" } });
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(state)))).toEqual([400, "That sign-in code was used already or has run out. Press Continue with ChatGPT and try again."]);
    expect(planRow()).toBeUndefined();
  });

  it("isn't connected unless the ID token is OpenAI's own for this client and this attempt", async () => {
    const bad: Array<[string, (nonce: string) => Promise<string>]> = [
      ["signed by someone else", (nonce) => idToken({ aud: "oaiapp_pat", sub: "user-pat-at-openai", nonce }, true)],
      ["for another client", (nonce) => idToken({ aud: "oaiapp_other", sub: "user-pat-at-openai", nonce })],
      ["from another issuer", (nonce) => idToken({ iss: "https://auth.example.test", aud: "oaiapp_pat", sub: "user-pat-at-openai", nonce })],
      ["expired", (nonce) => idToken({ aud: "oaiapp_pat", sub: "user-pat-at-openai", nonce, exp: Math.floor(Date.now() / 1000) - 600 })],
      ["for another attempt", () => idToken({ aud: "oaiapp_pat", sub: "user-pat-at-openai", nonce: "another-attempts-nonce" })],
      ["not a token", async () => "not.a.token"],
    ];
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    for (const [why, make] of bad) {
      const { state, nonce } = await begin();
      ai.token = async () => issued(1, nonce, { id_token: await make(nonce) });
      expect([why, await refusal(plans.finishSignIn(env, admin, pat, landed(state)))]).toEqual([why, [502, "ChatGPT's sign-in couldn't be checked, so nothing was connected. Press Continue with ChatGPT and try again."]]);
      expect(await tokens()).toBeNull();
    }
    expect(planRow()).toBeUndefined();
    vi.restoreAllMocks();
  });

  it("isn't connected when plan use wasn't granted, and offers the other way", async () => {
    const { state, nonce } = await begin();
    ai.token = () => issued(1, nonce, { scope: "openid profile email offline_access" });
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(state)))).toEqual([400, "You signed in, but using your ChatGPT plan here wasn't allowed, so nothing was connected. Start again and allow it, or use an OpenAI API key instead."]);
    expect(await tokens()).toBeNull();
    // The registration is kept for next time, without being connected.
    expect(planRow()).toMatchObject({ client_id: "oaiapp_pat" });
    expect(planRow()!.status ?? "disconnected").toBe("disconnected");
  });

  it("isn't connected when the plan's models don't list, and says which plans can be used when OpenAI says this one can't", async () => {
    let attempt = await begin();
    ai.token = () => issued(1, attempt.nonce);
    ai.models = { status: 503, body: { detail: "unavailable" } };
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(attempt.state)))).toEqual([502, "You signed in, but ChatGPT didn't list your plan's models, so nothing was connected. Press Continue with ChatGPT and try again."]);
    attempt = await begin();
    ai.models = { status: 403, body: { error: { code: "subscription_sharing_user_not_eligible" } } };
    expect(await refusal(plans.finishSignIn(env, admin, pat, landed(attempt.state)))).toEqual([400, "ChatGPT says your plan can't be used here. ChatGPT Plus and Pro plans can be used; an OpenAI API key is the other way."]);
    expect(await tokens()).toBeNull();
    expect(planRow()!.status ?? "disconnected").toBe("disconnected");
  });
});

describe("the access token", () => {
  beforeEach(async () => {
    await connect();
    ai.calls.length = 0;
  });

  it("is used as it is while it has time left, and refreshed when it's about to run out", async () => {
    expect(await plans.planAccess(env, admin, pat)).toBe("access-token-1");
    expect(ai.calls).toEqual([]);
    await expire();
    ai.token = () => issued(2, "unused");
    expect(await plans.planAccess(env, admin, pat)).toBe("access-token-2");
    // The refresh, as OpenAI documents it: the issued client, the refresh token, the resource, no scope.
    expect(ai.calls.map((c) => c.form)).toEqual([{ grant_type: "refresh_token", client_id: "oaiapp_pat", refresh_token: "refresh-token-1", resource: "https://api.openai.com/v1" }]);
    // The replacement refresh token is the one kept, and nothing holds the tokens anymore.
    expect(await tokens()).toMatchObject({ access_token: "access-token-2", refresh_token: "refresh-token-2" });
    expect(world.db.tables.chatgpt_plan_secrets![0]!.refresh_claimed_until).toBeNull();
  });

  it("is refreshed once when two servers need it at the same moment: one refresh token is never used twice", async () => {
    await expire();
    const used: string[] = [];
    ai.token = async (form) => {
      used.push(form.refresh_token!);
      await new Promise((resolve) => setTimeout(resolve, 50));
      // OpenAI ends the sign-in when a refresh token comes back a second time.
      return used.filter((t) => t === form.refresh_token).length > 1 ? { status: 400, body: { error: "refresh_token_reused" } } : issued(2, "unused");
    };
    // A second server: its own copy of the code, sharing only the database.
    vi.resetModules();
    const other = await import("../src/integrations/chatgptPlan");
    expect(other.planAccess).not.toBe(plans.planAccess);
    const got = await Promise.all([plans.planAccess(env, admin, pat), other.planAccess(env, admin, pat), plans.planAccess(env, admin, pat)]);
    expect(got).toEqual(["access-token-2", "access-token-2", "access-token-2"]);
    expect(used).toEqual(["refresh-token-1"]);
    expect(planRow()).toMatchObject({ status: "connected", problem: null });
  });

  it("ends in Sign in again when the refresh token has run out or was revoked, and the dead tokens are deleted", async () => {
    for (const code of ["invalid_grant", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]) {
      await connect();
      await expire();
      ai.token = () => ({ status: 400, body: { error: code } });
      const error = await plans.planAccess(env, admin, pat).catch((e: unknown) => e);
      expect([code, error instanceof plans.PlanTrouble && error.kind]).toEqual([code, "sign_in"]);
      expect(await tokens()).toBeNull();
      expect(planRow()).toMatchObject({ status: "disconnected", problem: "sign_in", client_id: "oaiapp_pat" });
      expect(plans.planStatus(env, planRow() as never)).toMatchObject({ status: "disconnected", problem: "sign_in", registered: true });
    }
  });

  it("is left alone when OpenAI can't be reached or is busy, or the answer isn't OpenAI's own: that isn't a sign-in that ended", async () => {
    await expire();
    // The last one is a proxy's error page: a 403 with no OAuth error in it.
    for (const answer of [{ status: 503, body: {} }, { status: 429, body: { error: "slow_down" } }, { status: 403, body: "<html>Forbidden</html>" }]) {
      ai.token = () => answer;
      const error = await plans.planAccess(env, admin, pat).catch((e: unknown) => e);
      expect(error instanceof plans.PlanTrouble && error.kind).toBe("unavailable");
      expect(await tokens()).toMatchObject({ refresh_token: "refresh-token-1" });
      expect(planRow()).toMatchObject({ status: "connected", problem: null });
      // The next ask can try again right away.
      expect(world.db.tables.chatgpt_plan_secrets![0]!.refresh_claimed_until).toBeNull();
    }
  });
});

describe("a connection whose tokens are gone", () => {
  it("says Sign in again rather than going on looking connected", async () => {
    await connect();
    world.db.tables.chatgpt_plan_secrets = [];
    const error = await plans.planAccess(env, admin, pat).catch((e: unknown) => e);
    expect(error instanceof plans.PlanTrouble && error.kind).toBe("sign_in");
    expect(planRow()).toMatchObject({ status: "disconnected", problem: "sign_in" });
  });

  it("keeps the client its tokens were issued to sealed with them, so they can be signed out once the account is gone", async () => {
    await connect();
    expect(await tokens()).toMatchObject({ client_id: "oaiapp_pat" });
    // The account was deleted: its connection went with it, and only the sealed tokens are left.
    world.db.tables.chatgpt_plans = [];
    ai.calls.length = 0;
    expect(await plans.tidyPlans(env, admin)).toEqual({ signed_out: 1, removed: 1, waiting: 0 });
    expect(ai.calls.find((c) => c.url.endsWith("/oauth/revoke"))!.form).toEqual({ token: "refresh-token-1", token_type_hint: "refresh_token", client_id: "oaiapp_pat" });
  });

  it("aren't the tokens of someone who signed in again while the task was signing the old ones out", async () => {
    await connect();
    planRow()!.status = "disconnected";
    // The task has read the old tokens; before it deletes them, the person signs in again.
    const leftovers = world.db.rpc.chatgpt_plan_leftovers!;
    world.db.rpc.chatgpt_plan_leftovers = (args, db) => {
      const found = leftovers(args, db);
      db.tables.chatgpt_plan_secrets![0]!.ciphertext = "v1.new-sign-in";
      planRow()!.status = "connected";
      return found;
    };
    expect(await plans.tidyPlans(env, admin)).toMatchObject({ signed_out: 1 });
    expect(world.db.tables.chatgpt_plan_secrets!.map((r) => r.ciphertext)).toEqual(["v1.new-sign-in"]);
  });
});

describe("a sign-in that fails after a new registration", () => {
  it("doesn't change the registration of a connection that's still live", async () => {
    await connect();
    const { state, nonce } = await begin(pat, { fresh: true });
    ai.token = async () => issued(2, nonce, { scope: "openid profile email offline_access", id_token: await idToken({ aud: "oaiapp_new", sub: "user-pat-at-openai", nonce }) });
    expect((await refusal(plans.finishSignIn(env, admin, pat, landed(state, { client_id: "oaiapp_new" })))) as unknown[]).toEqual([400, expect.stringMatching(/wasn't allowed/)]);
    expect(planRow()).toMatchObject({ status: "connected", client_id: "oaiapp_pat" });
    expect(await tokens()).toMatchObject({ refresh_token: "refresh-token-1", client_id: "oaiapp_pat" });
  });

  it("goes by what OpenAI's token endpoint granted, never by what the pasted address claims", async () => {
    const { state, nonce } = await begin();
    ai.token = () => issued(1, nonce, { scope: "openid profile email offline_access" });
    // The address says plan use was granted; the token endpoint says it wasn't.
    expect((await refusal(plans.finishSignIn(env, admin, pat, landed(state)))) as unknown[]).toEqual([400, expect.stringMatching(/wasn't allowed/)]);
    expect(await tokens()).toBeNull();
  });
});

describe("disconnecting", () => {
  it("signs the refresh token out at OpenAI, deletes the tokens and keeps the registration for next time", async () => {
    await connect();
    ai.calls.length = 0;
    expect(await plans.disconnectPlan(env, admin, pat)).toEqual({ revoked: true });
    const revoke = ai.calls.find((c) => c.url === "https://auth.openai.com/api/accounts/oauth/revoke")!;
    expect([revoke.method, revoke.form]).toEqual(["POST", { token: "refresh-token-1", token_type_hint: "refresh_token", client_id: "oaiapp_pat" }]);
    expect(await tokens()).toBeNull();
    expect(planRow()).toMatchObject({ status: "disconnected", client_id: "oaiapp_pat", account_email: "pat@poplar.test", problem: null });
  });

  it("deletes the tokens even when OpenAI doesn't confirm, and says so", async () => {
    await connect();
    ai.revoke = 400;
    expect(await plans.disconnectPlan(env, admin, pat)).toEqual({ revoked: false });
    expect(await tokens()).toBeNull();
    expect(planRow()).toMatchObject({ status: "disconnected" });
  });
});

describe("tokens whose person is gone", () => {
  it("are signed out at OpenAI and deleted on the task's next pass, with sign-ins nobody finished", async () => {
    await connect();
    await begin(olive);
    world.db.tables.chatgpt_sign_ins![0]!.expires_at = new Date(Date.now() - 1000).toISOString();
    // Pat was turned off on the Team page: the database ends the connection (chatgpt_plans_test.sql), the tokens wait here.
    planRow()!.status = "disconnected";
    ai.calls.length = 0;
    expect(await plans.tidyPlans(env, admin)).toEqual({ signed_out: 1, removed: 1, waiting: 0 });
    expect(ai.calls.find((c) => c.url.endsWith("/oauth/revoke"))!.form).toMatchObject({ token: "refresh-token-1", client_id: "oaiapp_pat" });
    expect(world.db.tables.chatgpt_plan_secrets).toEqual([]);
    expect(world.db.tables.chatgpt_sign_ins).toEqual([]);
    // A connected plan's tokens are left alone.
    await connect();
    expect(await plans.tidyPlans(env, admin)).toEqual({ signed_out: 0, removed: 0, waiting: 0 });
    expect(await tokens()).not.toBeNull();
  });

  it("wait for the next pass when OpenAI can't be reached about them, rather than being forgotten unsigned-out", async () => {
    await connect();
    planRow()!.status = "disconnected";
    ai.revoke = 503;
    expect(await plans.tidyPlans(env, admin)).toEqual({ signed_out: 0, removed: 0, waiting: 1 });
    expect(await tokens()).not.toBeNull();
    ai.revoke = 200;
    expect(await plans.tidyPlans(env, admin)).toEqual({ signed_out: 1, removed: 1, waiting: 0 });
  });

  it("are looked for every ten minutes by the chatgpt_plans task", async () => {
    expect(TASKS.at(-1)).toBe("chatgpt_plans");
    expect(CRON_TASKS["7-59/10 * * * *"]).toEqual(["chatgpt_plans"]);
    expect(await runTask("chatgpt_plans", env)).toEqual({ signed_out: 0, removed: 0, waiting: 0 });
  });
});

describe("who may connect a plan, and what comes back", () => {
  it("is owners and admins who manage apps, and the rest of the team only once the company allows it; never a sub", async () => {
    expect((await request(PAT, "POST", "/ai/chatgpt/sign-in", {})).status).toBe(200);
    for (const who of [OLIVE, CRUZ]) {
      const res = await request(who, "POST", "/ai/chatgpt/sign-in", {});
      expect([res.status, await res.json()]).toEqual([403, { error: "Your company hasn't turned on using your own ChatGPT plan. An owner or admin can, under Apps → ChatGPT." }]);
      expect((await request(who, "POST", "/ai/chatgpt/sign-in/finish", { address: landed("some-state-some-state-some") })).status).toBe(403);
      expect(await (await request(who, "GET", "/ai/chatgpt")).json()).toMatchObject({ allowed: false, team_plans: false });
    }
    expect((await request(SAL, "POST", "/ai/chatgpt/sign-in", {})).status).toBe(403);
    expect((await request(SAL, "GET", "/ai/chatgpt")).status).toBe(403);
    // Only an owner or admin flips the switch.
    expect((await request(OLIVE, "PUT", "/ai/team-plans", { on: true })).status).toBe(403);
    expect(await (await request(PAT, "PUT", "/ai/team-plans", { on: true })).json()).toEqual({ team_plans: true });
    expect((await request(CRUZ, "POST", "/ai/chatgpt/sign-in", {})).status).toBe(200);
    expect((await request(SAL, "POST", "/ai/chatgpt/sign-in", {})).status).toBe(403);
  });

  it("disconnects everyone's but the owners' and admins' when the company stops allowing it", async () => {
    await request(PAT, "PUT", "/ai/team-plans", { on: true });
    await connect(pat);
    await connect(olive);
    expect((await request(PAT, "PUT", "/ai/team-plans", { on: false })).status).toBe(200);
    expect([planRow(pat)!.status, planRow(olive)!.status]).toEqual(["connected", "disconnected"]);
    // Olive can still disconnect hers for good, which signs it out at OpenAI now.
    expect((await request(OLIVE, "POST", "/ai/chatgpt/disconnect", {})).status).toBe(200);
    expect(await tokens(olive)).toBeNull();
  });

  it("never holds a token, a code verifier or the client's secrets in any answer, from sign-in to disconnect", async () => {
    const seen: string[] = [];
    const call = async (method: string, path: string, body?: unknown) => {
      const res = await request(PAT, method, path, body);
      const text = await res.text();
      seen.push(text);
      return JSON.parse(text) as Row;
    };
    const started = await call("POST", "/ai/chatgpt/sign-in", {});
    const url = new URL(started.authorization_url);
    const verifier = (await decryptJson<Row>(env, world.db.tables.chatgpt_sign_ins![0]!.ciphertext)).verifier as string;
    ai.token = () => issued(1, url.searchParams.get("nonce")!);
    const finished = await call("POST", "/ai/chatgpt/sign-in/finish", { address: landed(url.searchParams.get("state")!) });
    expect(finished.plan).toEqual({ status: "connected", email: "pat@poplar.test", model: "gpt-6.1-sol", models: LISTED, model_locked: false, problem: null, notice_seen: false, registered: true, connected_at: expect.any(String) });
    expect(await call("GET", "/ai/chatgpt")).toMatchObject({ allowed: true, fallback: false, redirect_uri: CALLBACK, usage_url: "https://chatgpt.com/settings/usage" });
    await call("POST", "/ai/chatgpt/notice", {});
    expect((await call("GET", "/ai/chatgpt")).plan.notice_seen).toBe(true);
    expect((await call("PUT", "/ai/chatgpt/model", { model: "gpt-6-astra" })).plan.model).toBe("gpt-6-astra");
    expect((await request(PAT, "PUT", "/ai/chatgpt/model", { model: "gpt-9-made-up" })).status).toBe(400);
    await call("POST", "/ai/chatgpt/models", {});
    await call("POST", "/ai/chatgpt/retry", {});
    await call("GET", "/apps");
    await call("GET", "/me");
    const idTokenSent = (await issued(1, "x")).id_token.split(".")[0]!;
    expect((await call("POST", "/ai/chatgpt/disconnect", {})).plan).toMatchObject({ status: "disconnected", registered: true });
    const everything = seen.join("\n");
    for (const secret of ["access-token-1", "refresh-token-1", verifier, idTokenSent, "oaiapp_pat", "user-pat-at-openai"]) expect(everything).not.toContain(secret);
  });

  it("shows a person's plan as theirs alone: on their Apps page and their sign-in, not anyone else's", async () => {
    await connect(pat);
    const apps = (await (await request(PAT, "GET", "/apps")).json()) as { apps: Row[] };
    expect(apps.apps.find((a) => a.id === "chatgpt")).toMatchObject({ status: "disconnected", my_plan: true, team_plans: false });
    world.db.tables.profiles = [PAT, OLIVE].map((user_id) => ({ user_id, email: `${user_id}@poplar.test`, full_name: "Someone", phone: null }));
    for (const m of world.db.tables.memberships!) m.company = world.db.tables.companies![0];
    const mine = (await (await request(PAT, "GET", "/me")).json()) as { memberships: Row[] };
    expect(mine.memberships[0]).toMatchObject({ ai_connected: true, chatgpt_plan: true });
    const hers = (await (await request(OLIVE, "GET", "/me")).json()) as { memberships: Row[] };
    expect(hers.memberships[0]).toMatchObject({ ai_connected: false, chatgpt_plan: false });
    expect(await (await request(OLIVE, "GET", "/ai/chatgpt")).json()).toMatchObject({ plan: { status: "disconnected", email: null, registered: false } });
  });
});
