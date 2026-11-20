/**
 * The office's quote page (/quotes/:id), for every trade and for change orders: its lines, message,
 * totals, deposit, template and contract, sending it, and what comes after (approved, a job, lost).
 * Its lines show as an editable list or as the paper it prints as (the Paper view), and "Print or
 * save PDF" prints those same pages.
 *
 * A quote that offers options (quote_options) has the options bar above its lines (QuoteOptions.tsx).
 * Looking at an option changes nothing for the customer: the page shows that option's lines, totals,
 * contract and paper. Marking it approved, or making it a job, first asks which option they chose,
 * and an approval made here keeps that option and the contract as they read then (quotes.approval),
 * as a signature on the Client Hub or the iPad does. The option math is core money.ts; options.ts has
 * the option records.
 */
import { changeOrderBlocker, isCustomerSignature } from "@crewtavo/core/changeOrders";
import { depositFor } from "@crewtavo/core/contracts";
import { shownCustomFields } from "@crewtavo/core/customFields";
import { usesDepth } from "@crewtavo/core/formulas";
import type { TablesUpdate } from "@crewtavo/core/database";
import type { TemplateSettings } from "@crewtavo/core/documents";
import { inRangeMode, sitePriceSet } from "@crewtavo/core/estimates";
import { optionBaseTotal, optionTotals, taxPercent, taxRateFromPercent, type Amount, type OptionLine, type TotalsPromo } from "@crewtavo/core/money";
import { isPackagePicturePath } from "@crewtavo/core/presets";
import { quotePromoRule } from "@crewtavo/core/promos";
import { parseRule } from "@crewtavo/core/recurrence";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useMemo, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { AnimatedNumber, MONEY_CENTS } from "@/components/ui/AnimatedNumber";
import { Button, cx } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { MoneyInput } from "@/components/ui/MoneyInput";
import { BackLink, useDocumentTitle } from "@/components/ui/PageHeader";
import { SaveStatus, useSaveStatus } from "@/components/ui/SaveStatus";
import { DetailSkeleton, Skeleton } from "@/components/ui/Skeleton";
import { PageError } from "@/components/ui/States";
import { EntityStatus } from "@/components/ui/StatusPill";
import { api, supabase, unwrap, unwrapOne } from "@/lib/api";
import { ApiError, errorMessage, isAuthError, isNetworkError, isRestarting } from "@/lib/errors";
import { addressLine, formatDate, formatMoney, formatMoneyCents, formatTaxRate, timeAgo, todayIn } from "@/lib/format";
import { useRememberRecent } from "@/lib/recent";
import { can, hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import {
  choiceLabel,
  contractTemplate,
  documentCompany,
  documentOptions,
  isSignedQuote,
  mySignatureKey,
  NO_CONTRACT,
  optionTiers,
  quoteDate,
  quoteDocument,
  readApproval,
  signedTemplate,
  useLetterhead,
  useMySignature,
  useQuoteContract,
  useQuoteTemplate,
  useTemplates,
  type ApprovalOption,
  type DocumentQuote,
  type DocumentQuoteLine,
  type QuoteApproval,
  type QuoteContract,
  type QuoteContractInput,
} from "../documents/data";
import { DocumentSheet } from "../documents/EstimateDocument";
import type { DocumentData } from "../documents/types";
import { SignaturePad } from "../field/SignaturePad";
import { RecurrenceEditor, type Recurrence } from "../jobs/RecurrenceEditor";
import { scheduleText } from "../jobs/repeatText";
import { DrawingsCard } from "../measure/drawings";
import { CustomFieldsCard, useCustomFields } from "../customFields/CustomFields";
import { PlansCard } from "../plans/PlansCard";
import { WorksheetsCard } from "../paving/WorksheetsCard";
import { dayText } from "../roofing/flow/model";
import { QuotePrint, useQuotePrint } from "../roofing/flow/QuotePrint";
import { SendEstimateDialog } from "../roofing/flow/SendEstimateDialog";
import { lineSums, LineItems, visibleLines } from "./LineItems";
import { duplicateQuote, optionsOpen, quoteOptionsKey, sortOptions, useQuoteOptions, viewedOption, type QuoteOptionRow } from "./options";
import styles from "./QuotePage.module.css";
import { depthLines, lineDepths, type DepthLine } from "./depths";
import { AddOptionsDialog, QuoteOptions } from "./QuoteOptions";
import { QuoteSections } from "./QuoteSections";
import { DraftedCallout } from "./DraftedCallout";
import { PaymentScheduleCard } from "./PaymentSchedule";
import { DiscountRows } from "./PromoRow";
import { SendDialog } from "./SendDialog";
import { UsingChatGptPlan } from "@/features/apps/UsingChatGptPlan";

export { SendDialog } from "./SendDialog";

const EDITABLE = ["draft", "sent", "changes_requested"];
/** Before the quote has loaded: the business's default template. */
const NO_QUOTE = { template_id: null, approval: null };
const LOST_REASONS = ["Price was too high", "Went with another company", "Timing didn't work", "No response", "Scope changed", "Other"];
/** The totals card's figures, to the cent as the quote prints them, rolling to their new values. */

/**
 * The quote, with every line (every option's) and what its paper and contract are filled in from. Its
 * options are useQuoteOptions. Its code's `every_visit` is the rule it was approved with once it's
 * signed, so its words don't change after (core quotePromoRule).
 */
async function loadQuote(id: string) {
  const q = await loadQuoteRow(id);
  return q.promo ? { ...q, promo: { ...q.promo, every_visit: quotePromoRule(q) } } : q;
}

async function loadQuoteRow(id: string) {
  return unwrapOne(
    await supabase()
      .from("quotes")
      .select("id, number, title, status, message, subtotal, discount_amount, tax_rate, tax_amount, total, deposit_amount, deposit_percent, valid_until, recurrence_rule, active_months, starts_on, ends_on, sent_at, approved_at, approval, lost_reason, request_id, created_at, template_id, option_id, section_ids, roof_package_id, promo_code_id, promo_every_visit, promo:promo_codes(code, kind, value, description, every_visit), request:requests(promo_code, website_form_id, rejected_promo_code, promo_problem), client:clients(id, display_name, email, phone, billing_address, sms_opt_out_at, tax_exempt, tax_exempt_note), property:properties(id, line1, city, region, postal_code, lat, lng), lines:quote_line_items(id, name, description, quantity, unit, unit_price, unit_cost, taxable, optional, selected, option_group, option_id, formula, sort, service_id), jobs!jobs_company_id_quote_id_fkey(id, number), change_order_for, change_job:jobs!quotes_change_order_fkey(id, number, title), package:roof_packages!quotes_roof_package_fkey(name, warranty, price_mode, markup_pct), range_low, range_high, range_accepted_at, priced_on_site_at, exact_sent_at, custom_fields, is_template, left_out, payment_schedule, drafted")
      .eq("id", id)
      .order("sort", { referencedTable: "quote_line_items" })
      .maybeSingle(),
    "This quote",
  );
}
type QuoteRow = Awaited<ReturnType<typeof loadQuote>>;

// ---------------------------------------------------------------------------------------------
// The options, in plain functions
// ---------------------------------------------------------------------------------------------

/** The parts of a quote its money for each option is worked out from. */
export interface TabQuote {
  status: string;
  /** The option shown first; once signed, the one chosen. */
  option_id: string | null;
  subtotal: Amount;
  discount_amount: Amount;
  tax_amount: Amount;
  total: Amount;
  tax_rate: Amount;
  promo: TotalsPromo | null;
}

/** A quote's money settings, as core money.ts takes them. */
const moneyOf = (q: Pick<TabQuote, "tax_rate" | "discount_amount" | "promo">) => ({ taxRate: q.tax_rate, discountAmount: q.discount_amount, promo: q.promo });

/**
 * Whether a quote offers options: it has option rows, or lines on an option. The quote and its options
 * are read apart, so for a moment after options are added or taken off only one of them may say so.
 */
export const offersOptions = (options: readonly unknown[], lines: ReadonlyArray<{ option_id?: string | null }>) => options.length > 0 || lines.some((l) => l.option_id != null);

/**
 * The totals for the option being looked at: the quote's own (the database's) for the option shown
 * and for a quote without options; for another option, its totals as they'd be once it's the one
 * shown, with its add-ons not picked yet (core optionTotals, to the cent of the database's).
 */
export function tabTotals(q: TabQuote, lines: readonly OptionLine[], optionId: string | null): { subtotal: number; discount: number; tax: number; total: number } {
  if (!optionId || optionId === q.option_id) return { subtotal: Number(q.subtotal ?? 0), discount: Number(q.discount_amount ?? 0), tax: Number(q.tax_amount ?? 0), total: Number(q.total ?? 0) };
  return optionTotals(lines, optionId, q.option_id, moneyOf(q));
}

/** What the totals card says it's for, on a quote that offers options. */
export function totalsCaption(name: string, { shown, signed }: { shown: boolean; signed: boolean }): string {
  if (signed) return shown ? `For ${name}, the option they chose` : `For ${name}, if they had chosen it`;
  return shown ? `For ${name}, the option shown first` : `For ${name}, if they choose it`;
}

/**
 * The most the deposit can be: the cheapest option's price before its add-ons (core optionBaseTotal),
 * so it's never more than they'd pay whichever option they choose and whichever of its add-ons they
 * leave off, with that option's name. The quote's total without options. Options with no lines of
 * their own yet aren't counted.
 */
export function depositCap(q: TabQuote, lines: readonly OptionLine[], options: ReadonlyArray<{ id: string; name: string }>): { amount: number; name: string | null } {
  const priced = options.flatMap((o) => {
    const total = optionBaseTotal(lines, o.id, moneyOf(q));
    return total === null ? [] : [{ name: o.name, total }];
  });
  if (!priced.length) return { amount: Number(q.total ?? 0), name: null };
  const lowest = priced.reduce((low, o) => (o.total < low.total ? o : low));
  return { amount: lowest.total, name: lowest.name };
}

/**
 * The deposit as a percent of the total, for switching a deposit typed as an amount to a percent:
 * the percent that asks for the same, at most 100 (none on a quote with no total yet).
 */
export const depositAsPercent = (amount: Amount, total: Amount) =>
  Number(total) > 0 ? Math.min(100, Math.round((Number(amount) / Number(total)) * 10_000) / 100) : 0;

/** An option as an approval keeps it (approval.option): as it's offered, with the tier word on its card. */
export function approvalOption(option: QuoteOptionRow, tier: string | null): ApprovalOption {
  const picture = option.picture && isPackagePicturePath(option.picture) && option.picture_width && option.picture_height ? { path: option.picture, width: option.picture_width, height: option.picture_height } : null;
  return { id: option.id, name: option.name, tier: tier ?? option.tier ?? null, picture, style: option.style, highlights: [...option.highlights], warranty: option.warranty };
}


/** What a quote's contract is filled in from for one of its options (none without options), as the server fills in the signed copy. */
export function contractFor(
  q: QuoteContractInput["quote"] & Pick<QuoteContractInput, "client" | "property"> & { package?: { name: string; warranty?: string | null } | null },
  template: TemplateSettings,
  option: Pick<QuoteOptionRow, "name" | "warranty" | "section_ids" | "tier" | "highlights"> | null,
  total: Amount,
  tier: string | null = null,
): QuoteContractInput {
  return {
    quote: { status: q.status, number: q.number, sent_at: q.sent_at, created_at: q.created_at, deposit_amount: q.deposit_amount, deposit_percent: q.deposit_percent, section_ids: q.section_ids, approval: q.approval },
    template,
    // The option's card as the customer sees it: the tier word on it (optionTiers), and its highlights.
    option: option && { name: option.name, warranty: option.warranty, section_ids: option.section_ids, tier: tier ?? option.tier ?? null, highlights: option.highlights },
    // Without options, {Option} and {Warranty} say the package it was priced from, as the server fills them in.
    fill: !option && q.package ? { name: q.package.name, warranty: q.package.warranty ?? "" } : null,
    total,
    client: q.client,
    property: q.property,
  };
}

/** A quote as the office prints it. */
export type PaperQuote = DocumentQuote & TabQuote;

/** The option a quote prints: the one it was signed for once it's signed, else the one looked at. */
export function printedOption(q: Pick<PaperQuote, "status" | "option_id" | "approval">, viewed: string | null): string | null {
  if (isSignedQuote(q.status)) return readApproval(q.approval)?.option?.id ?? q.option_id;
  return viewed ?? q.option_id;
}

/**
 * The estimate as the office prints it (the Paper view, and "Print or save PDF"): the option looked
 * at with its own totals, and the options side by side while the customer is still deciding; once
 * signed, the option it was signed for with its totals. `contract`: filled in for that option.
 */
export function paperDocument(input: {
  quote: PaperQuote;
  lines: ReadonlyArray<DocumentQuoteLine & OptionLine>;
  options: readonly QuoteOptionRow[];
  viewed: string | null;
  date: string;
  contract: QuoteContract | null;
}): DocumentData {
  const { quote: q, lines, options } = input;
  const signed = isSignedQuote(q.status);
  const printed = printedOption(q, input.viewed);
  const totals = tabTotals(q, lines, signed ? null : printed);
  return quoteDocument({ ...q, subtotal: totals.subtotal, discount_amount: totals.discount, tax_amount: totals.tax, total: totals.total }, lines, {
    date: input.date,
    optionId: printed,
    options: options.length && !signed ? documentOptions(sortOptions(options), lines, moneyOf(q)) : undefined,
    contract: input.contract,
  });
}

/**
 * The quote as "Send the range" and "Send the exact price" read it (SendEstimateDialog): with its
 * options, which this page reads apart from the quote, so the range runs from the lowest option to
 * the highest and the words count the options, as the server's will.
 */
export const quoteToSend = <Q extends object>(q: Q, options: readonly QuoteOptionRow[]) => ({ ...q, options });

// ---------------------------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------------------------

export function QuotePage() {
  const { id = "" } = useParams();
  const session = useSession();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [dialog, setDialog] = useState<null | "send" | "exact" | "lost" | "template">(null);
  // The option being looked at (local: the customer sees nothing change), and how: as lines or as paper.
  const [viewing, setViewing] = useState<string | null>(null);
  const [view, setView] = useState<"lines" | "paper">("lines");
  // "Offer options" from the lines' add row: packages to offer side by side.
  const [offering, setOffering] = useState(false);
  const panelId = useId();
  // Every field here saves as it loses focus; the header says when it's saving and saved.
  const save = useSaveStatus();
  const canSell = hasRole(session, "admin", "office", "estimator") && can(session, "sales");

  const quote = useQuery({ queryKey: ["quote", id], queryFn: () => loadQuote(id) });
  const q = quote.data;
  // Waited for with the quote: without them, every option's lines would read as on every option.
  const optionRows = useQuoteOptions(id);
  const options = useMemo(() => optionRows.data ?? [], [optionRows.data]);
  const templates = useTemplates();
  // The look it prints with: the template it was signed on once it's signed, else the one it's set to.
  const { template } = useQuoteTemplate(q ?? NO_QUOTE);
  useDocumentTitle(q ? (q.is_template ? q.title : `Quote #${q.number}`) : "Quote");
  useRememberRecent(session.company.id, q ? { kind: "quote", id: q.id, title: q.title, subtitle: q.is_template ? "Quote template" : `Quote #${q.number} · ${q.client?.display_name ?? ""}`, path: `/quotes/${q.id}` } : null);

  const history = useQuery({
    queryKey: ["quote", id, "history"],
    enabled: canSell,
    meta: { silent: true },
    queryFn: async () => {
      const [activity, messages] = await Promise.all([
        supabase().from("activity").select("id, verb, summary, created_at").eq("subject_type", "quote").eq("subject_id", id).order("created_at", { ascending: false }).limit(20),
        supabase().from("messages").select("id, channel, direction, subject, body, created_at").eq("related_type", "quote").eq("related_id", id).order("created_at", { ascending: false }).limit(20),
      ]);
      return { activity: unwrap(activity), messages: unwrap(messages) };
    },
  });

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ["quote", id] });
    queryClient.invalidateQueries({ queryKey: quoteOptionsKey(id) });
    queryClient.invalidateQueries({ queryKey: ["quotes", session.company.id] });
  };
  const update = useMutation({
    meta: {
      success: (_: unknown, patch: TablesUpdate<"quotes">) => (patch.status === "approved" ? "Marked approved" : patch.status === "lost" ? "Marked lost" : patch.status === "archived" ? "Quote archived" : patch.status === "draft" ? "Moved back to draft" : null),
      tone: "quote",
    },
    mutationFn: async (patch: TablesUpdate<"quotes">) => unwrap(await supabase().from("quotes").update(patch).eq("id", id)),
    onSuccess: refresh,
  });
  // A field saved in place (title, message, discount, tax, deposit, end date, template): the
  // header's save status says how it went, so it has no toast of its own. Offline or restarting,
  // "Couldn't save" is enough; a refusal also says why in a toast, since trying again won't help.
  const edit = useMutation({
    meta: { inline: true },
    mutationFn: async (patch: TablesUpdate<"quotes">) => unwrap(await supabase().from("quotes").update(patch).eq("id", id)),
    onSuccess: refresh,
    onError: (error) => {
      if (!isNetworkError(error) && !isAuthError(error) && !(error instanceof ApiError && isRestarting(error.status))) toast.error(errorMessage(error));
    },
  });
  const saveField = (patch: TablesUpdate<"quotes">) => save.track(edit.mutateAsync(patch));
  // A field left without a change takes back its "Edited".
  const unchanged = () => save.status === "edited" && save.reset();
  const convert = useMutation({
    meta: { success: () => (quote.data?.change_order_for ? "Added to the job" : "Converted to a job"), tone: "job" },
    mutationFn: () => api.post<{ job_id: string }>(`/quotes/${id}/convert`),
    onSuccess: (res) => {
      refresh();
      navigate(`/jobs/${res.job_id}`);
    },
  });
  const copy = useMutation({
    meta: { success: "Quote copied as a new draft", tone: "quote" },
    mutationFn: () => duplicateQuote(id),
    onSuccess: (res) => {
      queryClient.invalidateQueries({ queryKey: ["quotes", session.company.id] });
      navigate(`/quotes/${res.id}`);
    },
  });
  // "Save as template": a copy without the client, named by the office, that new quotes start from.
  const saveTemplate = useMutation({
    meta: { inline: true },
    mutationFn: async (name: string) => unwrap(await supabase().rpc("duplicate_quote", { p_quote: id, p_template_name: name })),
    onSuccess: (templateId) => {
      setDialog(null);
      queryClient.invalidateQueries({ queryKey: ["quotes", session.company.id] });
      toast.success("Saved as a quote template", { description: "New quotes can start from it.", action: { label: "Open it", onClick: () => navigate(`/quotes/${templateId}`) } });
    },
  });
  const remove = useMutation({
    meta: { success: () => (quote.data?.is_template ? "Quote template deleted" : "Quote deleted"), tone: "quote" },
    mutationFn: async () => unwrap(await supabase().from("quotes").delete().eq("id", id)),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["quotes", session.company.id] });
      navigate(quote.data?.is_template ? "/quotes?status=templates" : "/quotes", { replace: true });
    },
  });
  const openClientView = useMutation({
    mutationFn: () => api.get<{ link: string }>(`/quotes/${id}/link`),
    onSuccess: ({ link }) => window.open(link, "_blank", "noopener"),
  });
  // Printing is the paper the Paper view shows, from the quote itself: the exact price, even while
  // the client's link shows a range.
  const printer = useQuotePrint();

  if (quote.isPending || (optionRows.isPending && !optionRows.error)) return <DetailSkeleton />;
  if (quote.error || !q || optionRows.error) {
    return <PageError error={quote.error ?? optionRows.error} onRetry={() => void Promise.all([quote.refetch(), optionRows.refetch()])} back={<BackLink to="/quotes">Quotes</BackLink>} />;
  }
  // A quote template: its contents are edited here as a quote's are, but it's never sent, so
  // nothing about a client, sending or what comes after shows.
  const isTemplate = q.is_template;

  const editable = canSell && EDITABLE.includes(q.status);
  const taxExempt = Boolean(q.client?.tax_exempt) && Number(q.tax_rate) === 0;
  const signed = isSignedQuote(q.status);
  // A roof estimate out as a price range: the client hasn't seen this exact price yet.
  const ranged = inRangeMode(q);
  // And they said yes to it. Sending the range again would ask them all over, so it isn't offered:
  // the visit sets the exact price, or the office sends it instead.
  const rangeAccepted = ranged && Boolean(q.range_accepted_at);
  const approval = readApproval(q.approval);
  // The picker beside the totals. A signed quote keeps the template it was signed on.
  const templateRows = templates.data ?? [];
  const frozen = signedTemplate(q) !== null;
  const templateId = q.template_id && templateRows.some((t) => t.id === q.template_id) ? q.template_id : templateRows.find((t) => t.is_default)?.id ?? templateRows[0]?.id ?? "";
  // Signing for the business is offered on approved quotes, and on jobs whose client signed online.
  const signatures = (
    <ApprovalSignatures quoteId={q.id} approval={approval} approvedAt={q.approved_at} companySigns={template.company_signs} canSign={canSell && (q.status === "approved" || Boolean(approval?.signature))} onSigned={refresh} />
  );
  const changeRequest = history.data?.messages.find((m) => m.direction === "in" && m.subject === "Changes requested");
  const expired = q.valid_until && q.valid_until < todayIn(session.company.timezone) && ["sent", "draft"].includes(q.status);
  // A change order adds to an existing job instead of becoming a new one.
  const changeJob = q.change_job as { id: string; number: number; title: string } | null;
  const convertLabel = changeJob ? `Add to job #${changeJob.number}` : "Convert to job";
  // Planet Ops: a change order joins its job only with the customer's signature on this exact
  // version (core changeOrders.ts; the database refuses anything else), so the office isn't offered
  // "Mark approved" or "Add to job" for one that isn't signed.
  const coBlocker = changeJob && q.status !== "converted" ? changeOrderBlocker(q) : null;

  // With options: the one looked at, its totals and its cost. Without, the quote as it is.
  const offers = offersOptions(options, q.lines);
  // A price agreed on site has its discount in it already, so no promo code goes on top (the server refuses one too).
  const sitePriced = sitePriceSet(q, q.lines);
  const viewed = offers ? viewedOption(options, viewing, q.option_id) : null;
  const viewedRow = options.find((o) => o.id === viewed) ?? null;
  const tab = tabTotals(q, q.lines, viewed);
  const cost = lineSums(visibleLines(q.lines, viewed), { optionId: viewed, shownOptionId: q.option_id, withOptions: true }).cost;
  const priceForMargin = tab.subtotal - tab.discount;
  const cap = depositCap(q, q.lines, options);
  // A percent deposit is of the total of the option looked at, as the client is asked for it.
  const percentDeposit = q.deposit_percent !== null;
  const deposit = Number(depositFor(q.deposit_amount, tab.total, q.deposit_percent));
  // With a payment schedule, the deposit is its payment due at approval: it's changed there.
  const scheduled = Array.isArray(q.payment_schedule) && q.payment_schedule.length > 0;
  // Planet Ops: it becomes a job (or joins its job) only once the customer has signed this exact
  // version with a drawn signature; the server and the database refuse anything else, and there's no
  // office "Mark approved" to stand in for it.
  const customerSigned = q.status === "approved" && isCustomerSignature(q.approval);

  return (
    <>
      {isTemplate ? <BackLink to="/quotes?status=templates">Quote templates</BackLink> : <BackLink to="/quotes">Quotes</BackLink>}
      <div className="page-header">
        <h1 className="page-title">{editable ? <TitleInput value={q.title} onEdit={save.edited} onUnchanged={unchanged} onSave={(title) => saveField({ title })} /> : q.title}</h1>
        {canSell && isTemplate && (
          <div className="page-actions">
            <Button icon="plus" onClick={() => navigate(`/quotes?new=1&template=${q.id}`)}>New quote from it</Button>
            <Menu
              items={[
                {
                  label: "Delete template",
                  icon: "trash",
                  danger: true,
                  onSelect: async () => {
                    if (await confirm({ title: `Delete the template ${q.title}?`, body: "Quotes made from it stay as they are. This can't be undone.", confirmLabel: "Delete template", danger: true })) remove.mutate();
                  },
                },
              ]}
            />
          </div>
        )}
        {canSell && !isTemplate && (
          <div className="page-actions">
            {/* One solid green button: the next step. Sending while it's a draft (or again once they asked for changes), making the job once it's approved. */}
            {EDITABLE.includes(q.status) &&
              (rangeAccepted ? (
                <Button icon="send" variant="secondary" onClick={() => setDialog("exact")} disabled={!q.lines.length}>Send the exact price</Button>
              ) : (
                <Button icon="send" variant={q.status === "draft" || q.status === "changes_requested" ? "primary" : "secondary"} onClick={() => setDialog("send")} disabled={!q.lines.length} title={!q.lines.length ? "Add a line item first" : undefined}>{q.status === "draft" ? "Send quote" : "Resend"}</Button>
              ))}
            {customerSigned && !coBlocker && (
              <Button variant="primary" icon="job" loading={convert.isPending} disabled={!q.lines.length} onClick={() => convert.mutate()}>{convertLabel}</Button>
            )}
            <Menu
              items={[
                { label: "Preview as client", icon: "eye", onSelect: () => openClientView.mutate() },
                { label: "Print or save PDF", icon: "printer", onSelect: () => printer.print() },
                { label: "Copy as new draft", icon: "copy", disabled: copy.isPending, onSelect: () => copy.mutate() },
                { label: "Save as template", icon: "quote", onSelect: () => setDialog("template") },
                { separator: true },
                { label: "Mark as lost", icon: "x", hidden: !EDITABLE.includes(q.status), onSelect: () => setDialog("lost") },
                { label: "Reopen as draft", icon: "undo", hidden: !["lost", "archived"].includes(q.status), onSelect: () => update.mutate({ status: "draft", lost_reason: null }) },
                { label: "Archive", icon: "archive", hidden: ["archived", "converted"].includes(q.status), onSelect: () => update.mutate({ status: "archived" }) },
                {
                  label: "Delete quote",
                  icon: "trash",
                  danger: true,
                  hidden: !["draft", "lost", "archived"].includes(q.status) || q.jobs.length > 0,
                  onSelect: async () => {
                    if (await confirm({ title: `Delete quote #${q.number}?`, body: "Its line items are deleted too. This can't be undone.", confirmLabel: "Delete quote", danger: true })) remove.mutate();
                  },
                },
              ]}
            />
          </div>
        )}
      </div>
      <div className="page-meta">
        {isTemplate ? (
          <span className="muted">Quote template · new quotes start from it, and it's never sent</span>
        ) : (
          <>
            <span className="muted">Quote #{q.number}</span>
            <EntityStatus kind="quote" status={q.status} />
          </>
        )}
        <SaveStatus status={save.status} />
        {q.client && <Link to={`/clients/${q.client.id}`} className="strong">{q.client.display_name}</Link>}
        {q.property && <span className="muted">{addressLine(q.property)}</span>}
      </div>

      {q.status === "approved" && (
        <div className="callout callout-good">
          <Icon name="check" size={20} />
          <div className="grow">
            <div>
              {approval?.method === "in_person" ? "Signed on site" : "Approved"} {q.approved_at ? formatDate(q.approved_at) : ""}
              {approval?.name ? ` by ${approval.name}` : ""}
              {approval?.option ? `, for ${choiceLabel(approval.option)}` : ""}
            </div>
            {signatures}
          </div>
          {/* The header's button is the solid one. */}
          {canSell && customerSigned && <Button size="sm" loading={convert.isPending} onClick={() => convert.mutate()}>{convertLabel}</Button>}
        </div>
      )}
      {changeJob && (
        <div className="callout callout-info">
          <Icon name="job" size={20} />
          <div className="grow">
            <div>Change order for <Link to={`/jobs/${changeJob.id}`} className="strong">job #{changeJob.number}</Link>: {changeJob.title}</div>
            <div className="small" style={{ fontWeight: 400 }}>{q.status === "converted" ? "The customer signed it, and it's been added to the job." : "Once the customer signs this exact version, its items are added to the job and the contract total changes. A staff approval or a note can't stand in for the signature, for credits and $0 changes too."}</div>
            {coBlocker && q.status !== "draft" && <div className="small" style={{ fontWeight: 600, marginTop: 4 }}>Awaiting the customer's signature.</div>}
          </div>
        </div>
      )}
      {!changeJob && q.status === "converted" && q.jobs.length > 0 && (
        <div className="callout callout-info">
          <Icon name="job" size={20} />
          <div className="grow">
            <div>Converted to <Link to={`/jobs/${q.jobs[0].id}`} className="strong">job #{q.jobs[0].number}</Link>.</div>
            {approval && signatures}
          </div>
        </div>
      )}
      {q.status === "changes_requested" && (
        <div className="callout callout-warning">
          <Icon name="messages" size={20} />
          <div className="grow">
            <div>{q.client?.display_name ?? "The client"} asked for changes</div>
            {changeRequest && <div className="pre-wrap small" style={{ fontWeight: 400, marginTop: 4 }}>“{changeRequest.body}”</div>}
            <div className="small" style={{ fontWeight: 400, marginTop: 4 }}>Update the quote, then resend it.</div>
          </div>
        </div>
      )}
      {q.status === "draft" && <DraftedCallout quoteId={q.id} message={q.message} drafted={q.drafted} lines={q.lines} requestId={q.request_id} admin={hasRole(session, "admin")} canEdit={editable} onChanged={refresh} />}
      {q.status === "lost" && <div className="callout callout-danger"><Icon name="x" size={20} /><div className="grow">Marked lost{q.lost_reason ? `: ${q.lost_reason}` : ""}.</div></div>}
      {q.status === "sent" && q.sent_at && (
        <div className="callout">
          <Icon name="clock" size={20} />
          <div className="grow">
            {rangeAccepted
              ? `${q.client?.display_name ?? "The client"} said yes to the range, ${formatMoney(q.range_low)} to ${formatMoney(q.range_high)}, on ${dayText(q.range_accepted_at!, session.company.timezone)}. Book the site visit: the exact price is set there.`
              : ranged
              ? `Sent ${timeAgo(q.sent_at)} as a price range, ${formatMoney(q.range_low)} to ${formatMoney(q.range_high)}. ${q.client?.display_name ?? "The client"} sees the range, not this exact price, until it's priced on site.`
              : `Sent ${timeAgo(q.sent_at)}. Waiting for ${q.client?.display_name ?? "the client"} to respond.`}
            {expired ? " This quote has expired; update the date before resending." : ""}
          </div>
        </div>
      )}

      <div className="two-col">
        <div className="wide stack-lg">
          {/* Without options there's no bar: they're offered from the lines' add row instead. */}
          <QuoteOptions quote={q} options={options} lines={q.lines} viewing={viewing} onView={setViewing} mode="office" onChanged={refresh} panelId={panelId} invite={false} />
          <div className="stack-sm">
            <div className="segmented" role="group" aria-label="Show the estimate as" style={{ justifySelf: "start" }}>
              <button type="button" aria-pressed={view === "lines"} aria-controls={panelId} onClick={() => setView("lines")}>Lines</button>
              <button type="button" aria-pressed={view === "paper"} aria-controls={panelId} onClick={() => setView("paper")}>Paper</button>
            </div>
            <div id={panelId} role={offers ? "tabpanel" : undefined} aria-label={viewedRow ? viewedRow.name : undefined}>
              {view === "lines" && (
                <LineItems
                  table="quote_line_items"
                  parent="quote_id"
                  parentId={q.id}
                  lines={q.lines}
                  editable={editable}
                  onChanged={refresh}
                  withOptions
                  optionId={viewed}
                  shownOptionId={q.option_id}
                  options={options}
                  followMarkup={q.package?.price_mode === "follow" ? Number(q.package.markup_pct) : null}
                  saveStatus={save}
                  propertyId={q.property?.id}
                  onOfferOptions={!offers && optionsOpen(q.status) ? () => setOffering(true) : undefined}
                />
              )}
              {(view === "paper" || printer.request > 0) && <QuotePaper quote={q} options={options} viewed={viewed} sheet={view === "paper"} print={printer.request} />}
            </div>
          </div>
          <MessageCard value={q.message} editable={editable} onEdit={save.edited} onUnchanged={unchanged} onSave={(message) => saveField({ message })} />
          {canSell && !isTemplate && <PlansCard scope={{ kind: "quote", id: q.id, propertyId: q.property?.id ?? null }} />}
        </div>
        <aside className="narrow stack">
          <div className="card card-pad totals">
            {viewedRow && <p className={styles.totalsFor}>{totalsCaption(viewedRow.name, { shown: viewed === q.option_id, signed })}</p>}
            {/* The figures roll to their new values as lines change, rather than snapping. */}
            <div className="line"><span>Subtotal</span><AnimatedNumber value={tab.subtotal} format={MONEY_CENTS} /></div>
            <DiscountRows
              kind="quote"
              id={q.id}
              promo={q.promo}
              discount={q.promo ? tab.discount : Number(q.discount_amount)}
              subtotal={tab.subtotal}
              canEditDiscount={editable}
              canChangePromo={editable && !sitePriced && !isTemplate}
              suggestedCode={sitePriced ? null : q.request?.promo_code}
              suggestedFrom={q.request?.website_form_id ? "website" : "booking"}
              rejected={!sitePriced && q.request?.rejected_promo_code ? { code: q.request.rejected_promo_code, problem: q.request.promo_problem } : null}
              onSaveDiscount={(v) => saveField({ discount_amount: v })}
              onEditDiscount={save.edited}
              onUnchangedDiscount={unchanged}
              onChanged={refresh}
            />
            {offers && (editable || Number(q.discount_amount) > 0) && (
              <p className={styles.note}>{q.promo ? "The promo code is worked out on whichever option they choose." : "The discount comes off whichever option they choose."}</p>
            )}
            {/* A tax-exempt client's quote is kept at 0% by the database, so there's no rate to type. */}
            <div className="line">
              <span>{taxExempt ? `Tax exempt${q.client?.tax_exempt_note ? ` · ${q.client.tax_exempt_note}` : ""}` : `Tax ${editable ? "" : `(${formatTaxRate(q.tax_rate)})`}`}</span>
              {editable && !taxExempt ? <MoneyInput percent label="Tax rate" value={taxPercent(q.tax_rate)} max={99.99} onSave={(v) => saveField({ tax_rate: taxRateFromPercent(v) })} onEdit={save.edited} onUnchanged={unchanged} /> : <AnimatedNumber value={tab.tax} format={MONEY_CENTS} />}
            </div>
            {editable && !taxExempt && <div className="line"><span>Tax amount</span><AnimatedNumber value={tab.tax} format={MONEY_CENTS} /></div>}
            <div className="line grand"><span>{q.recurrence_rule ? "Total per visit" : "Total"}</span><AnimatedNumber value={tab.total} format={MONEY_CENTS} /></div>
            {!q.change_order_for && (
              <div className={cx("line", styles.howOftenRow)}>
                <span>How often</span>
                <HowOften quote={q} editable={editable} onSaved={refresh} />
              </div>
            )}
            <div className="line">
              <span>Deposit required</span>
              {scheduled ? (
                <span title="The payment due when they approve, in the payment schedule">{formatMoneyCents(deposit)}</span>
              ) : editable ? (
                <span className={styles.deposit}>
                  {/* A percent follows the total as lines change, and the option and add-ons the client picks. */}
                  <span className="segmented" role="group" aria-label="Deposit as">
                    <button type="button" aria-pressed={!percentDeposit} title="An amount" onClick={() => percentDeposit && void saveField({ deposit_percent: null })}>$</button>
                    <button type="button" aria-pressed={percentDeposit} title="A percent of the total" onClick={() => !percentDeposit && void saveField({ deposit_percent: depositAsPercent(q.deposit_amount, q.total) })}>%</button>
                  </span>
                  {percentDeposit ? (
                    <MoneyInput percent label="Deposit percent" width={96} value={Number(q.deposit_percent)} max={100} onSave={(v) => saveField({ deposit_percent: v })} onEdit={save.edited} onUnchanged={unchanged} />
                  ) : (
                    <MoneyInput label="Deposit" width={96} value={Number(q.deposit_amount)} max={cap.amount} onSave={(v) => saveField({ deposit_amount: v })} onEdit={save.edited} onUnchanged={unchanged} />
                  )}
                </span>
              ) : (
                <span>{formatMoneyCents(deposit)}{percentDeposit ? ` (${Number(q.deposit_percent)}%)` : ""}</span>
              )}
            </div>
            {percentDeposit && editable && !scheduled && <div className="line"><span>Deposit amount</span><AnimatedNumber value={deposit} format={MONEY_CENTS} /></div>}
            {!percentDeposit && !scheduled && cap.name && editable && Number(q.deposit_amount) > cap.amount && (
              <p className={styles.warn}>That's more than {cap.name} comes to ({formatMoneyCents(cap.amount)}). Lower it so it fits whichever option they choose.</p>
            )}
            {/* A quote made from a template is valid for the usual days from then. */}
            {!isTemplate && (
              <div className="line">
                <span>Valid until</span>
                <ValidUntil value={q.valid_until} editable={editable} onEdit={save.edited} onUnchanged={unchanged} onSave={(validUntil) => saveField({ valid_until: validUntil })} />
              </div>
            )}
          </div>
          {/* On a template too: the quotes made from it carry it. */}
          {canSell && <PaymentScheduleCard quote={q} editable={editable} onSaved={refresh} />}
          {/* Filled in after it's signed too: a permit number often comes later. */}
          <CustomFieldsCard record="quote" values={q.custom_fields} editable={canSell} onSave={async (values) => { unwrap(await supabase().from("quotes").update({ custom_fields: values }).eq("id", q.id)); refresh(); }} />
          {/* The paper's look is picked on each quote, so a quote template doesn't have one. */}
          {canSell && !isTemplate && templateRows.length > 1 && (
            <div className="card card-pad stack-sm">
              <label htmlFor="quote-template"><strong>Document style</strong></label>
              <select
                id="quote-template"
                className="select"
                value={templateId}
                disabled={!editable}
                onChange={(e) => {
                  const chosen = templateRows.find((t) => t.id === e.target.value);
                  // The default one isn't pinned: the quote follows whichever template is the default.
                  if (chosen) void saveField({ template_id: chosen.is_default ? null : chosen.id });
                }}
              >
                {templateRows.map((t) => <option key={t.id} value={t.id}>{t.name}{t.is_default ? " (default)" : ""}</option>)}
              </select>
              <span className="muted small">{frozen ? "It keeps the look it was signed with." : "How it looks printed, as a PDF and on the client's link."}</span>
            </div>
          )}
          {canSell && <QuoteSections quote={q} optionSectionIds={viewedRow?.section_ids ?? null} approval={q.approval} />}
          {canSell && cost > 0 && (
            <div className="card card-pad stack-sm">
              <strong>Profit estimate</strong>
              <div className="totals">
                <div className="line"><span>Price before tax</span><AnimatedNumber value={priceForMargin} format={MONEY_CENTS} /></div>
                <div className="line"><span>Estimated cost</span><AnimatedNumber value={cost} format={MONEY_CENTS} /></div>
                <div className="line grand">
                  <span>Profit</span>
                  <span style={{ color: priceForMargin - cost < 0 ? "var(--danger)" : "var(--green-dark)" }}>
                    <AnimatedNumber value={priceForMargin - cost} format={MONEY_CENTS} /> {priceForMargin > 0 && `(${Math.round(((priceForMargin - cost) / priceForMargin) * 100)}%)`}
                  </span>
                </div>
              </div>
            </div>
          )}
          {/* The paving calculator's working behind its lines: costs and profit, the office's only. */}
          {canSell && !isTemplate && <WorksheetsCard quoteId={q.id} editable={editable} />}
          {canSell && !isTemplate && <MeasurementsCard quoteId={q.id} propertyId={q.property?.id ?? null} lat={q.property?.lat ?? null} lng={q.property?.lng ?? null} editable={editable} onApplied={refresh} />}
          {canSell && !isTemplate && !!history.data?.activity.length && (
            <div className="card">
              <div className="card-head"><strong>History</strong></div>
              <div className="timeline">
                {history.data.activity.map((a) => (
                  <div key={a.id} className="timeline-item" style={{ padding: "10px 20px" }}>
                    <span className="t-icon" style={{ width: 28, height: 28 }}><Icon name={a.verb.endsWith("approved") || a.verb.endsWith("accepted") ? "check" : a.verb.endsWith("sent") ? "send" : "history"} size={14} /></span>
                    <div><div className="text-sm">{a.summary}</div><div className="t-meta">{timeAgo(a.created_at)}</div></div>
                  </div>
                ))}
                <div className="timeline-item" style={{ padding: "10px 20px" }}>
                  <span className="t-icon" style={{ width: 28, height: 28 }}><Icon name="plus" size={14} /></span>
                  <div><div className="text-sm">Quote created</div><div className="t-meta">{timeAgo(q.created_at)}</div></div>
                </div>
              </div>
            </div>
          )}
        </aside>
      </div>

      {dialog === "send" &&
        (ranged ? (
          // Out as a range: resending sends the range again, never an email with the exact total.
          <SendEstimateDialog quote={quoteToSend(q, options)} mode="range" onClose={() => setDialog(null)} onSent={refresh} />
        ) : (
          <SendDialog kind="quote" id={q.id} number={q.number} email={q.client?.email ?? null} phone={q.client?.phone ?? null} textsOffSince={q.client?.sms_opt_out_at} onClose={() => setDialog(null)} onSent={refresh} />
        ))}
      {/* They said yes to the range: the exact price goes out instead, the way the roofing project offers it. */}
      {dialog === "exact" && <SendEstimateDialog quote={quoteToSend(q, options)} mode="exact" onClose={() => setDialog(null)} onSent={refresh} />}
      {dialog === "template" && <SaveTemplateDialog title={q.title} pending={saveTemplate.isPending} error={saveTemplate.error} onClose={() => setDialog(null)} onSave={(name) => saveTemplate.mutate(name)} />}
      {dialog === "lost" && <LostDialog onClose={() => setDialog(null)} onSave={(reason) => update.mutateAsync({ status: "lost", lost_reason: reason }).then(() => setDialog(null))} />}
      {offering && (
        <AddOptionsDialog
          quote={q}
          options={options}
          lines={q.lines}
          startOver={false}
          mode="office"
          onClose={() => setOffering(false)}
          onDone={() => {
            setOffering(false);
            setViewing(null);
            refresh();
          }}
        />
      )}
    </>
  );
}


/**
 * `value`, as the same object for as long as what's in it stays the same: a template (and a signed
 * contract) is read afresh on every render, and the paper is built again only when it changes.
 */
function useSameContent<T>(value: T): T {
  const key = JSON.stringify(value);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  return useMemo(() => value, [key]);
}

/**
 * The estimate on paper (paperDocument): letter pages on its template, with the option looked at,
 * its totals and its contract filled in; once signed, the option and the contract it was signed with.
 * `sheet` shows the pages here (the Paper view). `print` is the print button's latest request: each
 * new one prints these same pages once they're ready, and the printable copy stays on the page after,
 * following the quote, so the browser's own Print prints it too.
 */
function QuotePaper({ quote: q, options, viewed, sheet, print }: { quote: QuoteRow; options: readonly QuoteOptionRow[]; viewed: string | null; sheet: boolean; print: number }) {
  const session = useSession();
  const tz = session.company.timezone;
  const look = useQuoteTemplate(q);
  const template = useSameContent(look.template);
  const isPending = look.isPending;
  const letterhead = useLetterhead();
  const company = letterhead.data ?? documentCompany(session.company);
  const fields = useCustomFields("quote");

  const printed = printedOption(q, viewed);
  const option = options.find((o) => o.id === printed) ?? null;
  const total = isSignedQuote(q.status) ? Number(q.total) : tabTotals(q, q.lines, printed).total;
  const tier = option ? (optionTiers(options, q.lines, moneyOf(q)).get(option.id) ?? null) : null;
  const input = useMemo(() => (isPending ? null : contractFor(q, template, option, total, tier)), [isPending, q, template, option, total, tier]);
  const terms = useQuoteContract(input);
  const contract = useSameContent(terms.contract ?? (terms.error ? NO_CONTRACT : null));
  const ready = !isPending && contract !== null;
  const data = useMemo(
    () =>
      ready
        ? paperDocument({
            quote: { ...q, pdf_fields: shownCustomFields(fields, q.custom_fields, "pdf") },
            lines: q.lines,
            options,
            viewed,
            // The day it was sent, else the day it was made, as its {Date} says it.
            date: quoteDate(q, tz),
            contract,
          })
        : null,
    [ready, q, options, viewed, tz, contract, fields],
  );
  const paperTemplate = useMemo(() => contractTemplate(template, contract), [template, contract]);
  // While another option's contract loads, the pages stay as they were rather than blinking out.
  const onScreen = useRef<{ template: TemplateSettings; data: DocumentData } | null>(null);
  if (data) onScreen.current = { template: paperTemplate, data };

  // Printed only with its contract: printing without it would leave the terms off the copy they sign.
  const printable = ready && terms.contract !== null;
  const [printing, setPrinting] = useState(0);
  const last = useRef<{ template: TemplateSettings; data: DocumentData } | null>(null);
  if (printable && data) last.current = { template: paperTemplate, data };
  useEffect(() => {
    if (printable && print > printing) setPrinting(print);
  }, [printable, print, printing]);
  useEffect(() => {
    if (print > printing && terms.error) toast.error("The contract didn't load, so it can't print yet", { action: { label: "Try again", onClick: terms.refetch } });
    // Once for each print asked for while it can't load.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [print, Boolean(terms.error)]);

  return (
    <>
      {sheet && (
        <section className="stack" aria-label="The estimate as it prints">
          {terms.error && (
            <p className="muted small" style={{ margin: 0 }}>
              The contract didn't load, so it's not on the pages below.{" "}
              <button type="button" className="btn btn-sm btn-ghost" onClick={terms.refetch}>Try again</button>
            </p>
          )}
          {onScreen.current ? (
            <DocumentSheet template={onScreen.current.template} company={company} data={onScreen.current.data} />
          ) : (
            <Skeleton height="auto" radius={4} style={{ aspectRatio: "8.5 / 11" }} />
          )}
        </section>
      )}
      {printing > 0 && last.current && <QuotePrint request={printing} template={last.current.template} company={company} data={last.current.data} />}
    </>
  );
}

/**
 * Who signed an approved quote: the customer, and the business. When the template has a line for
 * the business and nobody has signed it yet, a salesperson signs for it here: their saved signature
 * in one tap, or drawn in a small dialog (and saved for next time).
 */
function ApprovalSignatures({ quoteId, approval, approvedAt, companySigns, canSign, onSigned }: {
  quoteId: string;
  approval: QuoteApproval | null;
  approvedAt: string | null;
  companySigns: boolean;
  canSign: boolean;
  onSigned: () => void;
}) {
  const { company, userId } = useSession();
  const queryClient = useQueryClient();
  const [drawing, setDrawing] = useState(false);
  const needsCompany = companySigns && canSign && !approval?.company;
  const mine = useMySignature({ enabled: needsCompany });
  const countersign = useMutation({
    meta: { inline: drawing, success: `Signed for ${company.name}`, tone: "quote" },
    mutationFn: (body: { signature?: string; save_signature?: boolean }) => api.post<{ ok: true }>(`/quotes/${quoteId}/countersign`, body),
    onSuccess: (_, body) => {
      if (body.save_signature && body.signature) queryClient.setQueryData(mySignatureKey(company.id, userId), body.signature);
      setDrawing(false);
      onSigned();
    },
  });
  const customer = approval && approval.method !== "manual" && approval.signature ? approval : null;
  if (!customer && !approval?.company && !needsCompany) return null;
  return (
    <div className="row wrap" style={{ gap: 16, marginTop: 10, alignItems: "flex-start" }}>
      {customer && <SignatureTile image={customer.signature!} name={customer.name || "The client"} caption={`Signed ${formatDate(customer.signed_at ?? approvedAt)}`} />}
      {approval?.company ? (
        <SignatureTile image={approval.company.signature} name={approval.company.name || company.name} caption={`For ${company.name}`} />
      ) : (
        needsCompany && (
          <div className="stack-sm" style={{ gap: 6, alignSelf: "center" }}>
            <Button size="sm" icon="signature" loading={countersign.isPending || mine.isPending} onClick={() => (mine.data ? countersign.mutate({}) : setDrawing(true))}>
              Sign for {company.name}
            </Button>
            <span className="small" style={{ fontWeight: 400 }}>{mine.data ? "With your saved signature." : "The business's line is still blank."}</span>
          </div>
        )
      )}
      {drawing && (
        <CountersignDialog companyName={company.name} pending={countersign.isPending} error={countersign.error} onClose={() => setDrawing(false)} onSign={(body) => countersign.mutate(body)} />
      )}
    </div>
  );
}

function SignatureTile({ image, name, caption }: { image: string; name: string; caption: string }) {
  return (
    <div className="stack-sm" style={{ gap: 2 }}>
      <img src={image} alt={`Signature of ${name}`} style={{ height: 56, width: 180, objectFit: "contain", background: "#fff", borderRadius: 8, padding: 4, border: "1px solid var(--border)" }} />
      <span className="small" style={{ fontWeight: 600 }}>{name}</span>
      <span className="small" style={{ fontWeight: 400 }}>{caption}</span>
    </div>
  );
}

function CountersignDialog({ companyName, pending, error, onClose, onSign }: { companyName: string; pending: boolean; error: unknown; onClose: () => void; onSign: (body: { signature: string; save_signature: boolean }) => void }) {
  const [signature, setSignature] = useState<string | null>(null);
  const [keep, setKeep] = useState(true);
  return (
    <Dialog open onClose={onClose} title={`Sign for ${companyName}`} description="Your signature goes on the business's line of this estimate." size="sm">
      <form
        className="stack"
        onSubmit={(e: FormEvent) => {
          e.preventDefault();
          if (signature) onSign({ signature, save_signature: keep });
        }}
      >
        <SignaturePad value={signature} onChange={setSignature} label="Sign with your finger or mouse" />
        <label className="checkbox">
          <input type="checkbox" checked={keep} onChange={(e) => setKeep(e.target.checked)} />
          Save my signature for next time
        </label>
        <FormError error={error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" icon="signature" loading={pending} disabled={!signature}>Sign for {companyName}</Button>
        </div>
      </form>
    </Dialog>
  );
}

/** "Save as template": the office names it; its lines, options, sections and message go with it, not the client. */
function SaveTemplateDialog({ title, pending, error, onClose, onSave }: { title: string; pending: boolean; error: unknown; onClose: () => void; onSave: (name: string) => void }) {
  const [name, setName] = useState(title);
  return (
    <Dialog open onClose={onClose} title="Save as quote template" description="New quotes can start from it, with its lines, options, contract sections and message. The client and dates stay on this quote." size="sm">
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault();
          if (name.trim()) onSave(name.trim());
        }}
      >
        <Field label="Template name" requiredMessage="Give it a name, like Spring cleanup.">
          <input className="input" value={name} onChange={(e) => setName(e.target.value.trimStart())} required maxLength={200} autoFocus />
        </Field>
        <FormError error={error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" loading={pending}>Save template</Button>
        </div>
      </form>
    </Dialog>
  );
}

function LostDialog({ onClose, onSave }: { onClose: () => void; onSave: (reason: string) => Promise<unknown> }) {
  const [reason, setReason] = useState(LOST_REASONS[0]);
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  return (
    <Dialog open onClose={onClose} title="Mark quote as lost" size="sm">
      <form
        onSubmit={async (e: FormEvent) => {
          e.preventDefault();
          setSaving(true);
          await onSave([reason, note.trim()].filter(Boolean).join(": ")).finally(() => setSaving(false));
        }}
      >
        <Field label="Reason">
          <select className="select" value={reason} onChange={(e) => setReason(e.target.value)}>
            {LOST_REASONS.map((r) => <option key={r}>{r}</option>)}
          </select>
        </Field>
        <Field label="Note" optional><input className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} /></Field>
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="danger-solid" loading={saving}>Mark lost</Button>
        </div>
      </form>
    </Dialog>
  );
}

/** The quote's title, typed over in the header; saved as it loses focus, and a blank one goes back. */
function TitleInput({ value, onEdit, onUnchanged, onSave }: { value: string; onEdit: () => void; onUnchanged: () => void; onSave: (v: string) => void }) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  return (
    <input
      className="title-input"
      aria-label="Quote title"
      value={draft}
      maxLength={200}
      onChange={(e) => {
        setDraft(e.target.value);
        onEdit();
      }}
      onBlur={() => {
        const title = draft.trim();
        if (title && title !== value) return onSave(title);
        if (!title) setDraft(value);
        onUnchanged();
      }}
      onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
    />
  );
}

/**
 * "Valid until" in the totals: the day the quote is good until, or "No end date". The date field
 * shows only while a date is being picked (it opens on the picker), so an empty one never reads as
 * the browser's "mm/dd/yyyy". Saved as it loses focus; Escape puts it back.
 */
function ValidUntil({ value, editable, onEdit, onUnchanged, onSave }: { value: string | null; editable: boolean; onEdit: () => void; onUnchanged: () => void; onSave: (v: string | null) => void }) {
  const [picking, setPicking] = useState(false);
  const [draft, setDraft] = useState(value ?? "");
  const input = useRef<HTMLInputElement>(null);
  const shown = useRef<HTMLSpanElement>(null);
  const cancelled = useRef(false);
  // Done from the keyboard (Enter, Escape), the focus goes back to the date rather than the page.
  const refocus = useRef(false);
  useEffect(() => setDraft(value ?? ""), [value]);
  useEffect(() => {
    if (!picking && refocus.current) {
      refocus.current = false;
      shown.current?.querySelector("button")?.focus();
    }
    if (!picking || !input.current) return;
    cancelled.current = false;
    input.current.focus();
    try {
      input.current.showPicker();
    } catch {
      // Some browsers open it only on a click in the field itself; it has focus either way.
    }
  }, [picking]);

  if (!editable) return value ? <span>{formatDate(value)}</span> : <span className="muted">No end date</span>;
  if (picking) {
    return (
      <input
        ref={input}
        className="input input-sm"
        style={{ width: 150 }}
        type="date"
        aria-label="Valid until"
        value={draft}
        onChange={(e) => {
          setDraft(e.target.value);
          onEdit();
        }}
        onBlur={(e) => {
          setPicking(false);
          // A date typed only partway reads as empty: it goes back rather than clearing the date.
          if (cancelled.current || e.currentTarget.validity.badInput) setDraft(value ?? "");
          else if ((draft || null) !== value) return onSave(draft || null);
          onUnchanged();
        }}
        onKeyDown={(e) => {
          if (e.key !== "Enter" && e.key !== "Escape") return;
          e.preventDefault();
          refocus.current = true;
          if (e.key === "Escape") cancelled.current = true;
          e.currentTarget.blur();
        }}
      />
    );
  }
  // The date as picked, while it saves.
  return draft ? (
    <span ref={shown} className={styles.validUntil}>
      <Button size="sm" variant="ghost" className={styles.validUntilDate} aria-label={`Valid until ${formatDate(draft)}. Change the date`} onClick={() => setPicking(true)}>{formatDate(draft)}</Button>
      <Button
        size="sm"
        variant="ghost"
        icon="x"
        aria-label="Remove the end date"
        title="No end date"
        onClick={() => {
          setDraft("");
          onSave(null);
        }}
      />
    </span>
  ) : (
    <span ref={shown} className={styles.validUntil}>
      <span className="muted">No end date</span>
      <Button size="sm" variant="ghost" icon="calendar" onClick={() => setPicking(true)}>Set date</Button>
    </span>
  );
}

type QuoteSchedule = Pick<QuoteRow, "id" | "recurrence_rule" | "active_months" | "starts_on" | "ends_on">;

/**
 * "How often" in the totals, for recurring work like mowing: one time, or how it repeats. The
 * client's quote says it beside a total per visit, and converting it makes a recurring job.
 */
function HowOften({ quote, editable, onSaved }: { quote: QuoteSchedule; editable: boolean; onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const text = quote.recurrence_rule ? scheduleText(quote.recurrence_rule, quote.active_months) : null;
  if (!editable) return text ? <span className={styles.howOften}>{text}</span> : <span className="muted">One time</span>;
  return (
    <span className={styles.validUntil}>
      {text ? (
        <Button size="sm" variant="ghost" className={cx(styles.validUntilDate, styles.howOften)} aria-label={`${text}. Change how often`} onClick={() => setOpen(true)}>{text}</Button>
      ) : (
        <>
          <span className="muted">One time</span>
          <Button size="sm" variant="ghost" icon="refresh" onClick={() => setOpen(true)}>Repeat</Button>
        </>
      )}
      {open && <HowOftenDialog quote={quote} onClose={() => setOpen(false)} onSaved={onSaved} />}
    </span>
  );
}

function HowOftenDialog({ quote, onClose, onSaved }: { quote: QuoteSchedule; onClose: () => void; onSaved: () => void }) {
  const session = useSession();
  const [repeats, setRepeats] = useState(true);
  const [recurrence, setRecurrence] = useState<Recurrence>({
    rule: quote.recurrence_rule ?? "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO",
    months: quote.active_months,
    starts_on: quote.starts_on ?? todayIn(session.company.timezone),
    ends_on: quote.ends_on,
  });
  const save = useMutation({
    meta: { inline: true },
    mutationFn: async () => {
      if (repeats) parseRule(recurrence.rule); // says what's wrong before anything is saved
      const patch = repeats
        ? { recurrence_rule: recurrence.rule, active_months: recurrence.months, starts_on: recurrence.starts_on, ends_on: recurrence.ends_on }
        : { recurrence_rule: null, active_months: null, starts_on: null, ends_on: null };
      unwrap(await supabase().from("quotes").update(patch).eq("id", quote.id));
    },
    onSuccess: () => {
      onSaved();
      onClose();
    },
  });
  return (
    <Dialog open onClose={onClose} title="How often" description="For work that repeats, like mowing. Their quote says how often and prices it per visit. As a job, its visits are scheduled." size="lg">
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); save.mutate(); }}>
        <div className="segmented" role="group" aria-label="How often">
          <button type="button" aria-pressed={!repeats} onClick={() => setRepeats(false)}>One time</button>
          <button type="button" aria-pressed={repeats} onClick={() => setRepeats(true)}>Repeats</button>
        </div>
        {repeats && <RecurrenceEditor value={recurrence} onChange={setRecurrence} />}
        <FormError error={save.error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" loading={save.isPending}>Save</Button>
        </div>
      </form>
    </Dialog>
  );
}

function MessageCard({ value, editable, onEdit, onUnchanged, onSave }: { value: string | null; editable: boolean; onEdit: () => void; onUnchanged: () => void; onSave: (v: string) => void }) {
  const { config } = useSession();
  const [draft, setDraft] = useState(value ?? "");
  useEffect(() => setDraft(value ?? ""), [value]);
  const polish = useMutation({
    mutationFn: () => api.post<{ text: string }>("/ai/rewrite", { text: draft }),
    onSuccess: (res) => {
      setDraft(res.text);
      onSave(res.text);
      toast.success("Message polished", { description: "Review it before sending." });
    },
  });
  if (!editable) {
    return value ? <div className="card card-pad"><strong>Message to client</strong><p className="pre-wrap" style={{ margin: "8px 0 0" }}>{value}</p></div> : null;
  }
  return (
    <div className="card card-pad stack-sm">
      <label htmlFor="quote-message"><strong>Message to client</strong> <span className="muted small">(shown above the line items)</span></label>
      <textarea
        id="quote-message"
        className="textarea"
        value={draft}
        maxLength={4000}
        onChange={(e) => {
          setDraft(e.target.value);
          onEdit();
        }}
        onBlur={() => (draft !== (value ?? "") ? onSave(draft) : onUnchanged())}
        placeholder="Thanks for having us out. Here's what we recommend…"
      />
      {config.features.ai && (
        <div className="row">
          <Button size="sm" icon="sparkle" loading={polish.isPending} disabled={draft.trim().length < 3} onClick={() => polish.mutate()}>Polish with AI</Button>
          <UsingChatGptPlan />
        </div>
      )}
    </div>
  );
}

/**
 * The quote's drawings, and Fill quantities: each line's formula worked out from a drawing. Lines
 * whose formula reads a depth are shown first, each with its own to confirm (its price list item's
 * default, else the drawing's), so 6 inches of stone isn't priced at the asphalt's 2.
 */
function MeasurementsCard({ quoteId, propertyId, lat, lng, editable, onApplied }: { quoteId: string; propertyId: string | null; lat: number | null; lng: number | null; editable: boolean; onApplied: () => void }) {
  const [asking, setAsking] = useState<{ measurementId: string; lines: DepthLine[] } | null>(null);
  const apply = useMutation({
    meta: { inline: true, success: (r: { lines: unknown[] }) => (r.lines.length ? "Quantities filled from the drawing" : null), tone: "quote" },
    mutationFn: ({ measurementId, depths }: { measurementId: string; depths?: Record<string, number> }) =>
      api.post<{ lines: Array<{ name: string; field?: string; value?: number; depth_in?: number | null; error?: string }> }>(`/quotes/${quoteId}/apply-measurement`, {
        measurement_id: measurementId,
        item_depths: true,
        ...(depths ? { depths } : {}),
      }),
    onSuccess: () => {
      setAsking(null);
      onApplied();
    },
  });
  // With no line that reads a depth, the drawing fills the quote straight away.
  const start = useMutation({
    mutationFn: async (measurementId: string) => {
      const db = supabase();
      const [lines, drawing] = await Promise.all([
        db.from("quote_line_items").select("id, name, formula, service:services(default_depth_in)").eq("quote_id", quoteId).order("sort"),
        db.from("measurements").select("sections").eq("id", measurementId).maybeSingle(),
      ]);
      const deep = depthLines(unwrap(lines), null, usesDepth);
      if (!deep.length) return void (await apply.mutateAsync({ measurementId }).catch(() => undefined));
      const sections = unwrap(drawing)?.sections;
      const drawn = (Array.isArray(sections) ? (sections as Array<{ depth_in?: number | null }>) : []).find((s) => s?.depth_in)?.depth_in;
      setAsking({ measurementId, lines: depthLines(unwrap(lines), drawn, usesDepth) });
    },
  });

  const measureUrl = `/measure?quote=${quoteId}${propertyId ? `&property=${propertyId}` : ""}${lat != null ? `&lat=${lat}&lng=${lng}` : ""}`;
  return (
    <DrawingsCard
      kind="quote"
      parentId={quoteId}
      candidates={propertyId ? `property_id.eq.${propertyId}` : null}
      measureUrl={measureUrl}
      editable
      rowExtra={(m) =>
        editable && (
          <Button size="sm" style={{ justifySelf: "start" }} loading={(start.isPending && start.variables === m.id) || (!asking && apply.isPending && apply.variables?.measurementId === m.id)} onClick={() => start.mutate(m.id)}>Fill quantities</Button>
        )
      }
    >
      {!asking && <FormError error={apply.error} />}
      {apply.data && (
        <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12 }}>
          {apply.data.lines.map((l, i) => <li key={`${i}-${l.name}`}>{l.name}: {l.error ? <span className="error-text">{l.error}</span> : `${l.field === "unit_price" ? "price" : "qty"} ${l.value}${l.depth_in != null ? ` at ${l.depth_in} in deep` : ""}`}</li>)}
          {apply.data.lines.length === 0 && <li className="muted">No lines on this quote use a formula.</li>}
        </ul>
      )}
      {asking && (
        <Dialog open onClose={() => setAsking(null)} title="Depth for each line">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              const depths = lineDepths(asking.lines);
              if (depths) apply.mutate({ measurementId: asking.measurementId, depths });
            }}
          >
            <p className="muted" style={{ margin: 0 }}>These lines work out their amount from a depth. Each starts with its price list item's own depth, or the drawing's. Check them, then fill the quantities.</p>
            {asking.lines.map((line, i) => (
              <Field key={line.id} label={`${line.name} (inches deep)`}>
                <input
                  className="input"
                  inputMode="decimal"
                  value={line.depth}
                  autoFocus={i === 0}
                  required
                  onChange={(e) => setAsking({ ...asking, lines: asking.lines.map((l) => (l.id === line.id ? { ...l, depth: e.target.value.replace(/[^0-9.]/g, "") } : l)) })}
                />
              </Field>
            ))}
            {!lineDepths(asking.lines) && <span className="muted small">Each depth is more than 0 and at most 48 inches.</span>}
            <FormError error={apply.error} />
            <div className="form-actions">
              <Button onClick={() => setAsking(null)}>Cancel</Button>
              <Button type="submit" variant="primary" disabled={!lineDepths(asking.lines)} loading={apply.isPending}>Fill quantities</Button>
            </div>
          </form>
        </Dialog>
      )}
    </DrawingsCard>
  );
}
