/**
 * Text that arrives already written in English, and is translated by its shape: notifications the
 * database and the server wrote (stored as finished English, read later by the bell, push, email
 * and texts), and the database's own error messages (`raise exception`). Each line of a table is
 * the English with {captures} and the translation with the same {captures}:
 *
 *   ["{title} now starts {when}", "{title} ahora empieza el {when}"]
 *
 * Reading the shape rather than changing every writer keeps old rows, and rows an older server
 * still writes during an update, readable in Spanish too. Text that matches no line stays English.
 *
 * What a capture's name says about it, and what it will match:
 *   when…, was…, date…, time…  a date or time as the database writes it in English ("Thu Oct 15,
 *                              9:00 AM", "Oct 15, 2026", "6:00 PM Thu"), and nothing else, rewritten
 *                              in Spanish. A sentence is split around the date's own shape, so a
 *                              title with " on " or ": " in it stays whole.
 *   count…, number…, days…,    digits (a count, a job's number)
 *   hours…
 *   word…                      a word from the table's own word list (a document's name, "hours"),
 *                              translated
 *   line…                      an offer's line ("Smith roof, Tue Nov 3 to Thu Nov 5, 24 squares,
 *                              $2,040"): its dates, squares and days in Spanish, the rest as it is
 *   anything else              left as it is (a visit's title, a person's name, an amount)
 *
 * Notifications are read by their kind (notifications.kind): each kind's writers have their own
 * shapes (NoticeGroup), and a notification of another kind is never held against them. What
 * somebody typed (a chat message, a client's reason, a title) only ever passes through a capture
 * as it is: it is never matched against sentences. A notification whose title or body isn't a
 * shape its kind writes stays in English whole, rather than half translated.
 */
import { brandText } from "../brand";
import { oneOClock, translator, type Locale } from "./index";

export type PatternTable = ReadonlyArray<readonly [english: string, translation: string]>;

interface Compiled {
  re: RegExp;
  translation: string;
}

/**
 * The notifications one kind's writers make: the shapes of their titles and of each line of their
 * bodies. `from` names the database functions that write them (the test reads those functions'
 * own text, so a change of wording there fails it).
 */
export interface NoticeGroup {
  /** notifications.kind. */
  kind: string;
  from: readonly string[];
  titles: PatternTable;
  bodies: PatternTable;
  /**
   * The body is somebody's own words (a chat message): it's left exactly as written, unless it is
   * word for word one of `bodies` (what the database puts there when there are no words).
   */
  freeBody?: boolean;
}

interface CompiledGroup {
  kind: string;
  titles: Compiled[];
  bodies: Compiled[];
  freeBody: boolean;
}

const tables: Partial<Record<Locale, { notices: CompiledGroup[]; errors: Compiled[]; words: Record<string, string> }>> = {};

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// A date or time as the database writes one, for finding it inside a sentence (DATE_SHAPES, below, reads its parts).
const A_DAY = `(?:${WEEKDAYS.join("|")})`;
const A_MONTH = `(?:${MONTHS.join("|")})`;
const A_TIME = "\\d{1,2}:\\d{2} ?(?:AM|PM)";
const A_DATE = `(?:${A_DAY},? ${A_MONTH} \\d{1,2}(?:(?:,| at) ${A_TIME})?|${A_MONTH} \\d{1,2}(?:, \\d{4})?(?:(?:,| at) ${A_TIME})?|${A_TIME}(?: ${A_DAY})?)`;

/** What a capture will match, by its name (see the top of this file). */
function captureSource(name: string): string {
  if (/^(when|was|date|time)/.test(name)) return A_DATE;
  if (/^(count|number|days|hours)/.test(name)) return "\\d[\\d,.]*";
  return ".+?";
}

/**
 * "{title} now starts {when}" as a pattern anchored at both ends: {when} matches only a date as the
 * database writes one, so the sentence is split around the date and a title is whatever is left,
 * " on " and ": " and all; other captures take as little as they can.
 */
export function compilePattern(english: string): RegExp {
  const parts = english.split(/(\{\w+\})/);
  const source = parts.map((part) => (/^\{\w+\}$/.test(part) ? `(?<${part.slice(1, -1)}>${captureSource(part.slice(1, -1))})` : escape(part))).join("");
  return new RegExp(`^${source}$`, "s");
}

const compile = (table: PatternTable): Compiled[] => table.map(([english, translation]) => ({ re: compilePattern(english), translation }));

/** Adds a language's tables: the API at start-up, the web app with its catalog. */
export function addPatterns(locale: Locale, patterns: { notices?: readonly NoticeGroup[]; errors?: PatternTable; words?: Record<string, string> }) {
  const now = tables[locale] ?? { notices: [], errors: [], words: {} };
  tables[locale] = {
    notices: [...now.notices, ...(patterns.notices ?? []).map((g) => ({ kind: g.kind, titles: compile(g.titles), bodies: compile(g.bodies), freeBody: g.freeBody === true }))],
    errors: [...now.errors, ...compile(patterns.errors ?? [])],
    words: { ...now.words, ...patterns.words },
  };
}
const ES_WEEKDAYS = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"];
const ES_WEEKDAYS_LONG = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
const ES_MONTHS = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"];

const DY = `(?<dy>${WEEKDAYS.join("|")})`;
const MON = `(?<mon>${MONTHS.join("|")})`;
const TIME = "(?<h>\\d{1,2}):(?<mi>\\d{2}) ?(?<ampm>AM|PM)";

const DATE_SHAPES = [
  // "Thu Oct 15", "Thu, Oct 15", "Thu Oct 15, 9:00 AM", "Thu, Oct 15 at 9:00 AM"
  new RegExp(`^${DY},? ${MON} (?<d>\\d{1,2})(?:(?:,| at) ${TIME})?$`),
  // "Oct 15", "Oct 15, 2026", "Oct 15, 9:00 AM"
  new RegExp(`^${MON} (?<d>\\d{1,2})(?:, (?<y>\\d{4}))?(?:(?:,| at) ${TIME})?$`),
  // "9:00 AM", "6:00 PM Thu"
  new RegExp(`^${TIME}(?: ${DY})?$`),
];

/** A date or time the database wrote in English, in Spanish: "Thu Oct 15, 9:00 AM" → "jue, 15 de oct, 9:00 a.m.". */
export function spanishDate(text: string): string | null {
  for (const shape of DATE_SHAPES) {
    const g = text.trim().match(shape)?.groups;
    if (!g) continue;
    const time = g.h ? `${g.h}:${g.mi} ${g.ampm === "AM" ? "a.m." : "p.m."}` : null;
    const weekday = g.dy ? WEEKDAYS.indexOf(g.dy) : -1;
    if (!g.mon) return weekday >= 0 ? `${time} del ${ES_WEEKDAYS_LONG[weekday]}` : time;
    const day = `${Number(g.d)} de ${ES_MONTHS[MONTHS.indexOf(g.mon)]}${g.y ? ` de ${g.y}` : ""}`;
    return [weekday >= 0 ? `${ES_WEEKDAYS[weekday]}, ${day}` : day, time].filter(Boolean).join(", ");
  }
  return null;
}

/** "Smith roof, Tue Nov 3 to Thu Nov 5, 24 squares, $2,040" with its dates, squares and days in Spanish. */
export function spanishLine(text: string): string {
  const day = new RegExp(`${DY} ${MON} (?<d>\\d{1,2})`, "g");
  return text
    .replace(day, (...m) => {
      const g = m.at(-1) as Record<string, string>;
      return `${ES_WEEKDAYS[WEEKDAYS.indexOf(g.dy!)]} ${Number(g.d)} de ${ES_MONTHS[MONTHS.indexOf(g.mon!)]}`;
    })
    .replace(/(de \w+) to (\p{L}{3} )/gu, "$1 a $2")
    .replace(/\b(\d[\d,.]*) squares?\b/g, (_, n: string) => `${n} ${n === "1" ? "cuadro" : "cuadros"}`)
    .replace(/\b(\d[\d,.]*) days?\b/g, (_, n: string) => `${n} ${n === "1" ? "día" : "días"}`);
}

function apply(locale: Locale, text: string, compiled: Compiled[]): string | null {
  const words = tables[locale]?.words ?? {};
  for (const { re, translation } of compiled) {
    const found = text.match(re);
    if (!found) continue;
    // A line with no {captures} has no groups at all.
    const groups = found.groups ?? {};
    // "9:00 a.m." ending a sentence takes no second period, and one o'clock is "la 1:15", not "las 1:15".
    return oneOClock(fillCaptures(translation, groups, locale, words).replace(/([ap]\.m\.)\./g, "$1"));
  }
  return null;
}

/** The translation with each {capture} in, rewritten as its name says (see the top of this file). */
function fillCaptures(translation: string, groups: Record<string, string>, locale: Locale, words: Record<string, string>): string {
  return translation.replace(/\{(\w+)\}/g, (whole, name: string) => {
    const value = groups[name];
    if (value === undefined) return whole;
    if (/^(when|was|date|time)/.test(name)) return (locale === "es" && spanishDate(value)) || value;
    if (/^word/.test(name)) return words[value] ?? value;
    if (/^line/.test(name)) return locale === "es" ? spanishLine(value) : value;
    return value;
  });
}

/**
 * A notification in a person's language, read by its kind: its title, and its body line by line
 * (a batch of schedule changes is one line per change). All of it or none: when its kind has no
 * shapes, or the title or any line of the body isn't one its kind writes, it stays as written, in
 * English, rather than half in each. Somebody's own words (a chat message) are never read at all.
 */
export function translateNotice<N extends { kind?: string | null; title: string; body?: string | null }>(locale: Locale | string | null | undefined, notice: N): N {
  if (locale !== "es" || !tables.es || !notice.kind) return notice;
  for (const group of tables.es.notices) {
    if (group.kind !== notice.kind) continue;
    const title = apply("es", notice.title, group.titles);
    if (title == null) continue;
    if (notice.body == null) return { ...notice, title };
    if (group.freeBody) {
      // Their own words stay as they wrote them; only the database's stand-in for none is translated, whole.
      return { ...notice, title, body: apply("es", notice.body, group.bodies) ?? notice.body };
    }
    const lines = notice.body.split("\n").map((line) => apply("es", line, group.bodies));
    if (lines.some((line) => line == null)) continue;
    return { ...notice, title, body: lines.join("\n") };
  }
  return notice;
}

/** An error message (the database's, or the server's) in a person's language, or as it came. */
export function translateError(locale: Locale | string | null | undefined, message: string): string {
  if (locale !== "es" || !tables.es || !message) return message;
  const exact = translator("es")(message);
  // The translator brands even a line it has no Spanish for (brand.ts), so "translated" means it
  // differs from the branded English, not from the English as sent.
  if (exact !== brandText(message)) return exact;
  return brandText(apply("es", message, tables.es.errors) ?? message);
}

/** For tests: whether the errors table has a line for this text. */
export const patternMatches = (locale: Locale, kind: "errors", text: string) => (tables[locale]?.[kind] ?? []).some(({ re }) => re.test(text));
