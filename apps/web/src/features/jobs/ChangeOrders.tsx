/**
 * Change orders on a job: extra work (or a credit, or a $0 scope or schedule change) priced as a
 * quote, signed by the customer, then added to the job. Planet Ops: only the customer's signature on
 * the exact version finalizes one (core changeOrders.ts; the database enforces it).
 */
import { useMutation, useQuery } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { EntityStatus } from "@/components/ui/StatusPill";
import { supabase, unwrap } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import { useListAnimation } from "@/lib/motion";
import { useSession } from "@/lib/session";
import { changeOrderSignature } from "@crewtavo/core/changeOrders";

export function useStartChangeOrder(job: { id: string; title: string; client: { id: string } | null; property: { id: string } | null }) {
  const session = useSession();
  const navigate = useNavigate();
  return useMutation({
    meta: { success: "Change order started", tone: "quote" },
    mutationFn: async () =>
      unwrap(
        await supabase()
          .from("quotes")
          .insert({ company_id: session.company.id, client_id: job.client!.id, property_id: job.property?.id ?? null, title: `Change order: ${job.title}`.slice(0, 200), change_order_for: job.id })
          .select("id")
          .single(),
      ),
    onSuccess: (q) => navigate(`/quotes/${q.id}`),
  });
}

export function ChangeOrders({ jobId, onStart, starting }: { jobId: string; onStart: () => void; starting: boolean }) {
  const orders = useQuery({
    queryKey: ["job", jobId, "change-orders"],
    queryFn: async () => unwrap(await supabase().from("quotes").select("id, number, title, status, total, approval, change_order_for").eq("change_order_for", jobId).order("created_at")),
  });
  const listRef = useListAnimation<HTMLDivElement>();
  if (!orders.data?.length) return null;
  return (
    <section className="stack">
      <div className="section-head">
        <h2 className="section-title">Change orders</h2>
        <Button size="sm" icon="plus" loading={starting} onClick={onStart}>New change order</Button>
      </div>
      <div className="card" ref={listRef}>
        {orders.data.map((o) => (
          <Link key={o.id} to={`/quotes/${o.id}`} className="card-row">
            <strong className="grow">#{o.number} · {o.title.replace(/^Change order: /, "")}</strong>
            {["sent", "changes_requested"].includes(o.status) && !changeOrderSignature(o).signed && <span className="muted small">Awaiting customer signature</span>}
            <span className="tabular">{formatMoney(o.total)}</span>
            <EntityStatus kind="quote" status={o.status === "converted" ? "approved" : o.status} />
          </Link>
        ))}
      </div>
    </section>
  );
}
