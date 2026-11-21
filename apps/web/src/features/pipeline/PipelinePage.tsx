/**
 * Planet Ops Phase 2: the Sales pipeline. "Requests" is the pipeline itself (RequestPipeline: each
 * request by its stage, with its owner, next action and filters); "Quotes" is the quote board below.
 *
 * The quote board: open requests and quotes as a board with value and age. Drag a request to
 * "Drafting quote" to start a quote, a draft to "Awaiting response" to send it, or anything to "Lost".
 * Planet Ops: a quote reaches "Approved" only when the customer signs it (the database refuses an
 * office approval), so a quote dropped there is refused with how it gets signed. Until it's signed,
 * a quote that offers options is valued at its cheapest option's price (quotes/options.ts listPrice),
 * as on the quotes list.
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type DragEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { confirm } from "@/components/ui/Confirm";
import { Icon } from "@/components/ui/Icon";
import { BackLink, PageHeader } from "@/components/ui/PageHeader";
import { Loading, Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/States";
import { statusText } from "@/components/ui/StatusPill";
import { api, supabase, unwrap } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast, type ToastTone } from "@/lib/toast";
import { listPrice, withOptionLines } from "../quotes/options";
import { optionsNote } from "../quotes/QuotesPage";
import { SendDialog } from "../quotes/SendDialog";
import { PipelineReport, PricingHistory } from "./PipelineReport";
import { RequestPipeline } from "./RequestPipeline";

interface Card {
  kind: "request" | "quote";
  id: string;
  status: string;
  number: number | null;
  title: string;
  client: string;
  email: string | null;
  phone: string | null;
  value: number | null;
  /** The value is its cheapest option's: it offers options and isn't signed yet. */
  from: boolean;
  updated: string;
  /** How many options a quote offers. */
  options: number;
  /** The option shown first; once it's signed, the one chosen, which its value is for. */
  option: { name: string; tier: string | null } | null;
}
type ColumnKey = "new" | "assess" | "draft" | "sent" | "won";

/** Planet Ops: only the customer's drawn signature approves a quote. */
export const CUSTOMER_SIGNS = "A quote is approved when the customer signs it. Send it to them to sign, or have them sign it in person.";

/**
 * Why a card dropped on a column can't move there from the board, or null when it can. "Approved"
 * is never a drop target for a quote: only the customer's signature approves one.
 */
export function moveRefusal(card: Pick<Card, "kind" | "options">, to: ColumnKey | "lost"): string | null {
  return card.kind === "quote" && to === "won" ? CUSTOMER_SIGNS : null;
}

const COLUMNS: Array<{ key: ColumnKey; label: string; statuses: string[]; kind: Card["kind"]; color: string }> = [
  { key: "new", label: "New requests", statuses: ["new"], kind: "request", color: "var(--req)" },
  { key: "assess", label: "Assessments", statuses: ["assessment_scheduled", "assessment_complete"], kind: "request", color: "var(--req)" },
  { key: "draft", label: "Drafting quote", statuses: ["draft"], kind: "quote", color: "var(--quote)" },
  { key: "sent", label: "Awaiting response", statuses: ["sent", "changes_requested"], kind: "quote", color: "var(--quote)" },
  { key: "won", label: "Approved", statuses: ["approved"], kind: "quote", color: "var(--job)" },
];

const daysOld = (iso: string) => Math.floor((Date.now() - Date.parse(iso)) / 86_400_000);

const TABS = [
  { key: "requests", label: "Requests" },
  { key: "quotes", label: "Quotes" },
  { key: "report", label: "Report" },
  { key: "pricing", label: "Pricing history" },
] as const;
type Tab = (typeof TABS)[number]["key"];

export function PipelinePage() {
  const [params, setParams] = useSearchParams();
  const tab: Tab = TABS.find((t) => t.key === params.get("view"))?.key ?? "requests";
  return (
    <>
      <BackLink to="/requests">Requests</BackLink>
      <PageHeader title="Sales pipeline" />
      <div className="tabs" role="group" aria-label="Sales pipeline" style={{ marginBottom: 16 }}>
        {TABS.map((t) => (
          <button key={t.key} type="button" className="tab" aria-pressed={tab === t.key} onClick={() => setParams(t.key === "requests" ? {} : { view: t.key }, { replace: true })}>{t.label}</button>
        ))}
      </div>
      {tab === "requests" && <RequestPipeline />}
      {tab === "quotes" && <QuoteBoard />}
      {tab === "report" && <PipelineReport />}
      {tab === "pricing" && <PricingHistory />}
    </>
  );
}

function QuoteBoard() {
  const { company } = useSession();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [dragging, setDragging] = useState<Card | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [sending, setSending] = useState<Card | null>(null);
  const key = ["pipeline", company.id];

  const data = useQuery({
    queryKey: key,
    queryFn: async () => {
      const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
      const [requests, quotes, closed] = await Promise.all([
        supabase().from("requests").select("id, number, title, status, updated_at, client:clients(display_name, email, phone)").eq("company_id", company.id).in("status", ["new", "assessment_scheduled", "assessment_complete"]),
        supabase().from("quotes").select("id, number, title, status, total, tax_rate, discount_amount, promo:promo_codes(kind, value), updated_at, client:clients(display_name, email, phone), options:quote_options!quote_options_quote_fkey(id), option:quote_options!quotes_option_fkey(name, tier)").eq("company_id", company.id).in("status", ["draft", "sent", "changes_requested", "approved"]).eq("is_template", false),
        supabase().from("quotes").select("id, status, total, tax_rate, discount_amount, promo:promo_codes(kind, value), options:quote_options!quote_options_quote_fkey(id)").eq("company_id", company.id).in("status", ["converted", "lost"]).gte("updated_at", since),
      ]);
      // Quotes that offer options are worth their cheapest option until they're signed.
      const [open, c] = await Promise.all([withOptionLines(unwrap(quotes)), withOptionLines(unwrap(closed))]);
      const cards: Card[] = [
        ...unwrap(requests).map((x) => ({ kind: "request" as const, id: x.id, status: x.status, number: x.number, title: x.title, client: x.client?.display_name ?? "", email: x.client?.email ?? null, phone: x.client?.phone ?? null, value: null, from: false, updated: x.updated_at, options: 0, option: null })),
        ...open.map((x) => {
          const price = listPrice(x);
          return { kind: "quote" as const, id: x.id, status: x.status, number: x.number, title: x.title, client: x.client?.display_name ?? "", email: x.client?.email ?? null, phone: x.client?.phone ?? null, value: price.amount, from: price.from, updated: x.updated_at, options: x.options.length, option: x.option };
        }),
      ];
      const won = c.filter((q) => q.status === "converted");
      const lost = c.filter((q) => q.status === "lost");
      return { cards, won: { count: won.length, value: won.reduce((s, q) => s + listPrice(q).amount, 0) }, lost: { count: lost.length, value: lost.reduce((s, q) => s + listPrice(q).amount, 0) } };
    },
  });

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: key });
    queryClient.invalidateQueries({ queryKey: ["quotes", company.id] });
    queryClient.invalidateQueries({ queryKey: ["requests", company.id] });
  };
  const move = useMutation({
    mutationFn: async ({ card, to }: { card: Card; to: ColumnKey | "lost" }): Promise<{ message: string; open?: string; refused?: boolean; tone?: ToastTone }> => {
      if (to === "lost") {
        if (card.kind === "quote") unwrap(await supabase().from("quotes").update({ status: "lost", lost_reason: "Marked lost from the pipeline" }).eq("id", card.id));
        else unwrap(await supabase().from("requests").update({ status: "archived" }).eq("id", card.id));
        return { message: card.kind === "quote" ? `Quote #${card.number} marked lost` : "Request archived", tone: card.kind };
      }
      if (card.kind === "request" && to === "draft") {
        const quote = await api.post<{ id: string }>(`/requests/${card.id}/quote`);
        return { message: "Quote started", open: `/quotes/${quote.id}`, tone: "quote" };
      }
      throw new Error("That move isn't possible.");
    },
    onSuccess: (r) => {
      const action = r.open ? { action: { label: "Open", onClick: () => navigate(r.open!) } } : undefined;
      if (r.refused) toast.error(r.message, action);
      else toast.success(r.message, { ...action, tone: r.tone });
      refresh();
    },
  });

  const allowed = (card: Card, to: ColumnKey | "lost") =>
    to === "lost" ? true
    : card.kind === "request" ? to === "draft"
    : card.status === "draft" ? to === "sent"
    : ["sent", "changes_requested"].includes(card.status) ? to === "won"
    : false;
  const drop = async (to: ColumnKey | "lost") => {
    const card = dragging;
    setDragging(null);
    setOver(null);
    if (!card || !allowed(card, to)) return;
    const refusal = moveRefusal(card, to);
    if (refusal) return void toast.error(refusal, { action: { label: "Open", onClick: () => navigate(`/quotes/${card.id}`) } });
    if (card.kind === "quote" && card.status === "draft" && to === "sent") return setSending(card);
    if (to === "lost" && !(await confirm({ title: card.kind === "quote" ? `Mark quote #${card.number} lost?` : "Archive this request?", body: card.kind === "quote" ? "You can reopen it later from the quote." : "It leaves the pipeline. You can reopen it from the request.", confirmLabel: card.kind === "quote" ? "Mark lost" : "Archive", danger: true }))) return;
    move.mutate({ card, to });
  };
  const zone = (to: ColumnKey | "lost") => ({
    onDragOver: (e: DragEvent) => {
      if (dragging && allowed(dragging, to)) {
        e.preventDefault();
        if (over !== to) setOver(to);
      }
    },
    onDragLeave: (e: DragEvent) => !(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node) && setOver(null),
    onDrop: (e: DragEvent) => {
      e.preventDefault();
      drop(to);
    },
    "data-drop": over === to || undefined,
  });

  const cards = data.data?.cards ?? [];
  const openValue = cards.reduce((s, c) => s + (c.value ?? 0), 0);
  const winRate = data.data && data.data.won.count + data.data.lost.count ? Math.round((data.data.won.count / (data.data.won.count + data.data.lost.count)) * 100) : null;

  return (
    <>
      {data.data && (
        <div className="stat-row">
          <div className="card stat"><div className="label">Open quotes</div><div className="value">{formatMoney(openValue)}</div><div className="hint">{cards.filter((c) => c.kind === "quote").length} quotes · {cards.filter((c) => c.kind === "request").length} requests</div></div>
          <div className="card stat"><div className="label">Won (30 days)</div><div className="value">{formatMoney(data.data.won.value)}</div><div className="hint">{data.data.won.count} converted to jobs</div></div>
          <div className="card stat"><div className="label">Lost (30 days)</div><div className="value">{formatMoney(data.data.lost.value)}</div><div className="hint">{data.data.lost.count} quotes</div></div>
          <div className="card stat"><div className="label">Win rate (30 days)</div><div className="value">{winRate === null ? "—" : `${winRate}%`}</div></div>
        </div>
      )}
      {data.error && <div className="card"><ErrorState error={data.error} onRetry={() => data.refetch()} /></div>}
      {data.isPending ? (
        <Loading><div className="board">{COLUMNS.map((c) => <div key={c.key} className="board-col"><Skeleton width="60%" height={14} />{[0, 1].map((i) => <Skeleton key={i} height={70} radius={8} />)}</div>)}</div></Loading>
      ) : (
        <div className="board">
          {COLUMNS.map((col) => {
            const items = cards.filter((c) => c.kind === col.kind && col.statuses.includes(c.status)).sort((a, b) => a.updated.localeCompare(b.updated));
            const total = items.reduce((s, c) => s + (c.value ?? 0), 0);
            return (
              <section key={col.key} className="board-col" style={{ ["--stage" as string]: col.color }} aria-label={col.label} {...zone(col.key)}>
                <div className="board-col-head">
                  <strong>{col.label}</strong>
                  <span className="badge">{items.length}</span>
                  {total > 0 && <span className="muted">{formatMoney(total)}</span>}
                </div>
                {items.map((c) => {
                  const age = daysOld(c.updated);
                  return (
                    <Link
                      key={c.id}
                      to={`/${c.kind === "quote" ? "quotes" : "requests"}/${c.id}`}
                      className="deal"
                      draggable
                      data-dragging={dragging?.id === c.id || undefined}
                      data-stale={age >= 7 || undefined}
                      onDragStart={(e) => {
                        e.dataTransfer.effectAllowed = "move";
                        e.dataTransfer.setData("text/plain", c.id);
                        setDragging(c);
                      }}
                      onDragEnd={() => {
                        setDragging(null);
                        setOver(null);
                      }}
                    >
                      <span className="d-title">{c.title}</span>
                      <span className="muted small ellipsis">{c.client}</span>
                      <span className="d-meta">
                        <span>{c.status === "changes_requested" ? <span className="text-danger strong">{statusText("quote", c.status)}</span> : `#${c.number}`}</span>
                        <span style={age >= 14 ? { color: "var(--danger)", fontWeight: 600 } : age >= 7 ? { color: "var(--warning)", fontWeight: 600 } : undefined}>{age === 0 ? "Today" : `${age} ${age === 1 ? "day" : "days"}`}</span>
                      </span>
                      {c.value != null && (
                        <span className="d-value">
                          {c.from ? `From ${formatMoney(c.value)}` : formatMoney(c.value)}
                          {c.options > 0 && <span className="muted small" style={{ fontWeight: 600, overflowWrap: "anywhere" }}> · {optionsNote(c.status, c.options, c.option)}</span>}
                        </span>
                      )}
                    </Link>
                  );
                })}
                {items.length === 0 && <span className="muted small" style={{ padding: "4px 2px" }}>Nothing here</span>}
              </section>
            );
          })}
        </div>
      )}
      {dragging && (
        <div className="card row" style={{ justifyContent: "center", padding: 16, borderStyle: "dashed", borderColor: over === "lost" ? "var(--danger)" : undefined, background: over === "lost" ? "var(--danger-tint)" : undefined, color: "var(--danger)", fontWeight: 600, position: "sticky", bottom: 16, transition: "background 150ms" }} {...zone("lost")}>
          <Icon name="x" size={16} />Drop here to mark {dragging.kind === "quote" ? "lost" : "archived"}
        </div>
      )}
      {sending && <SendDialog kind="quote" id={sending.id} number={sending.number} email={sending.email} phone={sending.phone} onClose={() => setSending(null)} onSent={refresh} />}
    </>
  );
}
