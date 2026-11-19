-- Planet Ops Phase 1: a customer's acceptance is tied to the complete document version, only the
-- customer can sign, and a change order is finalized only with the customer's signature on its exact
-- current version (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3).
--
-- 1. The document version. private.quote_version() is everything a quote or change order offers:
--    its lines (names, descriptions, quantities, units, prices, tax, which are optional and grouped),
--    options, schedule (how often, start and end, months), payment terms (deposit and payment
--    schedule), discount, tax rate, promo code, contract sections and the template's terms and
--    signature settings. It leaves out what the customer chooses as they sign (the option and the
--    add-ons, recorded with the approval and its amounts) and what's derived (totals). Its
--    fingerprint (md5) changes with any of those, at the same price too.
-- 2. Signing. The page the customer signs from (the client hub, or the in-person signing screen)
--    sends the fingerprint of the version it showed (approval.seen_fingerprint). As the quote is
--    approved, the database compares it with the version now: a page opened before a change can't
--    sign. A change order can only be signed with one. The approval then keeps the fingerprint and a
--    copy of that version (approval.document), so the signed agreement is preserved as signed.
-- 3. Only the customer signs, and only by drawing. A customer signature has three separate parts:
--    the printed name, the signing time, and a signature drawn with a finger, mouse or stylus (a PNG
--    from the signature pad). A typed name alone is never a signature: an acceptance without the
--    drawing is refused, for quotes, proposals and change orders alike. A customer signature (an
--    approval that isn't the office's "manual" one) is written only by the server: approve_hub_quote (the customer's own link) and sign_quote
--    (in-person signing through the API, which checks the drawn signature). Nobody signed in can
--    write or alter one through the API, and sign_quote is no longer callable from the browser.
-- 4. Finalizing a change order (approved or converted, which adds its lines to the job) needs that
--    customer signature, on the version it is now. Staff "Mark approved", converting, status changes
--    and inserts are refused, for added charges, credits and $0 changes alike.
-- 5. A finalized change order stays as signed: it can't be reopened, moved to another job or
--    deleted, and its signed lines can't change. A revised agreement is a new change order, signed
--    again.
--
-- Change orders already approved or converted before this keep their state. Packages/core/src/
-- changeOrders.ts has the same rules for the interface.

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

-- A signature drawn on the signature pad: a PNG (its file signature, iVBORw0KGgo, at the start of the
-- data), of a size a signature pad makes. The API checks the image itself (logo.ts isDrawnPng); this is
-- the database's own check that it's a drawing, never typed words.
create function private.is_drawn_signature(p text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p ~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]+$' and length(p) <= 300100, false)
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
  if (select auth.uid()) is null or not private.is_customer_signature(new.approval) then
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

-- As a quote is signed by the customer: the page they signed from must have shown this version (a
-- change order can't be signed without saying which), and the approval keeps the version.
create function private.signed_version() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_version jsonb; v_fingerprint text; v_seen text;
begin
  -- An acceptance in the customer's name (it has a signing time) without the drawn signature: a typed
  -- name alone doesn't sign anything.
  if jsonb_typeof(new.approval) = 'object' and coalesce(new.approval ->> 'method', '') <> 'manual'
     and coalesce(new.approval ->> 'signed_at', '') <> '' and not private.is_customer_signature(new.approval) then
    raise exception 'A drawn signature is needed to sign: draw it with a finger, mouse or stylus. A typed name alone doesn''t sign.'
      using errcode = '22023';
  end if;
  if not private.is_customer_signature(new.approval) then
    return new;
  end if;
  v_version := private.quote_version(new.id);
  v_fingerprint := md5(v_version::text);
  v_seen := nullif(new.approval ->> 'seen_fingerprint', '');
  if v_seen is not null and v_seen <> v_fingerprint then
    raise exception 'This document changed after it was opened, so it wasn''t signed. Look over the latest version and sign that.'
      using errcode = 'CX410';
  end if;
  if new.change_order_for is not null and v_seen is null then
    raise exception 'A change order is signed only from a page showing its exact version. Open it again and sign there.'
      using errcode = 'CX410';
  end if;
  new.approval := new.approval || jsonb_build_object('fingerprint', v_fingerprint, 'document', v_version);
  return new;
end $$;
create trigger b_signed_version before update of status on public.quotes
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function private.signed_version();
create trigger b_signed_version_insert before insert on public.quotes
  for each row when (new.status = 'approved')
  execute function private.signed_version();

-- In-person signing goes through the API (services/signing.ts), which checks the drawn signature and
-- the person's access, then calls this as the server.
revoke execute on function public.sign_quote(uuid, jsonb, uuid, numeric) from authenticated;
grant execute on function public.sign_quote(uuid, jsonb, uuid, numeric) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 4. Finalizing a change order needs the customer's signature on the version it is now
-- ---------------------------------------------------------------------------------------------

create function private.change_order_customer_signed(p_quote uuid, p_approval jsonb, p_total numeric) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    private.is_customer_signature(p_approval)
    and p_approval ->> 'fingerprint' = private.quote_fingerprint(p_quote)
    and (p_approval ->> 'total') ~ '^-?[0-9]+(\.[0-9]+)?$'
    and round((p_approval ->> 'total')::numeric, 2) = round(p_total, 2),
    false)
$$;

create function private.change_order_needs_signature() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.change_order_customer_signed(new.id, new.approval, new.total) then
    if private.is_customer_signature(new.approval) then
      raise exception 'This change order changed after the customer signed it, so it needs their signature again before it''s added to the job.'
        using errcode = '22023';
    end if;
    raise exception 'A change order is added to the job only once the customer signs this exact version. Send it to them to sign, or have them sign it in person.'
      using errcode = '22023';
  end if;
  return new;
end $$;

-- Checked as it's finalized: inserted finalized, or moving from an open state to a finalized one.
-- Runs after b_signed_version, which keeps the version with the signature first.
create trigger c_change_order_needs_signature before insert on public.quotes
  for each row
  when (new.change_order_for is not null and new.status in ('approved', 'converted'))
  execute function private.change_order_needs_signature();
create trigger c_change_order_needs_signature_update before update of status, change_order_for on public.quotes
  for each row
  when (new.change_order_for is not null and new.status in ('approved', 'converted')
        and (old.status not in ('approved', 'converted') or old.change_order_for is null))
  execute function private.change_order_needs_signature();

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
    raise exception 'This change order was signed by the customer, so it''s kept as signed and can''t be deleted.'
      using errcode = '22023';
  end if;
  if new.status not in ('approved', 'converted') or new.change_order_for is distinct from old.change_order_for then
    raise exception 'This change order was signed by the customer, so it stays as signed. Make a new change order for anything that changes.'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger signed_change_order_stays before update of status, change_order_for or delete on public.quotes
  for each row
  when (old.change_order_for is not null and old.status in ('approved', 'converted'))
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

revoke execute on function private.quote_version(uuid), private.quote_fingerprint(uuid), private.is_customer_signature(jsonb), private.is_drawn_signature(text),
  private.customer_part(jsonb), private.customer_signs_only_through_the_server(), private.signed_version(),
  private.change_order_customer_signed(uuid, jsonb, numeric), private.change_order_needs_signature(),
  private.signed_change_order_stays(), private.signed_change_order_lines_stay() from public;
