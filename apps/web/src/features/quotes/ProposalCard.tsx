/**
 * Planet Ops Phase 1b: the customer document's layout and its words, on the quote page.
 *
 *   - Layout: a line-item quote (priced lines) or a proposal (overview, scope in work order,
 *     inclusions, exclusions, assumptions, optional alternates, and one total). Switching keeps
 *     prices, scope and terms: it only changes how the customer sees it.
 *   - Contract Terms and Payment Terms: two separate sections, filled from the company's defaults
 *     (Settings → Quotes and payments) and edited for the job before it's sent.
 *
 * All of it is part of the signed version: a change before signing makes a customer's open page
 * outdated, and once signed it stays as signed (20261120000100, 20261120000200). This is the
 * customer-facing document only; internal costs and markup belong to Estimating (Phase 3).
 */
import { NARRATIVE_MAX, NARRATIVE_SECTIONS, PRESENTATION_HINTS, PRESENTATION_LABELS, PRESENTATIONS, TERMS_MAX, isPresentation, proposalSettings, readNarrative, type NarrativeKey, type Presentation } from "@crewtavo/core/proposals";
import type { Json } from "@crewtavo/core/database";
import { useEffect, useId, useState } from "react";
import { Button } from "@/components/ui/Button";
import { useSession } from "@/lib/session";

export interface ProposalFields {
  presentation?: string | null;
  narrative?: unknown;
  contract_terms?: string | null;
  payment_terms?: string | null;
}

export type ProposalPatch = { presentation?: Presentation; narrative?: Exclude<Json, null>; contract_terms?: string | null; payment_terms?: string | null };

/**
 * The document type, chosen first: a line-item quote or a proposal. It's a choice about what the
 * customer receives, kept apart from how the office looks at it while editing (Edit / Preview).
 * `value`/`onChange` as a form control (the new-document dialog); `editable` false shows it as
 * text (a sent or signed document keeps the type it went out as).
 */
export function DocumentTypeChoice({ value, onChange, editable = true, compact = false }: { value: Presentation; onChange: (p: Presentation) => void; editable?: boolean; compact?: boolean }) {
  const name = useId();
  if (!editable) {
    return (
      <div className="row wrap" style={{ gap: 8, alignItems: "baseline" }} data-planet-ops="document-type">
        <span className="muted small">Document type</span>
        <strong>{PRESENTATION_LABELS[value]}</strong>
      </div>
    );
  }
  return (
    <fieldset className="stack-xs" style={{ border: 0, margin: 0, padding: 0, minWidth: 0 }} data-planet-ops="document-type">
      <legend className="strong small" style={{ padding: 0, marginBottom: 6 }}>Document type</legend>
      <div style={{ display: "grid", gap: 8, gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 220px), 1fr))" }}>
        {PRESENTATIONS.map((p) => (
          <label key={p} className="card card-pad" style={{ display: "flex", gap: 10, alignItems: "flex-start", cursor: "pointer", padding: compact ? 10 : undefined, borderColor: value === p ? "var(--accent, #1C50E4)" : undefined, boxShadow: value === p ? "0 0 0 1px var(--accent, #1C50E4)" : undefined }}>
            <input type="radio" name={name} value={p} checked={value === p} onChange={() => value !== p && onChange(p)} style={{ marginTop: 3 }} />
            <span className="stack-xs">
              <strong>{PRESENTATION_LABELS[p]}</strong>
              {!compact && <span className="muted small">{PRESENTATION_HINTS[p]}</span>}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

/** A text area that saves when it loses focus, as the message to the client does. */
function SavedText({ label, hint, value, max, rows = 4, editable, onEdit, onUnchanged, onSave }: { label: string; hint?: string; value: string; max: number; rows?: number; editable: boolean; onEdit: () => void; onUnchanged: () => void; onSave: (v: string) => void }) {
  const id = useId();
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  if (!editable) {
    return value ? (
      <div className="stack-xs">
        <strong className="small">{label}</strong>
        <p className="pre-wrap" style={{ margin: 0 }}>{value}</p>
      </div>
    ) : null;
  }
  return (
    <div className="stack-xs">
      <label htmlFor={id}>
        <strong className="small">{label}</strong>
        {hint && <span className="muted small"> · {hint}</span>}
      </label>
      <textarea
        id={id}
        className="textarea"
        rows={rows}
        value={draft}
        maxLength={max}
        onChange={(e) => {
          setDraft(e.target.value);
          onEdit();
        }}
        onBlur={() => (draft !== value ? onSave(draft) : onUnchanged())}
      />
    </div>
  );
}

export function ProposalCard({ quote, editable, onEdit, onUnchanged, onSave }: { quote: ProposalFields; editable: boolean; onEdit: () => void; onUnchanged: () => void; onSave: (patch: ProposalPatch) => void }) {
  const session = useSession();
  const defaults = proposalSettings(session.company.settings);
  const presentation: Presentation = isPresentation(quote.presentation) ? quote.presentation : "line_items";
  const narrative = readNarrative(quote.narrative);
  const saveSection = (key: NarrativeKey, text: string) => onSave({ narrative: { ...narrative, [key]: text.trim() || null } as Exclude<Json, null> });
  const contract = quote.contract_terms ?? "";
  const payment = quote.payment_terms ?? "";
  const placeholder = (text: string) => /\bTEST\b|placeholder/i.test(text);

  return (
    <div className="card card-pad stack" data-planet-ops="customer-document">
      <div className="row wrap" style={{ justifyContent: "space-between", gap: 12 }}>
        <strong>{presentation === "proposal" ? "Proposal sections and terms" : "Terms"}</strong>
        <span className="muted small">{PRESENTATION_LABELS[presentation]}</span>
      </div>
      <p className="muted small" style={{ margin: 0 }}>
        {presentation === "proposal"
          ? "The customer sees these sections and one total, without priced lines. The total is the same as the line items come to. Change the document type at the top of the page."
          : "The customer sees the priced lines and their total, then these terms. Change the document type at the top of the page."}
      </p>

      {presentation === "proposal" &&
        NARRATIVE_SECTIONS.map(({ key, label, hint }) => (
          <SavedText key={key} label={label} hint={hint} value={narrative[key] ?? ""} max={NARRATIVE_MAX} rows={key === "scope" ? 6 : 3} editable={editable} onEdit={onEdit} onUnchanged={onUnchanged} onSave={(text) => saveSection(key, text)} />
        ))}

      <SavedText label="Contract Terms" value={contract} max={TERMS_MAX} rows={5} editable={editable} onEdit={onEdit} onUnchanged={onUnchanged} onSave={(text) => onSave({ contract_terms: text.trim() || null })} />
      {editable && defaults.contractTerms && contract !== defaults.contractTerms && (
        <div><Button size="sm" variant="ghost" icon="undo" onClick={() => onSave({ contract_terms: defaults.contractTerms })}>Use the company's Contract Terms</Button></div>
      )}
      <SavedText label="Payment Terms" value={payment} max={TERMS_MAX} rows={4} editable={editable} onEdit={onEdit} onUnchanged={onUnchanged} onSave={(text) => onSave({ payment_terms: text.trim() || null })} />
      {editable && defaults.paymentTerms && payment !== defaults.paymentTerms && (
        <div><Button size="sm" variant="ghost" icon="undo" onClick={() => onSave({ payment_terms: defaults.paymentTerms })}>Use the company's Payment Terms</Button></div>
      )}
      {(placeholder(contract) || placeholder(payment)) && (
        <p className="callout callout-warning small" style={{ margin: 0 }}>These terms are placeholders. Replace them with the approved wording before sending to a real customer.</p>
      )}
      {!contract && !payment && editable && (
        <p className="muted small" style={{ margin: 0 }}>No terms yet. Add the company's approved Contract Terms and Payment Terms in Settings → Quotes and payments, or write them for this job.</p>
      )}
    </div>
  );
}
