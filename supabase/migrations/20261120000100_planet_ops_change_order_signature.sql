-- Planet Ops Phase 1: a customer's acceptance is tied to the complete document version, only the
-- customer can sign, and a change order is finalized only with the customer's signature on its exact
-- current version (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3).
--
-- 1. The document version. private.quote_version() is everything a quote or change order offers:
--    its lines (names, descriptions, quantities, units, prices, tax, which are optional and grouped),
--    options, schedule (how often, start and end, months), payment terms (deposit and payment
--    schedule), discount, tax rate, promo code, contract sections and the template's terms and
--    signature settings, and a price set on site (its "Price adjustment" lines). It leaves out what
--    the customer chooses as they sign (the option and the add-ons, recorded with the approval and
--    its amounts) and what's derived (totals). Its fingerprint (md5) changes with any of those, at
--    the same price too.
-- 2. Signing. The page the customer signs from (the client hub, or the in-person signing screen)
--    sends the fingerprint of the version it showed (approval.seen_fingerprint). As the quote is
--    approved, the database compares it with the version now: a page opened before a change can't
--    sign. The customer's own choice of another option, made as they sign, takes a price set on site
--    for the option shown off the quote; that choice is theirs, so the version they're held to is the
--    one as it was just before it (private.offered_version). A change order can only be signed with one. The approval then keeps the fingerprint and a
--    copy of that version (approval.document), so the signed agreement is preserved as signed.
-- 3. Only the customer signs, and only by drawing. A customer signature has three separate parts:
--    the printed name, the signing time, and a signature drawn with a finger, mouse or stylus (a PNG
--    from the signature pad). A typed name alone is never a signature: an acceptance without the
--    drawing is refused, for quotes, proposals and change orders alike. A customer signature (an
--    approval that isn't the office's "manual" one) is written only by the server: approve_hub_quote (the customer's own link) and sign_quote
--    (in-person signing through the API, which checks the drawn signature). Nobody signed in can
--    write or alter one through the API, and sign_quote is no longer callable from the browser.
-- 4. Accepting any quote, proposal or change order (approved), or making it a job (converted, which
--    for a change order adds its lines to the job), needs that drawn customer signature on the
--    version it is now; so does linking a job to a quote. The office's "Mark approved" ("manual"
--    approvals), converting an unsigned or office-approved quote, status changes through the API and
--    inserts are refused: internal approval never stands in for the customer's. Every customer
--    acceptance needs the version fingerprint (seen_fingerprint) of the page it was signed from.
-- 5. A signed agreement stays as signed: it can't be reopened, moved to another job, deleted or
--    signed over, and a change order's signed lines can't change. A revised agreement is a new
--    revision (a new change order for a job), signed again.
--
-- Agreements already approved or converted before this keep their state; one the office approved
-- itself needs the customer's signature before it's made a job. Packages/core/src/changeOrders.ts
-- has the same rules for the interface.

-- ---------------------------------------------------------------------------------------------
-- 1. The document version and its fingerprint
-- ---------------------------------------------------------------------------------------------

create function private.quote_version(p_quote uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with q as (select * from public.quotes where id = p_quote),
  tpl as (
    -- The template it prints with: its own, else the company's default.
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
        -- promo_every_visit is fixed as it's approved (from the code's own setting), and a deposit
        -- given as a percent comes to its amount from the total: neither is the document's own.
        'discount_amount', q.discount_amount, 'tax_rate', q.tax_rate, 'promo_code_id', q.promo_code_id,
        'deposit_amount', case when q.deposit_percent is null then q.deposit_amount end, 'deposit_percent', q.deposit_percent, 'payment_schedule', q.payment_schedule,
        'recurrence_rule', q.recurrence_rule, 'active_months', q.active_months, 'starts_on', q.starts_on, 'ends_on', q.ends_on,
        'valid_until', q.valid_until, 'template_id', q.template_id, 'section_ids', q.section_ids,
        'range_low', q.range_low, 'range_high', q.range_high)
      from q),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'name', l.name, 'description', l.description, 'quantity', l.quantity, 'unit', l.unit,
        'unit_price', l.unit_price, 'taxable', l.taxable, 'optional', l.optional,
        -- Which add-ons are ticked, and which option's lines count, is the customer's choice as they
        -- sign (recorded with the approval and its amounts), not the document.
        'selected', case when l.optional or l.option_id is not null then null else l.selected end,
        'option_id', l.option_id, 'option_group', l.option_group, 'sort', l.sort) order by l.sort, l.id), '[]')
      -- A price set on site (estimates.ts SITE_ADJUSTMENT_NAME, "Price adjustment" lines) is part
      -- of the price offered, so it's in the version like any other line: changing it makes an open
      -- page outdated. The customer picking another option as they sign takes it off; see
      -- private.offered_version for how that choice is kept theirs.
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

create function private.quote_fingerprint(p_quote uuid) returns text
language sql stable security definer set search_path = '' as $$
  select md5(private.quote_version(p_quote)::text)
$$;

-- The version as it was offered, before the customer's own choice of option. A customer signing on
-- their link for another option than the one shown (approve_hub_quote shows it first, in the same
-- step) takes off a price set on site for the shown one, so the version they saw is the one just
-- before that switch. This keeps, for the rest of the transaction only, the fingerprint of each quote
-- as it was before its first switch in it; b_signed_version accepts a signature for that version.
-- Only the server signs for a customer (customer_signs_only_through_the_server), and a change made
-- in an earlier transaction (an office edit) is already in it, so an outdated page still can't sign.
create function private.offered_version(p_quote uuid) returns text
language sql stable set search_path = '' as $$
  select nullif(current_setting('planet_ops.offered_versions', true), '')::jsonb ->> p_quote::text
$$;
create function private.keep_offered_version() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_kept jsonb := coalesce(nullif(current_setting('planet_ops.offered_versions', true), '')::jsonb, '{}');
begin
  if not v_kept ? new.id::text then
    -- Read from the table, where the lines and the price set on site are still as they were.
    perform set_config('planet_ops.offered_versions', (v_kept || jsonb_build_object(new.id::text, private.quote_fingerprint(new.id)))::text, true);
  end if;
  return new;
end $$;
create trigger keep_offered_version before update of option_id on public.quotes
  for each row when (old.option_id is distinct from new.option_id and old.status in ('draft', 'sent', 'changes_requested'))
  execute function private.keep_offered_version();

-- For the pages a customer signs from: the server (the client hub) and a member of the quote's
-- company (the in-person signing screen). Nothing else about the quote is revealed.
create function public.quote_fingerprint(p_quote uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_company uuid;
begin
  select company_id into v_company from public.quotes where id = p_quote;
  if v_company is null then
    return null;
  end if;
  if (select auth.uid()) is not null and not private.is_member(v_company) then
    return null;
  end if;
  return private.quote_fingerprint(p_quote);
end $$;
revoke execute on function public.quote_fingerprint(uuid) from public, anon;
grant execute on function public.quote_fingerprint(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 and 3. Customer signatures: what one is, who may write one, and what it's tied to
-- ---------------------------------------------------------------------------------------------

-- A signature drawn on the signature pad: a PNG data URL whose header (decoded here) says a size a
-- signature pad makes, at least 120 x 60 pixels (so never a one-pixel image) and at most 8000 a side
-- and 8 million pixels, 8 bits a channel. The API decodes the whole image before the server writes it
-- (apps/api/src/lib/drawnSignature.ts: checksums, a complete image, enough ink in a stroke, not a
-- blank pad or a tap); only the server writes a customer signature (below), so this is the database's
-- own check that what's kept is a pad's drawing, never typed words.
create function private.png_size(p text) returns integer[]
language plpgsql immutable set search_path = '' as $$
declare b bytea;
begin
  if p is null or p !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]+$' or length(p) < 70 then
    return null;
  end if;
  b := decode(substr(p, 23, 44), 'base64');
  if length(b) < 25 or substring(b from 13 for 4) <> '\x49484452'::bytea then
    return null;
  end if;
  return array[
    (get_byte(b, 16)::bigint << 24 | get_byte(b, 17) << 16 | get_byte(b, 18) << 8 | get_byte(b, 19))::integer,
    (get_byte(b, 20)::bigint << 24 | get_byte(b, 21) << 16 | get_byte(b, 22) << 8 | get_byte(b, 23))::integer,
    get_byte(b, 24)];
exception when others then
  return null;
end $$;

create function private.is_drawn_signature(p text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(
    length(p) between 200 and 300100
    and (private.png_size(p))[1] between 120 and 8000
    and (private.png_size(p))[2] between 60 and 8000
    and (private.png_size(p))[1]::bigint * (private.png_size(p))[2] <= 8000000
    and (private.png_size(p))[3] = 8,
    false)
$$;

-- An approval the customer made: anything but the office's "manual" one, with the printed name, the
-- signing time and the drawn signature, each its own field.
create function private.is_customer_signature(p_approval jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_approval) = 'object'
    and coalesce(p_approval ->> 'method', '') <> 'manual'
    and length(trim(coalesce(p_approval ->> 'name', ''))) > 0
    and coalesce(p_approval ->> 'signed_at', '') <> ''
    and private.is_drawn_signature(p_approval ->> 'signature'),
    false)
$$;

-- What the customer signed, without what's added beside it later: the business's countersignature
-- and the payment schedule's amounts.
create function private.customer_part(p_approval jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_approval) = 'object' then p_approval - 'company' - 'payment_schedule' else p_approval end
$$;

-- Nobody signed in writes or alters a customer signature: only the server's signing steps do. Named
-- to run before the other triggers, on what the request itself sent.
create function private.customer_signs_only_through_the_server() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not (private.is_customer_signature(new.approval) or private.is_customer_signature(old.approval)) then
    return new;
  end if;
  if tg_op = 'INSERT' or private.customer_part(new.approval) is distinct from private.customer_part(old.approval) then
    raise exception 'Only the customer can sign: on their own link, or in person on the signing screen. A signature can''t be entered or changed for them.'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger aa_customer_signs_only_through_the_server before insert or update of approval on public.quotes
  for each row execute function private.customer_signs_only_through_the_server();

-- As the customer signs (a quote, proposal or change order moving to approved): it's a drawn
-- signature, from a page showing this exact version, and never over a signature already given.
-- The approval then keeps, each in its own field: the printed name, the drawing, the signing time
-- (the database's own clock, not the caller's), the version's fingerprint and a copy of it (the
-- original signed document), and the customer's choices (the option, the add-ons) with the amounts
-- they came to.
create function private.signed_version() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_version jsonb; v_fingerprint text; v_seen text;
begin
  if jsonb_typeof(new.approval) is distinct from 'object' or coalesce(new.approval ->> 'method', '') = 'manual' then
    return new;  -- Not the customer's: private.customer_signature_to_accept refuses it.
  end if;
  if not private.is_customer_signature(new.approval) then
    raise exception 'A drawn signature is needed to sign: draw it with a finger, mouse or stylus. A typed name alone doesn''t sign.'
      using errcode = '22023';
  end if;
  if private.is_customer_signature(old.approval) then
    raise exception 'The customer already signed this. Make a new revision (Copy as new draft) for anything that changes, and send that to sign.'
      using errcode = '22023';
  end if;
  v_version := private.quote_version(new.id);
  v_fingerprint := md5(v_version::text);
  v_seen := nullif(new.approval ->> 'seen_fingerprint', '');
  if v_seen is null then
    raise exception 'A document is signed only from a page showing its exact version. Open it again and sign there.'
      using errcode = 'CX410';
  end if;
  -- The version now, or (when the customer chose another option as they signed) the version just
  -- before that choice (private.offered_version). Any other change since the page opened refuses it.
  if v_seen <> v_fingerprint and v_seen is distinct from private.offered_version(new.id) then
    raise exception 'This document changed after it was opened, so it wasn''t signed. Look over the latest version and sign that.'
      using errcode = 'CX410';
  end if;
  new.approval := new.approval || jsonb_build_object(
    'signed_at', now(),
    'fingerprint', v_fingerprint,
    'document', v_version,
    'choices', jsonb_build_object(
      'option_id', new.option_id,
      'selected_line_ids', (select coalesce(jsonb_agg(l.id order by l.sort, l.id), '[]') from public.quote_line_items l
                             where l.quote_id = new.id and l.optional and l.selected),
      'subtotal', new.subtotal, 'discount_amount', new.discount_amount, 'tax_amount', new.tax_amount, 'total', new.total));
  return new;
end $$;
create trigger b_signed_version before update of status on public.quotes
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function private.signed_version();

-- In-person signing goes through the API (services/signing.ts), which checks the drawn signature and
-- the person's access, then calls this as the server.
revoke execute on function public.sign_quote(uuid, jsonb, uuid, numeric) from authenticated;
grant execute on function public.sign_quote(uuid, jsonb, uuid, numeric) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 4. Accepting a quote, proposal or change order, or making it a job, needs the customer's drawn
--    signature on the version it is now
-- ---------------------------------------------------------------------------------------------

create function private.customer_signed_this_version(p_quote uuid, p_approval jsonb, p_total numeric) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    private.is_customer_signature(p_approval)
    and p_approval ->> 'fingerprint' = private.quote_fingerprint(p_quote)
    and (p_approval ->> 'total') ~ '^-?[0-9]+(\.[0-9]+)?$'
    and round((p_approval ->> 'total')::numeric, 2) = round(p_total, 2),
    false)
$$;

-- Approved (the customer accepted it) or converted (it's a job, or a change order on its job): only
-- with the customer's signature on this exact version. The office's "Mark approved" (a "manual"
-- approval), converting an unsigned or office-approved quote, a status change through the API, an
-- assistant or an automation are all refused. A quote is never inserted already accepted.
create function private.customer_signature_to_accept() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_what text := case when new.change_order_for is not null then 'A change order is added to the job' else 'A quote or proposal is accepted, and made a job,' end;
begin
  if tg_op = 'INSERT' or (new.status = 'converted' and old.status is distinct from 'approved') then
    raise exception '% only once the customer signs this exact version. Send it to them to sign, or have them sign it in person.', v_what
      using errcode = '22023';
  end if;
  if not private.customer_signed_this_version(new.id, new.approval, new.total) then
    if private.is_customer_signature(new.approval) then
      raise exception 'This changed after the customer signed it, so it needs their signature again on a new revision.'
        using errcode = '22023';
    end if;
    raise exception '% only once the customer signs this exact version. Send it to them to sign, or have them sign it in person.', v_what
      using errcode = '22023';
  end if;
  return new;
end $$;

-- Runs after b_signed_version, which keeps the version with the signature first.
create trigger c_customer_signature_to_accept before insert on public.quotes
  for each row when (new.status in ('approved', 'converted'))
  execute function private.customer_signature_to_accept();
create trigger c_customer_signature_to_accept_update before update of status on public.quotes
  for each row when (new.status in ('approved', 'converted') and old.status is distinct from new.status)
  execute function private.customer_signature_to_accept();

-- A quote imported from Jobber as approved (import_jobber) comes in sent instead: Jobber's approval is
-- not the customer's drawn signature on this version, so it waits for one here before it's a job.
-- This only ever moves an unsigned import back to sent, never forward.
create function private.jobber_approved_comes_in_sent() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.status := 'sent';
  new.approved_at := null;
  return new;
end $$;
create trigger a_jobber_approved_comes_in_sent before update of status on public.quotes
  for each row
  when (new.source_id like 'jobber:%' and old.status = 'draft' and new.status = 'approved' and new.approval is null)
  execute function private.jobber_approved_comes_in_sent();

-- A job takes a quote (quotes.quote_id) only once the customer signed it: converting it is how a job
-- gets one. A job made directly (Create Job) has none.
create function private.job_quote_signed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.quotes q where q.id = new.quote_id and q.status in ('approved', 'converted')
                    and private.is_customer_signature(q.approval)) then
    raise exception 'A job takes a quote only once the customer signs it. Send the quote to sign, or make the job without it.'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger job_quote_signed before insert or update of quote_id on public.jobs
  for each row when (new.quote_id is not null)
  execute function private.job_quote_signed();

-- ---------------------------------------------------------------------------------------------
-- 5. A finalized change order stays as signed
-- ---------------------------------------------------------------------------------------------

create function private.signed_change_order_stays() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- A cascade from deleting the job (which unlinks it) or the company (a trigger deeper than this one) goes ahead.
  if pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    raise exception 'This was signed by the customer, so it''s kept as signed and can''t be deleted.'
      using errcode = '22023';
  end if;
  if new.status not in ('approved', 'converted') or new.change_order_for is distinct from old.change_order_for then
    raise exception 'This was signed by the customer, so it stays as signed. Make a new revision (for a job, a new change order) for anything that changes.'
      using errcode = '22023';
  end if;
  return new;
end $$;
-- Every agreement the customer signed (a quote, proposal or change order), and every change order on
-- its job (finalized before this migration too): not reopened, moved or deleted.
create trigger signed_change_order_stays before update of status, change_order_for or delete on public.quotes
  for each row
  when (old.status in ('approved', 'converted') and (old.change_order_for is not null or private.is_customer_signature(old.approval)))
  execute function private.signed_change_order_stays();

-- Its signed lines don't change either: the scope and the price.
create function private.signed_change_order_lines_stay() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_quote uuid;
begin
  -- A delete cascading from the quote or the company (a trigger deeper than this one) goes ahead.
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    v_quote := old.quote_id;
  elsif tg_op = 'UPDATE' then
    -- Only what was signed is locked: a price-list service deleted (its link set to null) or a cost
    -- noted for job costing changes neither the scope nor the price.
    if (new.quote_id, new.name, new.description, new.quantity, new.unit, new.unit_price, new.taxable, new.selected, new.optional, new.option_id)
       is not distinct from
       (old.quote_id, old.name, old.description, old.quantity, old.unit, old.unit_price, old.taxable, old.selected, old.optional, old.option_id) then
      return new;
    end if;
    v_quote := old.quote_id;
  else
    v_quote := new.quote_id;
  end if;
  if exists (select 1 from public.quotes q
              where q.id = v_quote and q.change_order_for is not null and q.status in ('approved', 'converted')) then
    raise exception 'This change order was signed by the customer and added to the job, so its lines can''t change. Make a new change order for anything else.'
      using errcode = '22023';
  end if;
  return coalesce(new, old);
end $$;
create trigger signed_change_order_lines_stay before insert or update or delete on public.quote_line_items
  for each row execute function private.signed_change_order_lines_stay();

-- is_customer_signature, is_drawn_signature and png_size stay callable: pure checks that the triggers'
-- conditions run as whoever changes the quote.
revoke execute on function private.quote_version(uuid), private.quote_fingerprint(uuid),
  private.customer_part(jsonb), private.customer_signs_only_through_the_server(), private.signed_version(),
  private.customer_signed_this_version(uuid, jsonb, numeric), private.customer_signature_to_accept(), private.job_quote_signed(),
  private.jobber_approved_comes_in_sent(), private.offered_version(uuid), private.keep_offered_version(),
  private.signed_change_order_stays(), private.signed_change_order_lines_stay() from public;
