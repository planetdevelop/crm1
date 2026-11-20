-- Planet Ops Phase 1b: Quotes & Proposals (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3).
--
-- 1. Two customer-facing layouts on the same quote record: a line-item quote (priced lines) or a
--    proposal (project overview, scope in work order, inclusions, exclusions, assumptions, optional
--    alternates and a clear total). Both use the quote's one total; switching an unsigned draft
--    between them keeps prices, scope and terms.
-- 2. Contract Terms and Payment Terms: two separate sections on every quote and proposal, edited per
--    job, filled from the company's defaults (settings.quotes.contract_terms / payment_terms) when a
--    quote is made. The business supplies the approved wording; nothing here writes legal terms.
-- 3. Company countersignature, configurable (settings.quotes.countersign_required, off unless set).
--    A countersignature is an intentional act by a signed-in signer for one agreement: drawn now, or
--    their own saved drawing applied on purpose (approval.company.method 'drawn' or 'saved'). It
--    records who signed (user_id) and is stamped here with the database's own time and the
--    fingerprint of the version the customer signed, so it's bound to that exact agreement. It's
--    never added for the company as the customer signs on their link. When required, a quote,
--    proposal or change order becomes a job (or joins its job) only once it's there, so "customer
--    accepted" and "company countersigned" stay separate.
--
-- All of these are part of the signed document version (private.quote_version, from
-- 20261120000100): a change to any of them is a new version, and a page that showed an older one
-- can't sign. Once signed, they're kept as signed.

alter table public.quotes
  add column presentation text not null default 'line_items' check (presentation in ('line_items', 'proposal')),
  add column narrative jsonb not null default '{}' check (jsonb_typeof(narrative) = 'object' and length(narrative::text) <= 60000),
  add column contract_terms text check (length(contract_terms) <= 20000),
  add column payment_terms text check (length(payment_terms) <= 20000);

comment on column public.quotes.presentation is 'Planet Ops: how the customer sees it: line_items (a quote with priced lines) or proposal (narrative scope and a total). Same total either way.';
comment on column public.quotes.narrative is 'Planet Ops: the proposal''s sections as text: overview, scope (in work order), inclusions, exclusions, assumptions, alternates.';
comment on column public.quotes.contract_terms is 'Planet Ops: the Contract Terms for this job, filled from the company''s default and edited before sending.';
comment on column public.quotes.payment_terms is 'Planet Ops: the Payment Terms for this job, kept separate from the Contract Terms.';

-- The narrative's sections, and nothing else.
create function private.narrative_ok(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select not exists (
    select 1 from jsonb_each(p) e
     where e.key not in ('overview', 'scope', 'inclusions', 'exclusions', 'assumptions', 'alternates')
        or jsonb_typeof(e.value) not in ('string', 'null'))
$$;
alter table public.quotes add constraint quotes_narrative_sections check (private.narrative_ok(narrative));

-- A new quote takes the company's default terms, as text the office edits for the job. Until the
-- company has saved its own (an empty one means none), clearly marked placeholders (core proposals.ts
-- has the same words): no legal wording is written here.
create function private.quote_default_terms() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_settings jsonb;
begin
  select settings into v_settings from public.companies where id = new.company_id;
  if new.contract_terms is null then
    new.contract_terms := case when v_settings -> 'quotes' ? 'contract_terms' then nullif(v_settings -> 'quotes' ->> 'contract_terms', '')
      else '[PLACEHOLDER] Contract Terms: Planet Demolition will supply the approved wording. This is not approved text; don''t send it to a real customer.' end;
  end if;
  if new.payment_terms is null then
    new.payment_terms := case when v_settings -> 'quotes' ? 'payment_terms' then nullif(v_settings -> 'quotes' ->> 'payment_terms', '')
      else '[PLACEHOLDER] Payment Terms: Planet Demolition will supply the approved wording. This is not approved text; don''t send it to a real customer.' end;
  end if;
  return new;
end $$;
create trigger quote_default_terms before insert on public.quotes
  for each row execute function private.quote_default_terms();

-- Once signed, the layout, the narrative and the terms stay as signed (the lines already do).
create function private.signed_terms_stay() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.presentation, new.narrative, new.contract_terms, new.payment_terms)
     is distinct from (old.presentation, old.narrative, old.contract_terms, old.payment_terms) then
    raise exception 'This was signed, so its layout and terms stay as signed. Make a change order or a new quote for anything that changes.'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger signed_terms_stay before update of presentation, narrative, contract_terms, payment_terms on public.quotes
  for each row when (old.status in ('approved', 'converted'))
  execute function private.signed_terms_stay();

-- Whether the company has to countersign before an agreement counts.
create function private.countersign_required(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select settings -> 'quotes' ->> 'countersign_required' = 'true' from public.companies where id = p_company), false)
$$;

-- ---------------------------------------------------------------------------------------------
-- The document version now includes the layout, the narrative and both terms (as in 20261120000100,
-- with those added). Whether a countersignature is required isn't the document's: turning it on or
-- off doesn't make a change order the customer already signed outdated.
-- ---------------------------------------------------------------------------------------------

create or replace function private.quote_version(p_quote uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with q as (select * from public.quotes where id = p_quote),
  tpl as (
    select t.settings from public.document_templates t, q
     where t.company_id = q.company_id and (t.id = q.template_id or (q.template_id is null and t.is_default))
     order by (t.id = q.template_id) desc nulls last limit 1
  ),
  section_ids as (
    select unnest(q.section_ids) as id from q
    union select unnest(o.section_ids) from public.quote_options o where o.quote_id = p_quote
    union select (jsonb_array_elements_text(case when jsonb_typeof(tpl.settings -> 'sections') = 'array' then tpl.settings -> 'sections' else '[]' end))::uuid from tpl
  )
  select jsonb_build_object(
    'quote', (select jsonb_build_object(
        'client_id', q.client_id, 'property_id', q.property_id, 'change_order_for', q.change_order_for,
        'title', q.title, 'message', q.message,
        'presentation', q.presentation, 'narrative', q.narrative,
        'contract_terms', q.contract_terms, 'payment_terms', q.payment_terms,
        'discount_amount', q.discount_amount, 'tax_rate', q.tax_rate, 'promo_code_id', q.promo_code_id,
        'deposit_amount', case when q.deposit_percent is null then q.deposit_amount end, 'deposit_percent', q.deposit_percent, 'payment_schedule', q.payment_schedule,
        'recurrence_rule', q.recurrence_rule, 'active_months', q.active_months, 'starts_on', q.starts_on, 'ends_on', q.ends_on,
        'valid_until', q.valid_until, 'template_id', q.template_id, 'section_ids', q.section_ids,
        'range_low', q.range_low, 'range_high', q.range_high)
      from q),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'name', l.name, 'description', l.description, 'quantity', l.quantity, 'unit', l.unit,
        'unit_price', l.unit_price, 'taxable', l.taxable, 'optional', l.optional,
        'selected', case when l.optional or l.option_id is not null then null else l.selected end,
        'option_id', l.option_id, 'option_group', l.option_group, 'sort', l.sort) order by l.sort, l.id), '[]')
      -- A price set on site ("Price adjustment" lines) is part of the price offered, as in
      -- 20261120000100 (private.offered_version keeps the customer's own choice of option theirs).
      from public.quote_line_items l where l.quote_id = p_quote),
    'options', (select coalesce(jsonb_agg(to_jsonb(o) - 'created_at' - 'updated_at' order by o.sort, o.id), '[]')
      from public.quote_options o where o.quote_id = p_quote),
    'sections', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'body', s.body, 'place', s.place, 'initials', s.initials) order by s.id), '[]')
      from public.contract_sections s where s.id in (select id from section_ids)),
    'template', (select jsonb_build_object(
        'terms', tpl.settings -> 'terms', 'sections', tpl.settings -> 'sections',
        'customer_signs', tpl.settings -> 'customer_signs', 'company_signs', tpl.settings -> 'company_signs') from tpl)
  )
$$;

-- ---------------------------------------------------------------------------------------------
-- The company's countersignature.
-- ---------------------------------------------------------------------------------------------

-- A countersignature: who signed (name, user), how (drawn now, or their saved drawing applied on
-- purpose), the drawing, and the time and version the database stamped it with, which is the version
-- the customer signed.
create function private.is_company_countersignature(p_approval jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_approval -> 'company') = 'object'
    and length(trim(coalesce(p_approval -> 'company' ->> 'name', ''))) > 0
    and (p_approval -> 'company' ->> 'user_id') ~ '^[0-9a-fA-F-]{36}$'
    and (p_approval -> 'company' ->> 'method') in ('drawn', 'saved')
    and private.is_drawn_signature(p_approval -> 'company' ->> 'signature')
    and (p_approval -> 'company' ->> 'signed_at') is not null
    and (p_approval -> 'company' ->> 'fingerprint') is not null
    and (p_approval -> 'company' ->> 'fingerprint') = (p_approval ->> 'fingerprint'),
    false)
$$;

-- As a countersignature is added (on its own, or with the customer's when they sign in person): it's
-- a drawing by the person signed in (the server's in-person step names the seller it checked), on an
-- agreement the customer signed, on the version they signed. The database stamps the time and that
-- version. Once given, it isn't changed or taken off. Runs after b_signed_version, which stamps the
-- customer's version.
create function private.company_countersigns() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := case when jsonb_typeof(new.approval) = 'object' and jsonb_typeof(new.approval -> 'company') = 'object' then new.approval -> 'company' end;
  v_old jsonb := case when jsonb_typeof(old.approval) = 'object' and jsonb_typeof(old.approval -> 'company') = 'object' then old.approval -> 'company' end;
  v_uid uuid := (select auth.uid());
begin
  if v_new is not distinct from v_old then
    return new;
  end if;
  if v_old is not null then
    raise exception 'Your company already countersigned this. Make a new revision for anything that changes.'
      using errcode = '22023';
  end if;
  if not private.is_customer_signature(new.approval) then
    raise exception 'Your company countersigns once the customer has signed this exact version.'
      using errcode = '22023';
  end if;
  if length(trim(coalesce(v_new ->> 'name', ''))) = 0 or (v_new ->> 'method') is distinct from 'drawn' and (v_new ->> 'method') is distinct from 'saved'
     or not private.is_drawn_signature(v_new ->> 'signature') then
    raise exception 'Your company''s countersignature needs to be drawn with a finger, mouse or stylus, or your own saved signature applied.'
      using errcode = '22023';
  end if;
  if (v_new ->> 'user_id') is null or (v_uid is not null and (v_new ->> 'user_id') is distinct from v_uid::text) then
    raise exception 'A countersignature is signed by the person signed in, for themselves.'
      using errcode = '22023';
  end if;
  if (new.approval ->> 'fingerprint') is distinct from private.quote_fingerprint(new.id) then
    raise exception 'This changed after the customer signed it, so it can''t be countersigned. Make a new revision and have the customer sign it.'
      using errcode = '22023';
  end if;
  new.approval := jsonb_set(new.approval, '{company}',
    v_new || jsonb_build_object('signed_at', now(), 'fingerprint', new.approval ->> 'fingerprint'));
  return new;
end $$;
create trigger d_company_countersigns before update of approval on public.quotes
  for each row execute function private.company_countersigns();

-- A required countersignature: a change order the customer signed joins its job once the company
-- has countersigned too (as in 20261017002500's change_order_approved, with that wait added).
create or replace function private.change_order_approved() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.change_order_for is not null and new.status = 'approved' and old.status is distinct from 'approved' then
    if private.countersign_required(new.company_id) and not private.is_company_countersignature(new.approval) then
      -- Customer accepted; waiting for the company's countersignature (change_order_countersigned).
      return null;
    end if;
    perform private.apply_change_order(new.id);
  end if;
  return null;
end $$;

create function private.change_order_countersigned() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.change_order_for is not null and new.status = 'approved' and private.is_company_countersignature(new.approval)
     and not private.is_company_countersignature(old.approval) then
    perform private.apply_change_order(new.id);
  end if;
  return null;
end $$;
create trigger change_order_countersigned after update of approval on public.quotes
  for each row execute function private.change_order_countersigned();

-- A required countersignature is there before an agreement is finalized: a quote or proposal becoming
-- a job, or a change order joining its job. Turned on after the customer signed, it's still needed.
create function private.countersigned_to_finalize(p_company uuid, p_approval jsonb, p_change_order boolean) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.countersign_required(p_company) and not private.is_company_countersignature(p_approval) then
    raise exception '%', case when p_change_order
      then 'The customer signed this change order. It''s added to the job once your company countersigns it.'
      else 'The customer signed this. It becomes a job once your company countersigns it.' end
      using errcode = '22023';
  end if;
end $$;

create function private.quote_countersigned_to_finalize() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.countersigned_to_finalize(new.company_id, new.approval, new.change_order_for is not null);
  return new;
end $$;
create trigger e_quote_countersigned_to_finalize before update of status on public.quotes
  for each row when (new.status = 'converted' and old.status is distinct from 'converted')
  execute function private.quote_countersigned_to_finalize();

create function private.job_quote_countersigned() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_quote record;
begin
  select company_id, approval, change_order_for into v_quote from public.quotes where id = new.quote_id;
  if found then
    perform private.countersigned_to_finalize(v_quote.company_id, v_quote.approval, v_quote.change_order_for is not null);
  end if;
  return new;
end $$;
create trigger job_quote_signed_and_countersigned before insert or update of quote_id on public.jobs
  for each row when (new.quote_id is not null)
  execute function private.job_quote_countersigned();

-- narrative_ok and is_company_countersignature stay callable: a check and conditions run them as
-- whoever writes the quote.
revoke execute on function private.quote_default_terms(), private.signed_terms_stay(),
  private.countersign_required(uuid), private.change_order_countersigned(), private.company_countersigns(),
  private.countersigned_to_finalize(uuid, jsonb, boolean), private.quote_countersigned_to_finalize(),
  private.job_quote_countersigned() from public;
