/**
 * Planet Ops Phase 4: job costs, disposal and the PDOS record, the screens' side
 * (supabase/migrations/20261127000100_planet_ops_job_costs.sql).
 */
import { supabase, unwrap } from "@/lib/api";
import { uploadFile } from "@/lib/files";
import { can, type Session } from "@/lib/session";

export type CostKind = "receipt" | "supplier_invoice" | "dump_ticket" | "photo" | "other";
export const KIND_LABELS: Record<CostKind, string> = { receipt: "Receipt", supplier_invoice: "Supplier invoice", dump_ticket: "Dump ticket", photo: "Photo", other: "Other" };
/** Suggested categories (the business can type its own). */
export const CATEGORIES = ["fuel", "tools", "materials", "equipment rental", "disposal", "hauling", "subcontractor", "permits", "ppe", "other"];

/** The office with job costs reviews and sees every cost. */
export const reviewsCosts = (session: Session) => ["owner", "admin", "office"].includes(session.role) && can(session, "job_costs");

/** SHA-256 of the original file (before any shrinking), hex: the same file is the same document. */
export async function sha256(file: Blob): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Uploads a file and registers it; the same file again returns the document already there. */
export async function uploadCostDocument(companyId: string, jobId: string | null, kind: CostKind, file: File) {
  const checksum = await sha256(file);
  const path = await uploadFile(companyId, "receipts", file);
  return unwrap(await supabase().rpc("register_cost_document" as never, { p_company: companyId, p_kind: kind, p_path: path, p_checksum: checksum, p_file_name: file.name, p_size: file.size, p_job: jobId } as never)) as unknown as { id: string; duplicate: boolean; review_status: string };
}

export interface CostDocument {
  id: string;
  job_id: string | null;
  kind: CostKind;
  storage_path: string;
  file_name: string | null;
  uploaded_at: string;
  suggested: { vendor?: string; document_number?: string; document_date?: string; total?: number; category?: string; confidence?: number; missing?: string[] } | null;
  vendor: string | null;
  document_number: string | null;
  document_date: string | null;
  total: number | null;
  category: string | null;
  review_status: "pending" | "approved" | "reference_only" | "duplicate" | "rejected";
  review_note: string | null;
  reviewed_at: string | null;
}

export const DOCUMENT_COLUMNS = "id, job_id, kind, storage_path, file_name, uploaded_at, suggested, vendor, document_number, document_date, total, category, review_status, review_note, reviewed_at";

export interface DisposalTicket {
  id: string;
  direction: "outgoing" | "delivered_fill";
  load_date: string;
  hauler: string | null;
  facility: string | null;
  ticket_number: string | null;
  material_stream: string | null;
  is_metal: boolean;
  short_tons: number | null;
  container_capacity_cy: number | null;
  reported_loose_cy: number | null;
  quantity_basis: string;
  tipping_fee: number | null;
  hauling_charge: number | null;
  credit_amount: number | null;
  expense_id: string | null;
}

export interface Financials {
  estimate_costs_visible: boolean;
  original_estimate: { version: number; approved_at: string; base_cost?: number; selling_price?: number } | null;
  job_estimate: { version: number; status: string; base_cost?: number; selling_price?: number } | null;
  latest_approved_revision: { version: number; base_cost?: number } | null;
  actual_costs: { approved: number | null; paid: number | null; provisional: number | null; committed: number | null; count: number; by_category: Record<string, number> } | null;
  disposal: Record<string, number | null>;
  contract_value: number | null;
  original_contract: number | null;
  invoiced: number | null;
  paid: number | null;
  outstanding: number | null;
}
