/**
 * Planet Ops Phase 1d: someone who prepares pricing (the sales area) without the "Send pricing to
 * customers" area gets this instead of a send dialog. The server and the database refuse the send
 * too; this only says so up front.
 */
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { can, useSession } from "@/lib/session";

export const useCanSendPricing = () => {
  const session = useSession();
  return can(session, "send_pricing");
};

export function NoSendPricing({ onClose }: { onClose: () => void }) {
  return (
    <Dialog open onClose={onClose} title="Someone else sends this" description="You can prepare the pricing, but sending it to the customer needs the Send pricing to customers area." size="sm">
      <div className="stack">
        <p style={{ margin: 0 }}>It's saved as it is. Ask an owner, an admin or someone who sends pricing to look it over and send it. Your role's areas are in Settings → Team.</p>
        <div className="form-actions"><Button variant="primary" onClick={onClose}>OK</Button></div>
      </div>
    </Dialog>
  );
}
