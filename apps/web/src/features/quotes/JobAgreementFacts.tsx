/** Planet Ops Phase 1d: the job's agreement status, read from the quote it was made from. */
import { useQuery } from "@tanstack/react-query";
import { supabase, unwrap } from "@/lib/api";
import { AgreementFacts } from "./AgreementFacts";

export function JobAgreementFacts({ quoteId }: { quoteId: string }) {
  const quote = useQuery({
    queryKey: ["quote", quoteId, "agreement"],
    queryFn: async () => unwrap(await supabase().from("quotes").select("id, status, approval").eq("id", quoteId).maybeSingle()),
  });
  return quote.data ? <AgreementFacts quote={quote.data} /> : null;
}
