/**
 * Planet Ops branding (Phase 0, docs/PLANET_OPS_IMPLEMENTATION_PLAN.md).
 *
 * Planet Ops is a modified version of Crewtavo. NOTICE section 7(c)/(e) asks a modified version to
 * be marked as different and not to use the Crewtavo name or logo, except to say truthfully that it
 * is based on Crewtavo. So the user-facing name changes here, in one place, instead of a blind
 * repository-wide rename: package names (@crewtavo/*), the Railway service name `crewtavo`,
 * storage keys, environment variables and database objects keep their upstream names so that
 * deployments, migrations and integrations keep working.
 *
 * `brandText` is applied by the translation layer (i18n/index.ts), so every line that goes through
 * `t()` in the web app and the API shows the Planet Ops name in English and Spanish without
 * changing the English catalog keys.
 */

export const PRODUCT_NAME = "Planet Ops";
/** The upstream project this version is based on, for attribution and legal text. */
export const UPSTREAM_NAME = "Crewtavo";
export const UPSTREAM_SOURCE_URL = "https://github.com/jviars/crewtavo";
/** This modified version's source (AGPL section 13 asks a modified version to offer its own). */
export const SOURCE_URL = "https://github.com/planetdevelop/crm1";

/** Brand colors from the approved branding review. */
export const BRAND_BLUE = "#1C50E4";
export const BRAND_GREEN = "#17801B";

/**
 * Phrases that name the upstream project on purpose and must stay as written: its legal terms, its
 * documentation (crewtavo.com/docs) and attribution.
 */
const KEEP = ["Crewtavo Terms", "Crewtavo docs", "Crewtavo's docs", "based on Crewtavo", "Crewtavo notice"] as const;

const KEEP_MARK = "\u0000";

/** Replaces the upstream product name with Planet Ops in user-facing text, keeping legal/attribution phrases. */
export function brandText(text: string): string {
  if (typeof text !== "string" || !text.includes(UPSTREAM_NAME)) return text;
  const kept: string[] = [];
  let out = text;
  for (const phrase of KEEP) {
    out = out.split(phrase).join(`${KEEP_MARK}${kept.push(phrase) - 1}${KEEP_MARK}`);
  }
  out = out.replace(/\bCrewtavo\b/g, PRODUCT_NAME);
  return out.replace(new RegExp(`${KEEP_MARK}(\\d+)${KEEP_MARK}`, "g"), (_, i: string) => kept[Number(i)]!);
}
