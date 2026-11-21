/**
 * Planet Ops Phase 4: the cost review queue (Job costs): every receipt, invoice, ticket and photo
 * waiting for review across jobs, including the general inbox (files uploaded without a job), with an
 * upload for the inbox.
 */
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { PageHeader } from "@/components/ui/PageHeader";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";
import { DOCUMENT_COLUMNS, KIND_LABELS, reviewsCosts, type CostDocument } from "./data";
import { ReviewDialog, UploadButton } from "./JobCostsPanel";

export function CostReviewPage() {
  const session = useSession();
  const allowed = reviewsCosts(session);
  const [status, setStatus] = useState<"pending" | "all">("pending");
  const docs = useQuery({
    queryKey: ["cost-review", session.company.id, status],
    enabled: allowed,
    queryFn: async () => {
      let q = supabase().from("cost_documents" as never).select(`${DOCUMENT_COLUMNS}, job:jobs(number, title)`).eq("company_id", session.company.id).order("uploaded_at", { ascending: false }).limit(300);
      if (status === "pending") q = q.eq("review_status", "pending");
      return unwrap(await q) as unknown as Array<CostDocument & { job: { number: number; title: string } | null }>;
    },
  });
  const [reviewing, setReviewing] = useState<CostDocument | null>(null);
  if (!allowed) return <EmptyState title="Cost review is for the office with Job costs">Ask an owner or admin for the Job costs area.</EmptyState>;
  return (
    <>
      <PageHeader title="Cost review" actions={<UploadButton jobId={null} />} />
      <p className="muted">Receipts, supplier invoices, dump tickets and photos waiting for review. A suggestion counts as nothing until it's approved; the original file is always kept.</p>
      <div className="tabs" role="group" aria-label="Show">
        <button type="button" className="tab" aria-pressed={status === "pending"} onClick={() => setStatus("pending")}>Waiting for review</button>
        <button type="button" className="tab" aria-pressed={status === "all"} onClick={() => setStatus("all")}>All</button>
      </div>
      {docs.error ? <ErrorState error={docs.error} onRetry={() => docs.refetch()} /> : (docs.data ?? []).length === 0 ? <EmptyState title="Nothing waiting">New uploads appear here for review.</EmptyState> : (
        <table className="table table-stack" aria-label="Cost documents to review" data-planet-ops="cost-review">
          <thead><tr><th>File</th><th>Job</th><th>Suggested</th><th>Status</th><th /></tr></thead>
          <tbody>
            {(docs.data ?? []).map((d) => (
              <tr key={d.id}>
                <td>{KIND_LABELS[d.kind]} <span className="muted small">{d.file_name ?? ""} · {formatDate(d.uploaded_at)}</span></td>
                <td>{d.job ? `#${d.job.number} ${d.job.title}` : <span className="muted">Inbox (no job yet)</span>}</td>
                <td className="small">{d.suggested ? `${d.suggested.vendor ?? "?"} · ${d.suggested.category ?? "?"} · ${d.suggested.total ?? "?"}` : <span className="muted">No suggestion</span>}</td>
                <td>{d.review_status.replace("_", " ")}</td>
                <td><Button size="sm" onClick={() => setReviewing(d)}>Review</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {reviewing && <ReviewDialog document={reviewing} defaultJob={reviewing.job_id} onClose={() => setReviewing(null)} />}
    </>
  );
}
