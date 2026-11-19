/**
 * A person's own ChatGPT plan for Crewtavo's AI: OpenAI's Sign in with ChatGPT, plan use for
 * open-source apps (developers.openai.com/siwc), written from its protocol description.
 *
 * OpenAI only sends the browser back to an address on the person's own computer
 * (http://127.0.0.1:<port>/auth/callback), and a Crewtavo server isn't there. So signing in takes
 * two steps: the person opens OpenAI's page and approves, their browser lands on an address that
 * can't be reached, and they paste that address here, where the server checks it's the sign-in
 * this person started and exchanges its code.
 *
 * Tokens are sealed before they're stored (chatgpt_plan_secrets, which only the server reads) and
 * never leave the server: not in an answer to the web app, a log line or an address. Everything
 * here uses the server's own database client.
 */
import { PRODUCT_NAME } from "@crewtavo/core/brand";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Env } from "../env";
import { decryptJson, encryptJson, fromBase64Url, randomId, toBase64Url } from "../lib/crypto";
import { HttpError } from "../lib/http";
import type { Db } from "../lib/supabase";
import { listPlanModels, OpenAiProblem, pickModel, type OpenAiModel } from "./openai";

export const ISSUER = "https://auth.openai.com";
const DISCOVERY = `${ISSUER}/.well-known/openid-configuration`;
const AUTHORIZE = `${ISSUER}/api/accounts/authorize`;
const TOKEN = `${ISSUER}/api/accounts/oauth/token`;
/** Where OpenAI sends the browser back: always the person's own computer, where nothing of ours listens. */
export const REDIRECT_URI = "http://127.0.0.1:1455/auth/callback";
const PLAN_SCOPE = "chatgpt.tokens.use.direct";
const SCOPE = `openid profile email offline_access resource.invoke ${PLAN_SCOPE}`;
const RESOURCE = "https://api.openai.com/v1";
/** The client every first sign-in starts from; OpenAI answers with the one it registered for the account. */
const FIRST_CLIENT = "dynamic_agent_client";
const APP_NAME = PRODUCT_NAME;
/** Where a person sees and manages what their plan has used. */
export const USAGE_URL = "https://chatgpt.com/settings/usage";
/** How long a started sign-in can be finished. */
const ATTEMPT_MS = 10 * 60_000;

export interface Person {
  userId: string;
  companyId: string;
}

export type PlanProblem = "usage_limit" | "sign_in" | "not_eligible";

/** A row of chatgpt_plans. */
export interface PlanRow {
  user_id: string;
  company_id: string;
  status: "connected" | "disconnected";
  client_id: string | null;
  host_id: string | null;
  account_sub: string | null;
  account_email: string | null;
  model: string | null;
  models: OpenAiModel[];
  unsupported: string[];
  problem: PlanProblem | null;
  problem_at: string | null;
  retry_at: string | null;
  notice_seen_at: string | null;
  connected_at: string | null;
}

interface PlanTokens {
  /** The client the tokens were issued to, kept with them so they can be signed out even after the plan's own row is gone. */
  client_id?: string;
  access_token: string;
  refresh_token: string;
  /** ms since epoch */
  expires_at: number;
  scope: string;
}

interface Attempt {
  verifier: string;
  nonce: string;
  /** The client the sign-in was started with: FIRST_CLIENT, or the one registered before. */
  client_id: string;
  host_id: string;
}

/**
 * The new tables and functions as the server's client reaches them. The generated database types
 * learn them only when they're regenerated, so their rows are written out above instead.
 */
const loose = (db: Db) => db as unknown as SupabaseClient;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const who = (p: Person) => ({ user_id: p.userId, company_id: p.companyId });

// ---------------------------------------------------------------------------------------------
// OpenAI's sign-in service
// ---------------------------------------------------------------------------------------------

interface Discovery {
  jwks_uri: string;
  revocation_endpoint: string;
}
let discovered: { value: Discovery; at: number } | null = null;
let signingKeys: { keys: JsonWebKey[]; at: number } | null = null;

/** Forget what was read from OpenAI's sign-in service (tests start clean). */
export function forgetOpenAiSignIn() {
  discovered = null;
  signingKeys = null;
}

/** An https address on OpenAI's own sign-in host: what its discovery document names is only used there. */
function openAiAddress(value: unknown): string | null {
  try {
    const url = new URL(String(value));
    return url.protocol === "https:" && !url.port && !url.username && (url.hostname === "auth.openai.com" || url.hostname.endsWith(".openai.com")) ? url.toString() : null;
  } catch {
    return null;
  }
}

/** Where OpenAI publishes its signing keys and takes sign-outs, from its discovery document (kept for an hour). */
async function discovery(): Promise<Discovery> {
  if (discovered && Date.now() - discovered.at < 3_600_000) return discovered.value;
  const response = await fetch(DISCOVERY, { headers: { Accept: "application/json" }, redirect: "error", signal: AbortSignal.timeout(15_000) });
  const json = (await response.json().catch(() => null)) as { issuer?: unknown; jwks_uri?: unknown; revocation_endpoint?: unknown } | null;
  const jwks_uri = openAiAddress(json?.jwks_uri);
  const revocation_endpoint = openAiAddress(json?.revocation_endpoint);
  if (!response.ok || json?.issuer !== ISSUER || !jwks_uri || !revocation_endpoint) throw new Error("OpenAI's sign-in settings couldn't be read");
  discovered = { value: { jwks_uri, revocation_endpoint }, at: Date.now() };
  return discovered.value;
}

async function signingKey(kid: string | undefined): Promise<JsonWebKey | null> {
  // By the key id the token names. One that names none is only matched when OpenAI publishes a single key.
  const find = (keys: JsonWebKey[]) => keys.find((k) => (k as { kid?: string }).kid === kid) ?? (!kid && keys.length === 1 ? keys[0]! : null);
  const kept = signingKeys && Date.now() - signingKeys.at < 3_600_000 ? find(signingKeys.keys) : null;
  if (kept) return kept;
  // Not one we have: OpenAI may have changed its keys, so they're read again.
  const response = await fetch((await discovery()).jwks_uri, { headers: { Accept: "application/json" }, redirect: "error", signal: AbortSignal.timeout(15_000) });
  const json = (await response.json().catch(() => null)) as { keys?: JsonWebKey[] } | null;
  if (!response.ok || !Array.isArray(json?.keys)) throw new Error("OpenAI's signing keys couldn't be read");
  signingKeys = { keys: json.keys, at: Date.now() };
  return find(json.keys);
}

const ALGORITHMS: Record<string, { import: RsaHashedImportParams | EcKeyImportParams; verify: AlgorithmIdentifier | EcdsaParams }> = {
  RS256: { import: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, verify: "RSASSA-PKCS1-v1_5" },
  ES256: { import: { name: "ECDSA", namedCurve: "P-256" }, verify: { name: "ECDSA", hash: "SHA-256" } },
};

/**
 * The account an ID token names, once it's been checked: signed by one of OpenAI's published keys,
 * issued by OpenAI for this client, not expired, and carrying the one-time value this sign-in began
 * with. Throws when any of that doesn't hold.
 */
export async function verifyIdToken(idToken: string, expected: { clientId: string; nonce: string }): Promise<{ sub: string; email: string | null }> {
  const [head, body, signature] = idToken.split(".");
  if (!head || !body || !signature) throw new Error("not a token");
  // What doesn't decode says only that, so no piece of a token ends up in an error (JSON.parse quotes what it was given).
  const decode = (part: string) => {
    try {
      return JSON.parse(new TextDecoder().decode(fromBase64Url(part))) as Record<string, unknown>;
    } catch {
      throw new Error("not a token");
    }
  };
  const header = decode(head);
  const algorithm = ALGORITHMS[String(header.alg)];
  if (!algorithm) throw new Error("unexpected signing algorithm");
  const jwk = await signingKey(typeof header.kid === "string" ? header.kid : undefined);
  if (!jwk) throw new Error("unknown signing key");
  const key = await crypto.subtle.importKey("jwk", jwk, algorithm.import, false, ["verify"]);
  if (!(await crypto.subtle.verify(algorithm.verify, key, fromBase64Url(signature), new TextEncoder().encode(`${head}.${body}`)))) throw new Error("bad signature");
  const claims = decode(body);
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (claims.iss !== ISSUER) throw new Error("wrong issuer");
  if (!audience.includes(expected.clientId)) throw new Error("wrong audience");
  if (typeof claims.exp !== "number" || claims.exp * 1000 < Date.now() - 60_000) throw new Error("expired");
  if (claims.nonce !== expected.nonce) throw new Error("wrong nonce");
  if (typeof claims.sub !== "string" || !claims.sub) throw new Error("no account");
  return { sub: claims.sub.slice(0, 300), email: typeof claims.email === "string" && claims.email ? claims.email.slice(0, 320) : null };
}

interface TokenAnswer {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
  expires_in?: number;
  scope?: string;
  error?: unknown;
  code?: unknown;
}

/** What OpenAI called a refused token request: the standard OAuth `error`, or an error object's code. */
function tokenErrorCode(json: TokenAnswer | null): string | null {
  const error = json?.error;
  if (typeof error === "string") return error;
  if (error && typeof error === "object") {
    const e = error as { code?: unknown; type?: unknown };
    return typeof e.code === "string" ? e.code : typeof e.type === "string" ? e.type : null;
  }
  return typeof json?.code === "string" ? json.code : null;
}

/** The token endpoint, form-encoded and with no client secret (there is none). Never throws: a failure to reach it is status 0. */
async function tokenRequest(form: Record<string, string>): Promise<{ ok: boolean; status: number; json: TokenAnswer | null; code: string | null }> {
  try {
    const response = await fetch(TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams(form),
      // Never followed anywhere else: the form holds a code or a refresh token.
      redirect: "error",
      signal: AbortSignal.timeout(15_000),
    });
    const json = (await response.json().catch(() => null)) as TokenAnswer | null;
    return { ok: response.ok && Boolean(json?.access_token), status: response.status, json, code: tokenErrorCode(json) };
  } catch {
    return { ok: false, status: 0, json: null, code: null };
  }
}

/** A refresh token OpenAI won't take again: the person signs in again. */
const REFRESH_ENDED = new Set(["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "invalid_client"]);

/**
 * Sign a refresh token out at OpenAI. True once OpenAI confirms (an empty 200, also for a token
 * that was already dead). Trouble reaching OpenAI is tried three times, a little apart.
 */
async function revoke(refreshToken: string, clientId: string): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const { revocation_endpoint } = await discovery();
      const response = await fetch(revocation_endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token: refreshToken, token_type_hint: "refresh_token", client_id: clientId }),
        redirect: "error",
        signal: AbortSignal.timeout(15_000),
      });
      if (response.ok) return true;
      if (response.status < 500) return false;
    } catch {
      // Tried again below.
    }
    if (attempt < 2) await sleep(300 * (attempt + 1));
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// What's stored
// ---------------------------------------------------------------------------------------------

export async function loadPlan(admin: Db, person: Person): Promise<PlanRow | null> {
  const { data, error } = await loose(admin).from("chatgpt_plans").select("*").match(who(person)).maybeSingle();
  if (error) throw new Error(`Couldn't read the ChatGPT plan connection: ${error.message}`);
  return (data as PlanRow | null) ?? null;
}

async function savePlan(admin: Db, person: Person, patch: Partial<PlanRow>): Promise<void> {
  const { error } = await loose(admin).from("chatgpt_plans").upsert({ ...who(person), ...patch }, { onConflict: "user_id,company_id" });
  if (error) throw new Error(`Couldn't save the ChatGPT plan connection: ${error.message}`);
}

async function loadTokens(env: Env, admin: Db, person: Person): Promise<PlanTokens | null> {
  const { data, error } = await loose(admin).from("chatgpt_plan_secrets").select("ciphertext").match(who(person)).maybeSingle();
  if (error) throw new Error(`Couldn't read the ChatGPT plan sign-in: ${error.message}`);
  return data ? decryptJson<PlanTokens>(env, (data as { ciphertext: string }).ciphertext) : null;
}

/** Saving new tokens also gives up the hold a refresh had on them. */
async function saveTokens(env: Env, admin: Db, person: Person, tokens: PlanTokens): Promise<void> {
  const row = { ...who(person), ciphertext: await encryptJson(env, tokens), expires_at: new Date(tokens.expires_at).toISOString(), refresh_claimed_until: null, updated_at: new Date().toISOString() };
  let { error } = await loose(admin).from("chatgpt_plan_secrets").upsert(row, { onConflict: "user_id,company_id" });
  // The refresh token just used is spent: losing its replacement means signing in again, so once more.
  if (error) ({ error } = await loose(admin).from("chatgpt_plan_secrets").upsert(row, { onConflict: "user_id,company_id" }));
  if (error) throw new Error(`Couldn't store the ChatGPT plan sign-in: ${error.message}`);
}

const dropTokens = (admin: Db, person: Person) => loose(admin).from("chatgpt_plan_secrets").delete().match(who(person));

/** The companies where a person's plan is connected, and what's in its way at each, for their sign-in's list of companies. */
export async function connectedPlans(admin: Db, userId: string): Promise<Array<{ company_id: string; problem: PlanProblem | null }>> {
  const { data, error } = await loose(admin).from("chatgpt_plans").select("company_id, problem").eq("user_id", userId).eq("status", "connected");
  // Not worth failing a sign-in over: without it the plan just isn't shown as in use.
  if (error) console.error("Couldn't read ChatGPT plan connections", error.message);
  return (data ?? []) as Array<{ company_id: string; problem: PlanProblem | null }>;
}

/**
 * A company stops letting its whole team use their own plans: everyone's but the owners' and admins'
 * is disconnected now, and the chatgpt_plans task signs their tokens out at OpenAI.
 */
export async function endTeamPlans(admin: Db, companyId: string, keep: readonly string[]): Promise<void> {
  let query = loose(admin).from("chatgpt_plans").update({ status: "disconnected", problem: null, problem_at: null, retry_at: null }).eq("company_id", companyId).eq("status", "connected");
  if (keep.length) query = query.not("user_id", "in", `(${keep.join(",")})`);
  const { error } = await query;
  if (error) throw new Error(`Couldn't disconnect the team's ChatGPT plans: ${error.message}`);
}

/** What the page is told about a person's plan connection. Never a token, the client's id or the account's id. */
export interface PlanStatus {
  status: "connected" | "disconnected";
  email: string | null;
  model: string | null;
  models: OpenAiModel[];
  /** The server sets the model (OPENAI_MODEL), so it isn't picked on the page. */
  model_locked: boolean;
  problem: PlanProblem | null;
  /** "You're using your ChatGPT plan" has been dismissed. */
  notice_seen: boolean;
  /** Signed in here before with the account in `email`: signing in again is the same registration. */
  registered: boolean;
  connected_at: string | null;
}

export function planStatus(env: Env, row: PlanRow | null): PlanStatus {
  const models = Array.isArray(row?.models) ? row.models : [];
  return {
    status: row?.status === "connected" ? "connected" : "disconnected",
    email: row?.account_email ?? null,
    model: row?.status === "connected" ? (pickModel(env, models, row.model) ?? row.model) : null,
    models,
    model_locked: Boolean(env.OPENAI_MODEL),
    problem: row?.problem ?? null,
    notice_seen: Boolean(row?.notice_seen_at),
    registered: Boolean(row?.client_id),
    connected_at: row?.connected_at ?? null,
  };
}

/** What stands in the way of a person's plan, and when it's tried again (null: once they act). Null clears it. */
export async function notePlanProblem(admin: Db, person: Person, problem: PlanProblem | null, retryInMs: number | null = null): Promise<void> {
  const patch = problem
    ? { problem, problem_at: new Date().toISOString(), retry_at: retryInMs === null ? null : new Date(Date.now() + retryInMs).toISOString() }
    : { problem: null, problem_at: null, retry_at: null };
  const { error } = await loose(admin).from("chatgpt_plans").update(patch).match(who(person));
  if (error) console.error("Couldn't note a ChatGPT plan's state", person.companyId, error.message);
}

/** "You're using your ChatGPT plan" was read: it's shown once, the first time a person connects. */
export async function markNoticeSeen(admin: Db, person: Person): Promise<void> {
  const { error } = await loose(admin).from("chatgpt_plans").update({ notice_seen_at: new Date().toISOString() }).match(who(person)).is("notice_seen_at", null);
  if (error) throw new Error(`Couldn't save that the notice was read: ${error.message}`);
}

/** Remember a kind of ask the plan turned down as unsupported, so it isn't sent again. */
export async function notePlanUnsupported(admin: Db, person: Person, row: PlanRow, kind: string): Promise<void> {
  if (row.unsupported.includes(kind)) return;
  row.unsupported = [...row.unsupported, kind].slice(-20);
  const { error } = await loose(admin).from("chatgpt_plans").update({ unsupported: row.unsupported }).match(who(person));
  if (error) console.error("Couldn't note what a ChatGPT plan doesn't take", person.companyId, error.message);
}

// ---------------------------------------------------------------------------------------------
// Signing in
// ---------------------------------------------------------------------------------------------

async function hostId(admin: Db): Promise<string> {
  const { data, error } = await loose(admin).rpc("chatgpt_host_id");
  if (error || typeof data !== "string" || !data.startsWith("urn:uuid:")) throw new Error(`This Crewtavo's id for OpenAI couldn't be read${error ? `: ${error.message}` : ""}`);
  return data;
}

/**
 * Step one: OpenAI's sign-in page for this person, to open in a new tab. The first time for an
 * account it registers a client for it there; later it's that client again, with the account's
 * email as a hint. `fresh` starts over with a new registration (another ChatGPT account).
 */
export async function startSignIn(env: Env, admin: Db, person: Person, options: { fresh?: boolean } = {}): Promise<{ authorization_url: string; redirect_uri: string; expires_at: string }> {
  const [row, host] = await Promise.all([loadPlan(admin, person), hostId(admin)]);
  // The registration is for this Crewtavo: one made under another host id isn't reused.
  const registered = !options.fresh && row?.client_id && row.host_id === host ? row.client_id : null;
  const state = randomId(24);
  const attempt: Attempt = { verifier: randomId(48), nonce: randomId(24), client_id: registered ?? FIRST_CLIENT, host_id: host };
  const challenge = toBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(attempt.verifier))));
  const expires = new Date(Date.now() + ATTEMPT_MS).toISOString();
  // One sign-in under way for a person at a time: starting again forgets the last.
  await loose(admin).from("chatgpt_sign_ins").delete().match(who(person));
  const { error } = await loose(admin).from("chatgpt_sign_ins").insert({ state, ...who(person), ciphertext: await encryptJson(env, attempt), expires_at: expires });
  if (error) throw new Error(`Couldn't start a ChatGPT sign-in: ${error.message}`);
  const params = new URLSearchParams({
    response_type: "code",
    client_id: attempt.client_id,
    ...(registered ? {} : { agent_name_hint: APP_NAME }),
    ext_agent_host_id: host,
    redirect_uri: REDIRECT_URI,
    scope: SCOPE,
    resource: RESOURCE,
    state,
    nonce: attempt.nonce,
    code_challenge_method: "S256",
    code_challenge: challenge,
    ...(registered && row?.account_email ? { login_hint: row.account_email } : {}),
  });
  return { authorization_url: `${AUTHORIZE}?${params}`, redirect_uri: REDIRECT_URI, expires_at: expires };
}

/** What was pasted, as the parts of the address OpenAI sent the browser to: the whole address, or just what follows its question mark. */
export function pastedParams(pasted: string): URLSearchParams | null {
  const text = pasted.trim();
  if (!text || text.length > 6000) return null;
  const query = (text.includes("?") ? text.slice(text.indexOf("?") + 1) : text).split("#")[0]!.trim();
  if (!query.includes("=")) return null;
  const params = new URLSearchParams(query);
  return params.get("state") ? params : null;
}

const START_AGAIN = "Press Continue with ChatGPT and try again.";

/**
 * Step two: the address the browser landed on, pasted in. It must carry the one-time value of the
 * sign-in this person started here in the last ten minutes, which is used up by being read,
 * whatever happens next. The plan counts as connected only once OpenAI exchanged the code, the
 * sign-in is OpenAI's own for this client, it grants plan use, and the plan's models were listed.
 * Anything short of that says what happened and stores no tokens.
 */
export async function finishSignIn(env: Env, admin: Db, person: Person, pasted: string): Promise<PlanRow> {
  const params = pastedParams(pasted);
  if (!params) throw new HttpError(400, "That isn't the address from ChatGPT's sign-in. Copy the whole address from the address bar of the page that couldn't be reached. It starts with http://127.0.0.1.");
  const { data: taken, error } = await loose(admin)
    .from("chatgpt_sign_ins")
    .delete()
    .match({ state: params.get("state"), ...who(person) })
    .gt("expires_at", new Date().toISOString())
    .select("ciphertext")
    .maybeSingle();
  if (error) throw new Error(`Couldn't read the ChatGPT sign-in: ${error.message}`);
  if (!taken) throw new HttpError(400, `That address isn't from the sign-in you just started, or it's more than ten minutes old or was used already. ${START_AGAIN}`);
  const attempt = await decryptJson<Attempt>(env, (taken as { ciphertext: string }).ciphertext);

  if (params.get("error") === "access_denied") throw new HttpError(400, "You declined on ChatGPT's page, so your plan wasn't connected.");
  if (params.get("error")) throw new HttpError(400, `ChatGPT didn't finish the sign-in. ${START_AGAIN}`);
  const code = params.get("code");
  if (!code) throw new HttpError(400, `That address has no sign-in code in it. ${START_AGAIN}`);

  // A first sign-in comes back with the client OpenAI registered; a later one must be the same client.
  const first = attempt.client_id === FIRST_CLIENT;
  const returned = params.get("client_id");
  if (first && (!returned || returned === FIRST_CLIENT || !/^[\w.:-]{1,200}$/.test(returned))) {
    throw new HttpError(400, `ChatGPT didn't finish registering Crewtavo for your account. ${START_AGAIN}`);
  }
  if (!first && returned && returned !== attempt.client_id) throw new HttpError(400, `That sign-in came back for a different registration than the one saved for you, so it wasn't used. ${START_AGAIN}`);
  const clientId = first ? returned! : attempt.client_id;

  const exchanged = await tokenRequest({ grant_type: "authorization_code", client_id: clientId, code, code_verifier: attempt.verifier, redirect_uri: REDIRECT_URI, resource: RESOURCE });
  const tokens = exchanged.json;
  if (!exchanged.ok || !tokens?.access_token) {
    if (exchanged.code === "invalid_grant") throw new HttpError(400, `That sign-in code was used already or has run out. ${START_AGAIN}`);
    throw new HttpError(502, `ChatGPT didn't complete the sign-in. ${START_AGAIN}`);
  }
  const before = await loadPlan(admin, person);
  // From here on there are tokens: whatever stops the connection signs them out again. A new
  // registration is kept for next time, unless a connection is still live on the one before it.
  const giveUp = async (status: 400 | 502, message: string, keepRegistration: boolean): Promise<never> => {
    if (tokens.refresh_token) await revoke(tokens.refresh_token, clientId);
    if (keepRegistration && first && before?.status !== "connected") await savePlan(admin, person, { client_id: clientId, host_id: attempt.host_id }).catch(() => undefined);
    throw new HttpError(status, message);
  };

  let account: { sub: string; email: string | null };
  try {
    account = await verifyIdToken(tokens.id_token ?? "", { clientId, nonce: attempt.nonce });
  } catch (reason) {
    console.error("A ChatGPT sign-in couldn't be verified", (reason as Error).message);
    return giveUp(502, `ChatGPT's sign-in couldn't be checked, so nothing was connected. ${START_AGAIN}`, false);
  }
  if (!first && before?.account_sub && before.account_sub !== account.sub) {
    return giveUp(400, "That's a different ChatGPT account from the one you connected before. Sign in with that one, or choose Use a different account first.", false);
  }
  // What was granted is what OpenAI's token endpoint says, never the pasted address, which the person
  // could have changed. An answer that names no scope grants what was asked for (RFC 6749, 5.1).
  const granted = (tokens.scope ?? SCOPE).split(/[\s+]+/);
  if (!granted.includes(PLAN_SCOPE) || !tokens.refresh_token) {
    return giveUp(400, "You signed in, but using your ChatGPT plan here wasn't allowed, so nothing was connected. Start again and allow it, or use an OpenAI API key instead.", true);
  }

  let models: OpenAiModel[];
  try {
    models = await listPlanModels(tokens.access_token);
  } catch (reason) {
    const notEligible = reason instanceof OpenAiProblem && (reason.kind === "not_eligible" || reason.kind === "not_allowed");
    return giveUp(notEligible ? 400 : 502, notEligible ? `ChatGPT says your plan can't be used here. ${ELIGIBLE}` : `You signed in, but ChatGPT didn't list your plan's models, so nothing was connected. ${START_AGAIN}`, true);
  }
  const model = pickModel(env, models, before?.model);
  if (!model) return giveUp(400, `ChatGPT lists no models for your plan here, so nothing was connected. ${ELIGIBLE}`, true);

  // A new registration in place of another that was still signed in: the old one is signed out.
  if (before?.client_id && before.client_id !== clientId) {
    const old = await loadTokens(env, admin, person).catch(() => null);
    if (old?.refresh_token) await revoke(old.refresh_token, before.client_id);
  }
  await saveTokens(env, admin, person, { client_id: clientId, access_token: tokens.access_token, refresh_token: tokens.refresh_token, expires_at: Date.now() + (tokens.expires_in ?? 3600) * 1000, scope: granted.join(" ") });
  await savePlan(admin, person, {
    status: "connected",
    client_id: clientId,
    host_id: attempt.host_id,
    account_sub: account.sub,
    account_email: account.email,
    model: env.OPENAI_MODEL ? (before?.model ?? null) : model,
    models,
    unsupported: [],
    problem: null,
    problem_at: null,
    retry_at: null,
    connected_at: new Date().toISOString(),
  });
  return (await loadPlan(admin, person))!;
}

/** Which plans can be used this way, said wherever one can't. */
export const ELIGIBLE = "ChatGPT Plus and Pro plans can be used; an OpenAI API key is the other way.";

// ---------------------------------------------------------------------------------------------
// The access token, refreshed
// ---------------------------------------------------------------------------------------------

/** Why a plan's token couldn't be had: the sign-in has ended, or OpenAI couldn't be asked just now. */
export class PlanTrouble extends Error {
  override name = "PlanTrouble";
  constructor(readonly kind: "sign_in" | "unavailable") {
    super(`ChatGPT plan ${kind}`);
  }
}

/** Good for at least two more minutes. */
const stillGood = (tokens: PlanTokens) => tokens.expires_at - Date.now() > 120_000;

/** Reads of a person's token under way in this server. */
const reading = new Map<string, Promise<string>>();

/**
 * A person's access token, refreshed when it's within two minutes of running out, or (`renew`) when
 * OpenAI just turned it down.
 *
 * OpenAI replaces the refresh token every time it's used, so it must be used once: within this
 * server everyone who asks meanwhile shares one read, and between servers (two run side by side
 * during an update) the database hands the tokens to one refresher at a time
 * (claim_chatgpt_plan_refresh) while the others wait for the new ones to be saved.
 */
export function planAccess(env: Env, admin: Db, person: Person, renew = false): Promise<string> {
  const key = `${person.userId}:${person.companyId}:${renew}`;
  const going = reading.get(key);
  if (going) return going;
  const shared: Promise<string> = readAccess(env, admin, person, renew).finally(() => {
    if (reading.get(key) === shared) reading.delete(key);
  });
  reading.set(key, shared);
  return shared;
}

async function readAccess(env: Env, admin: Db, person: Person, renew: boolean): Promise<string> {
  const stored = await loadTokens(env, admin, person);
  // Connected, but its tokens are gone: said plainly on the connection, rather than left looking as if the plan were in use.
  if (!stored) {
    await endSignIn(admin, person);
    throw new PlanTrouble("sign_in");
  }
  if (!renew && stillGood(stored)) return stored.access_token;
  for (let waited = 0; ; waited += 400) {
    const { data: claimed, error } = await loose(admin).rpc("claim_chatgpt_plan_refresh", { p_user: person.userId, p_company: person.companyId });
    if (error) throw new PlanTrouble("unavailable");
    if (typeof claimed === "string") {
      const latest = await decryptJson<PlanTokens>(env, claimed);
      // Another server refreshed between this one's look and its turn: those are the tokens to use.
      if (latest.access_token !== stored.access_token && stillGood(latest)) {
        await loose(admin).from("chatgpt_plan_secrets").update({ refresh_claimed_until: null }).match(who(person));
        return latest.access_token;
      }
      return refresh(env, admin, person, latest);
    }
    // Another server is refreshing them now: wait for what it saves.
    if (waited >= 20_000) throw new PlanTrouble("unavailable");
    await sleep(400);
    const now = await loadTokens(env, admin, person);
    if (!now) throw new PlanTrouble("sign_in");
    if (now.access_token !== stored.access_token && stillGood(now)) return now.access_token;
  }
}

async function refresh(env: Env, admin: Db, person: Person, tokens: PlanTokens): Promise<string> {
  const row = await loadPlan(admin, person);
  const answered = row?.client_id ? await tokenRequest({ grant_type: "refresh_token", client_id: row.client_id, refresh_token: tokens.refresh_token, resource: RESOURCE }) : null;
  const json = answered?.json;
  if (answered?.ok && json?.access_token) {
    const scope = json.scope ?? tokens.scope;
    const next: PlanTokens = { client_id: tokens.client_id ?? row?.client_id ?? undefined, access_token: json.access_token, refresh_token: json.refresh_token ?? tokens.refresh_token, expires_at: Date.now() + (json.expires_in ?? 3600) * 1000, scope };
    await saveTokens(env, admin, person, next);
    return next.access_token;
  }
  // Only a definite no from OpenAI ends the sign-in: one of the refusals it names, or another error
  // it names for a request that is itself wrong. An outage, a timeout, "slow down", or an answer
  // that isn't OpenAI's own (a proxy's error page) leaves the tokens for the next try.
  if (!answered || (answered.code && (REFRESH_ENDED.has(answered.code) || [400, 401].includes(answered.status)))) {
    await endSignIn(admin, person, answered?.code === "invalid_client");
    throw new PlanTrouble("sign_in");
  }
  await loose(admin).from("chatgpt_plan_secrets").update({ refresh_claimed_until: null }).match(who(person));
  throw new PlanTrouble("unavailable");
}

/** The sign-in is over at OpenAI: the tokens go, and the page says to sign in again. `forget`: the registration too. */
async function endSignIn(admin: Db, person: Person, forget = false): Promise<void> {
  await dropTokens(admin, person);
  const { error } = await loose(admin)
    .from("chatgpt_plans")
    .update({ status: "disconnected", problem: "sign_in", problem_at: new Date().toISOString(), retry_at: null, ...(forget ? { client_id: null, host_id: null } : {}) })
    .match(who(person));
  if (error) console.error("Couldn't mark a ChatGPT plan as signed out", person.companyId, error.message);
}

// ---------------------------------------------------------------------------------------------
// Models, signing out, and tidying
// ---------------------------------------------------------------------------------------------

/** The plan's models read again from OpenAI, and the one in use: the one picked while it's still listed. */
export async function refreshPlanModels(env: Env, admin: Db, person: Person): Promise<PlanRow> {
  const row = await loadPlan(admin, person);
  if (!row || row.status !== "connected") throw new PlanTrouble("sign_in");
  const models = await listPlanModels(await planAccess(env, admin, person));
  const model = env.OPENAI_MODEL ? row.model : pickModel(env, models, row.model);
  const { error } = await loose(admin).from("chatgpt_plans").update({ models, model, ...(model !== row.model ? { unsupported: [] } : {}) }).match(who(person));
  if (error) throw new Error(`Couldn't save the ChatGPT plan's models: ${error.message}`);
  return { ...row, models, model, unsupported: model !== row.model ? [] : row.unsupported };
}

export async function choosePlanModel(env: Env, admin: Db, person: Person, model: string): Promise<void> {
  if (env.OPENAI_MODEL) throw new HttpError(409, `This server is set to use ${env.OPENAI_MODEL} (OPENAI_MODEL), so the model can't be changed here.`);
  const row = await loadPlan(admin, person);
  if (!row || row.status !== "connected") throw new HttpError(409, "Connect your ChatGPT plan first.");
  if (!row.models.some((m) => m.slug === model)) throw new HttpError(400, "ChatGPT doesn't list that model for your plan. Check for new models, then pick one.");
  const { error } = await loose(admin).from("chatgpt_plans").update({ model, unsupported: [] }).match(who(person));
  if (error) throw new Error(`Couldn't save the model: ${error.message}`);
}

/**
 * Disconnect: signed out at OpenAI first, then the tokens are deleted here whether or not OpenAI
 * answered. The registration stays, so signing in again later is the same one. `revoked` false:
 * OpenAI didn't confirm, and the person is told where to remove Crewtavo themselves.
 */
export async function disconnectPlan(env: Env, admin: Db, person: Person): Promise<{ revoked: boolean }> {
  const [row, tokens] = await Promise.all([loadPlan(admin, person), loadTokens(env, admin, person).catch(() => null)]);
  const client = tokens?.client_id ?? row?.client_id;
  const revoked = tokens?.refresh_token && client ? await revoke(tokens.refresh_token, client) : true;
  // The connection says disconnected before its tokens go, so it never says connected without them;
  // tokens that then fail to delete are leftovers, which the task clears.
  if (row) {
    const { error } = await loose(admin).from("chatgpt_plans").update({ status: "disconnected", problem: null, problem_at: null, retry_at: null, unsupported: [] }).match(who(person));
    if (error) throw new Error(`Couldn't save the ChatGPT plan connection: ${error.message}`);
  }
  const dropped = await dropTokens(admin, person);
  if (dropped.error) throw new Error(`Couldn't delete the ChatGPT plan sign-in: ${dropped.error.message}`);
  await loose(admin).from("chatgpt_sign_ins").delete().match(who(person));
  return { revoked };
}

/**
 * The chatgpt_plans task: tokens left without a connected plan (their person left the company, was
 * turned off, or is gone) are signed out at OpenAI and deleted, and sign-ins nobody finished are
 * cleared away. Tokens OpenAI couldn't be reached about stay for the next pass, for a day.
 */
export async function tidyPlans(env: Env, admin: Db): Promise<{ signed_out: number; removed: number; waiting: number }> {
  const done = { signed_out: 0, removed: 0, waiting: 0 };
  await loose(admin).from("chatgpt_sign_ins").delete().lt("expires_at", new Date().toISOString());
  const { data, error } = await loose(admin).rpc("chatgpt_plan_leftovers", { p_limit: 50 });
  if (error) throw new Error(`Couldn't read leftover ChatGPT plan sign-ins: ${error.message}`);
  for (const left of (data ?? []) as Array<{ user_id: string; company_id: string; ciphertext: string; client_id: string | null; updated_at?: string }>) {
    const tokens = await decryptJson<PlanTokens>(env, left.ciphertext).catch(() => null);
    const client = tokens?.client_id ?? left.client_id;
    const revoked = tokens?.refresh_token && client ? await revoke(tokens.refresh_token, client) : !tokens?.refresh_token;
    // OpenAI couldn't be reached about it just now: kept to try again, for a day past its hour of use.
    if (!revoked && tokens && client && tokens.expires_at + 86_400_000 > Date.now()) {
      done.waiting++;
      continue;
    }
    // Only the tokens that were read: someone who signed in again meanwhile keeps their new ones.
    await dropTokens(admin, { userId: left.user_id, companyId: left.company_id }).eq("ciphertext", left.ciphertext);
    if (revoked) done.signed_out++;
    done.removed++;
  }
  return done;
}
