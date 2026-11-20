/**
 * Planet Ops Phase 1d: preparing pricing (the sales area) is apart from sending it to the customer
 * (send_pricing). Asked before anything goes out, so nothing is emailed, texted or shown to sign that
 * the database would then refuse to record as sent (public.can_send_pricing, 20261121000200).
 */
import { dbError, HttpError } from "./http";
import type { Db } from "./supabase";

export const NO_SEND_PRICING = 'Sending pricing to the customer needs the "Send pricing to customers" area. You can prepare it; ask someone who can send it.';

export async function canSendPricing(db: Db, companyId: string): Promise<boolean> {
  const { data, error } = await db.rpc("can_send_pricing", { p_company: companyId });
  if (error) throw dbError(error);
  return data === true;
}

export async function requireSendPricing(db: Db, companyId: string): Promise<void> {
  if (!(await canSendPricing(db, companyId))) throw new HttpError(403, NO_SEND_PRICING);
}
