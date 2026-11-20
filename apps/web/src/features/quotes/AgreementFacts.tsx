/**
 * Planet Ops Phase 1d: where an agreement stands, each fact from its own record (core
 * agreementFacts): customer accepted (their drawn signature), company countersigned (only when the
 * business requires it), deposit (its invoice's payments, never the signature), and ready to
 * schedule (what the business requires: the signatures, and the deposit when it says so in Settings →
 * Quotes and payments).
 */
import { agreementFacts, proposalSettings } from "@crewtavo/core/proposals";
import { useQuery } from "@tanstack/react-query";
import { Icon } from "@/components/ui/Icon";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { useSession } from "@/lib/session";

type Approval = { name?: string; signed_at?: string; company?: { name?: string; signed_at?: string } | null } | null;

export function AgreementFacts({ quote }: { quote: { id: string; status: string; approval: unknown } }) {
  const { company } = useSession();
  const settings = proposalSettings(company.settings);
  const deposit = useQuery({
    queryKey: ["quote-deposit", quote.id],
    queryFn: async () => unwrap(await supabase().rpc("quote_deposit_status", { p_quote: quote.id })) as { asked: number | null; paid: number | null } | null,
  });
  const asked = Number(deposit.data?.asked ?? 0);
  const paid = deposit.data?.paid == null ? null : Number(deposit.data.paid);
  const facts = agreementFacts({ status: quote.status, approval: quote.approval, countersignRequired: settings.countersignRequired, depositBeforeScheduling: settings.depositBeforeScheduling, depositAsked: asked, depositPaid: paid });
  const a = (quote.approval ?? null) as Approval;
  const rows: Array<{ key: string; label: string; ok: boolean | null; text: string }> = [
    { key: "customer", label: "Customer accepted", ok: facts.customerAccepted, text: facts.customerAccepted ? `Signed${a?.signed_at ? ` ${formatDate(a.signed_at)}` : ""}${a?.name ? ` by ${a.name}` : ""}` : "Not yet: waiting for the customer's signature" },
    {
      key: "countersign",
      label: "Company countersigned",
      ok: facts.countersign === "waiting" ? false : facts.countersign === "done" ? true : null,
      text: facts.countersign === "done" ? `Signed${a?.company?.signed_at ? ` ${formatDate(a.company.signed_at)}` : ""}${a?.company?.name ? ` by ${a.company.name}` : ""}` : facts.countersign === "waiting" ? "Waiting for your company's countersignature" : "Not required",
    },
    {
      key: "deposit",
      label: "Deposit",
      ok: facts.deposit === "received" ? true : facts.deposit === "none" ? null : false,
      text: deposit.isPending ? "…" : facts.deposit === "none" ? "None asked for" : facts.deposit === "received" ? `Received (${formatMoneyCents(paid)})` : facts.deposit === "partly_paid" ? `${formatMoneyCents(paid)} of ${formatMoneyCents(asked)} paid` : `${formatMoneyCents(asked)} owed, not paid yet`,
    },
    {
      key: "ready",
      label: "Ready to schedule",
      ok: facts.readyToSchedule,
      text: facts.readyToSchedule ? "Yes" : `Not yet: waiting for ${facts.waitingFor.map((w) => (w === "customer" ? "the customer's signature" : w === "countersign" ? "the countersignature" : "the deposit")).join(", ")}`,
    },
  ];
  return (
    <div className="card card-pad stack-sm" data-planet-ops="agreement-facts">
      <strong>Agreement status</strong>
      <ul className="stack-xs" style={{ listStyle: "none", margin: 0, padding: 0 }}>
        {rows.map((r) => (
          <li key={r.key} className="row" style={{ gap: 8, alignItems: "baseline" }} data-fact={r.key} data-ok={r.ok === null ? "na" : String(r.ok)}>
            <Icon name={r.ok ? "check" : r.ok === false ? "clock" : "minus"} size={16} />
            <span className="strong small" style={{ minWidth: 170 }}>{r.label}</span>
            <span className="small">{r.text}</span>
          </li>
        ))}
      </ul>
      {!settings.depositBeforeScheduling && facts.deposit !== "none" && <span className="muted small">Ready to schedule doesn't wait for the deposit (Settings → Quotes and payments).</span>}
    </div>
  );
}
