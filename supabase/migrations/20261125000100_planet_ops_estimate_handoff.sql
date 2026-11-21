-- Planet Ops Phase 3: from an internal estimate to the customer's document, the summary, and the job
-- (after 20261124000100_planet_ops_estimating.sql).
--
-- 1. public.create_quote_from_estimate: a saved estimate version becomes an unsent line-item quote or
--    proposal draft, linked to that exact version (quotes.estimate_version_id). Only what a customer
--    sees crosses: each customer item and its selling price, and the customer-facing scope; never a
--    wage, cost, rate, margin, risk, owner pay or internal note (the quote's own unit_cost stays
--    empty). Needs Estimating and Quotes and sales; when the business requires approval (Settings →
--    Estimating, on unless switched off) the version must be approved. Nothing is sent. A retried
--    call returns the draft it made.
-- 2. public.estimate_quote_diff and public.refresh_quote_from_estimate: an unsigned document can be
--    brought up to date with an estimate version on purpose, after seeing the differences; a signed
--    one never. A sent document refreshed this way is a draft revision (Phase 1c) until it's sent.
--    The estimate is never changed by the customer's document, nor the document by the estimate.
-- 3. Each issued version of the document keeps the estimate version it carried
--    (quote_versions.estimate_version_id), and converting the signed version links the job to that
--    exact estimate version (jobs.estimate_version_id): never to whichever estimate is newest.
--    Documents and jobs with no estimate stay without one; no link is guessed. Only converting sets it.
-- 4. public.estimate_summary: the estimate's one internal summary, rendered (costs only for
--    estimate_costs). Once a job is made from it, its permanent copy's destination becomes the job's
--    folder (Phase 4 moves it; nothing is backed up here).

-- ---------------------------------------------------------------------------------------------
-- Links
-- ---------------------------------------------------------------------------------------------

alter table public.quotes add column estimate_version_id uuid;
alter table public.quotes add constraint quotes_estimate_version_fkey foreign key (company_id, estimate_version_id) references public.estimate_versions (company_id, id);
alter table public.quotes add column from_estimate_key uuid;
create unique index quotes_from_estimate_key on public.quotes (company_id, from_estimate_key) where from_estimate_key is not null;
comment on column public.quotes.estimate_version_id is 'Planet Ops: the internal estimate version this document''s prices came from (set only by create_quote_from_estimate and refresh_quote_from_estimate).';

alter table public.quote_versions add column estimate_version_id uuid;
alter table public.quote_versions add constraint quote_versions_estimate_version_fkey foreign key (company_id, estimate_version_id) references public.estimate_versions (company_id, id);
comment on column public.quote_versions.estimate_version_id is 'Planet Ops: the internal estimate version the document carried when this version was issued.';

alter table public.jobs add column estimate_version_id uuid;
alter table public.jobs add constraint jobs_estimate_version_fkey foreign key (company_id, estimate_version_id) references public.estimate_versions (company_id, id);
comment on column public.jobs.estimate_version_id is 'Planet Ops: the internal estimate version the signed document version was made from (set only by converting it).';

-- The document's estimate link is the estimating functions' to set.
create function private.quote_estimate_link_stays() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and (tg_op = 'INSERT' and (new.estimate_version_id is not null or new.from_estimate_key is not null)
     or tg_op = 'UPDATE' and (new.estimate_version_id is distinct from old.estimate_version_id or new.from_estimate_key is distinct from old.from_estimate_key)) then
    raise exception 'A document''s estimate link is set by creating it from the estimate, or refreshing it from one.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger quote_estimate_link_stays before insert or update of estimate_version_id, from_estimate_key on public.quotes
  for each row execute function private.quote_estimate_link_stays();

-- An issued version keeps the estimate version its document carried.
create function private.quote_version_estimate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.estimate_version_id := (select q.estimate_version_id from public.quotes q where q.id = new.quote_id);
  return new;
end $$;
create trigger a_quote_version_estimate before insert on public.quote_versions
  for each row execute function private.quote_version_estimate();

-- The job's estimate version: set only as the signed document is converted, to the one its signed
-- version carried; never set later, cleared or replaced (as the signed-version link, 20261121000300).
create function private.job_estimate_version_stays() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare v_converter name;
begin
  if tg_op = 'UPDATE' then
    if new.estimate_version_id is distinct from old.estimate_version_id then
      raise exception 'A job keeps the estimate version it was made from, and gets one only as a signed document is converted.' using errcode = '22023';
    end if;
    return new;
  end if;
  if new.estimate_version_id is null then return new; end if;
  select pg_get_userbyid(p.proowner) into v_converter from pg_proc p where p.oid = 'public.convert_quote_to_job(uuid)'::regprocedure;
  if current_user is distinct from v_converter or new.quote_id is null
     or current_setting('planet_ops.converting_quote', true) is distinct from new.quote_id::text
     or new.estimate_version_id is distinct from (select v.estimate_version_id from public.quote_versions v where v.id = new.quote_version_id) then
    raise exception 'A job''s estimate version is set only as a signed document is converted: the one its signed version carried.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger jobs_estimate_version_stays before insert or update of estimate_version_id on public.jobs
  for each row execute function private.job_estimate_version_stays();

-- As in 20261121000300, and: the job keeps the estimate version its signed version carried.
create or replace function public.convert_quote_to_job(p_quote uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v_job uuid; v_label text; v_today date; v_repeats boolean; v_version uuid; v_estimate_version uuid;
begin
  -- Locked while it's converted: a second click or request waits here, then finds the job.
  select * into q from public.quotes where id = p_quote for update;
  if not found or ((select auth.uid()) is not null
                   and not (private.has_role(q.company_id, '{owner,admin,office,estimator}') and private.has_perm(q.company_id, 'sales'))) then
    raise exception 'Quote not found' using errcode = 'P0002';
  end if;
  if q.status = 'converted' then
    v_job := case when q.change_order_for is not null then q.change_order_for
                  else (select j.id from public.jobs j where j.company_id = q.company_id and j.quote_id = q.id order by j.created_at limit 1) end;
    if v_job is not null then
      return v_job;
    end if;
    raise exception 'This quote is already converted' using errcode = '22023';
  end if;
  if q.status in ('lost', 'archived') then
    raise exception 'This quote is already %', q.status using errcode = '22023';
  end if;
  if q.status <> 'approved' and exists (select 1 from public.quote_options where quote_id = q.id) then
    raise exception 'This estimate offers options. Mark it approved with the option they chose first.' using errcode = '22023';
  end if;
  if q.change_order_for is not null then
    return private.apply_change_order(q.id);
  end if;

  -- The version the customer signed (signed before versions were kept: none to link).
  select v.id into v_version from public.quote_versions v
   where v.company_id = q.company_id and v.quote_id = q.id and v.id = nullif(q.approval ->> 'version_id', '')::uuid and v.signed_at is not null;

  v_repeats := q.recurrence_rule is not null;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date into v_today from public.companies c where c.id = q.company_id;
  -- Marks this quote as the one being converted, for the guard on the job's signed version.
  -- The internal estimate version the signed version was made from (none for a document that wasn't).
  select v.estimate_version_id into v_estimate_version from public.quote_versions v where v.id = v_version;
  perform set_config('planet_ops.converting_quote', q.id::text, true);
  insert into public.jobs (company_id, client_id, property_id, quote_id, request_id, quote_version_id, estimate_version_id, title, instructions, kind, recurrence_rule, active_months, starts_on, ends_on, billing_mode)
  values (
    q.company_id, q.client_id, q.property_id, q.id, q.request_id, v_version, v_estimate_version, q.title, q.message,
    case when v_repeats then 'recurring' else 'one_off' end,
    q.recurrence_rule,
    case when v_repeats then q.active_months end,
    case when v_repeats then greatest(coalesce(q.starts_on, v_today), v_today) end,
    case when v_repeats then q.ends_on end,
    case when v_repeats then 'per_visit' else 'on_completion' end
  )
  returning id into v_job;
  perform set_config('planet_ops.converting_quote', '', true);

  insert into public.job_line_items (company_id, job_id, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, sort)
  select company_id, v_job, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, sort
  from public.quote_line_items where quote_id = q.id and selected;
  select coalesce('Promo code ' || p.code, 'Discount') into v_label from public.promo_codes p where p.id = q.promo_code_id;
  perform private.carry_quote_discount(q.id, v_job, coalesce(v_label, 'Discount'));

  update public.quotes set status = 'converted', converted_at = now() where id = q.id;
  if q.request_id is not null then
    update public.requests set status = 'converted' where id = q.request_id;
  end if;
  update public.clients set status = 'active' where id = q.client_id and status = 'lead';
  return v_job;
end $$;


-- Once a job is made from an estimate's version, the summary's permanent copy belongs with the job.
create function private.estimate_summary_job() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.estimate_summaries s set drive_destination = 'job', job_id = new.id, updated_at = now()
    from public.estimate_versions v
   where v.id = new.estimate_version_id and s.estimate_id = v.estimate_id and s.job_id is null;
  return null;
end $$;
create trigger estimate_summary_job after insert on public.jobs
  for each row when (new.estimate_version_id is not null) execute function private.estimate_summary_job();

-- ---------------------------------------------------------------------------------------------
-- From the estimate to the customer's document
-- ---------------------------------------------------------------------------------------------

-- The customer items an estimate version gives a document: lines with the same customer item (else
-- their section's name) are one, at the sum of their selling-price shares. Nothing else.
create function private.estimate_customer_items(p_version uuid) returns table (name text, description text, price numeric, sort integer)
language sql stable security definer set search_path = '' as $$
  select g.name, nullif(string_agg(distinct g.description, E'\n'), ''), sum(g.price), min(g.sort)::integer
    from (select coalesce(l.customer_item, case l.section when 'labor' then 'Labor' when 'travel' then 'Travel' when 'equipment' then 'Equipment'
                  when 'disposal' then 'Disposal' when 'hauling' then 'Hauling and fill' when 'materials' then 'Materials and supplies'
                  when 'permits' then 'Permits and testing' when 'subcontractor' then 'Subcontracted work' when 'contingency' then 'Contingency' else 'Other' end) as name,
                 l.customer_description as description, coalesce(l.price, 0) as price, l.sort
            from public.estimate_lines l where l.version_id = p_version) g
   group by g.name
  having sum(g.price) <> 0
   order by min(g.sort)
$$;

-- The customer-facing scope an estimate version gives a proposal's narrative.
create function private.estimate_narrative(p_version uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'overview', nullif(btrim(coalesce(v.scope ->> 'customer_overview', '')), ''),
    'scope', nullif(btrim(coalesce(v.scope ->> 'customer_scope', '')), ''),
    'inclusions', nullif(btrim(coalesce(v.scope ->> 'customer_inclusions', '')), ''),
    'exclusions', nullif(btrim(coalesce(v.scope ->> 'customer_exclusions', '')), ''),
    'assumptions', nullif(btrim(coalesce(v.scope ->> 'customer_assumptions', '')), '')))
    from public.estimate_versions v where v.id = p_version
$$;

create function private.estimate_handoff_check(v public.estimate_versions) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.estimating_can(v.company_id, 'estimate') or ((select auth.uid()) is not null and not (private.has_role(v.company_id, '{owner,admin,office,estimator}') and private.has_perm(v.company_id, 'sales'))) then
    raise exception 'Making a customer document from an estimate needs the Estimating and Quotes and sales areas.' using errcode = '42501';
  end if;
  if v.revision = 0 or v.calc_status <> 'ok' then
    raise exception 'Save a complete estimate first (no line without a rate).' using errcode = '22023';
  end if;
  if v.status <> 'approved' and coalesce((select (c.settings -> 'estimating' ->> 'require_approval')::boolean from public.companies c where c.id = v.company_id), true) then
    raise exception 'This business requires an approved estimate before a customer document is made from it.' using errcode = '22023';
  end if;
end $$;

create function public.create_quote_from_estimate(p_version uuid, p_presentation text, p_request_key uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v public.estimate_versions; e public.estimates; v_quote uuid;
begin
  select * into v from public.estimate_versions where id = p_version;
  if not found then raise exception 'Estimate not found.' using errcode = 'P0002'; end if;
  perform private.estimate_handoff_check(v);
  if p_presentation = 'quote' then p_presentation := 'line_items'; end if;
  if p_presentation is null or p_presentation not in ('line_items', 'proposal') then
    raise exception 'Choose a line-item quote or a proposal.' using errcode = '22023';
  end if;
  if p_request_key is null then
    raise exception 'A new document needs its request key.' using errcode = '22023';
  end if;
  select id into v_quote from public.quotes where company_id = v.company_id and from_estimate_key = p_request_key;
  if v_quote is not null then return v_quote; end if;
  select * into e from public.estimates where id = v.estimate_id;
  if e.client_id is null then
    raise exception 'Give the estimate its customer first.' using errcode = '22023';
  end if;
  insert into public.quotes (company_id, client_id, property_id, request_id, title, presentation, narrative, estimate_version_id, from_estimate_key)
  values (v.company_id, e.client_id, e.property_id, e.request_id, e.title, p_presentation, private.estimate_narrative(p_version), p_version, p_request_key)
  on conflict (company_id, from_estimate_key) where from_estimate_key is not null do nothing
  returning id into v_quote;
  if v_quote is null then
    select id into v_quote from public.quotes where company_id = v.company_id and from_estimate_key = p_request_key;
    return v_quote;
  end if;
  insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price, sort)
  select v.company_id, v_quote, i.name, i.description, 1, 'job', i.price, row_number() over (order by i.sort)
    from private.estimate_customer_items(p_version) i;
  update public.estimate_summaries set updated_at = now() where estimate_id = v.estimate_id;
  return v_quote;
end $$;

-- What refreshing a document from an estimate version would change: its customer lines now and then.
create function public.estimate_quote_diff(p_quote uuid, p_version uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare q public.quotes; v public.estimate_versions;
begin
  select * into q from public.quotes where id = p_quote;
  select * into v from public.estimate_versions where id = p_version;
  if q.id is null or v.id is null or q.company_id <> v.company_id then
    raise exception 'Not found.' using errcode = 'P0002';
  end if;
  perform private.estimate_handoff_check(v);
  return jsonb_build_object(
    'quote_status', q.status,
    'from_version', (select number from public.estimate_versions where id = q.estimate_version_id),
    'to_version', v.number,
    'current', (select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'amount', round(l.quantity * l.unit_price, 2)) order by l.sort), '[]') from public.quote_line_items l where l.quote_id = q.id),
    'proposed', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'amount', i.price) order by i.sort), '[]') from private.estimate_customer_items(p_version) i),
    'current_subtotal', (select coalesce(sum(round(l.quantity * l.unit_price, 2)), 0) from public.quote_line_items l where l.quote_id = q.id and l.selected),
    'proposed_subtotal', (select coalesce(sum(i.price), 0) from private.estimate_customer_items(p_version) i));
end $$;

-- Brings an unsigned document's lines (and, if asked, its narrative) up to date with an estimate
-- version, on purpose. A sent one becomes a draft revision until it's sent again (Phase 1c).
create function public.refresh_quote_from_estimate(p_quote uuid, p_version uuid, p_narrative boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v public.estimate_versions;
begin
  select * into q from public.quotes where id = p_quote for update;
  select * into v from public.estimate_versions where id = p_version;
  if q.id is null or v.id is null or q.company_id <> v.company_id then
    raise exception 'Not found.' using errcode = 'P0002';
  end if;
  perform private.estimate_handoff_check(v);
  if q.status not in ('draft', 'sent', 'changes_requested') or q.is_template or q.change_order_for is not null then
    raise exception 'Only an unsigned quote or proposal can be refreshed from an estimate.' using errcode = '22023';
  end if;
  if q.estimate_version_id is not null and (select estimate_id from public.estimate_versions where id = q.estimate_version_id) <> v.estimate_id then
    raise exception 'That version is from another estimate.' using errcode = '22023';
  end if;
  delete from public.quote_line_items where quote_id = q.id;
  insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price, sort)
  select q.company_id, q.id, i.name, i.description, 1, 'job', i.price, row_number() over (order by i.sort)
    from private.estimate_customer_items(p_version) i;
  update public.quotes set estimate_version_id = p_version,
         narrative = case when p_narrative then private.estimate_narrative(p_version) else narrative end
   where id = q.id;
  update public.estimate_summaries set updated_at = now() where estimate_id = v.estimate_id;
  return public.estimate_quote_diff(q.id, p_version);
end $$;

-- ---------------------------------------------------------------------------------------------
-- The estimate's summary
-- ---------------------------------------------------------------------------------------------

-- The one internal Estimate Summary, as it is now: the estimate and its versions, customer, property,
-- request and its pipeline, scope, assumptions, files, the current version's lines (with their
-- costs, rate snapshots and the pricing only for estimate_costs), every version's dated figures, the
-- prices actually sent and accepted (apart from the calculated price), any job, and where its
-- permanent copy is to go. Private: the Estimating area, and costs for estimate_costs.
create function public.estimate_summary(p_estimate uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.estimates; v public.estimate_versions; v_costs boolean; s public.estimate_summaries;
begin
  select * into e from public.estimates where id = p_estimate;
  if not found or not private.estimating_can(e.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
  end if;
  v_costs := private.estimating_can(e.company_id, 'estimate_costs');
  select * into v from public.estimate_versions where id = e.current_version_id;
  select * into s from public.estimate_summaries where estimate_id = e.id;
  return jsonb_build_object(
    'summary', jsonb_build_object('id', s.id, 'title', s.title, 'updated_at', s.updated_at, 'drive_destination', s.drive_destination, 'job_id', s.job_id, 'drive_status', s.drive_status),
    'costs_visible', v_costs,
    'estimate', jsonb_build_object('id', e.id, 'number', e.number, 'title', e.title, 'project_type', e.project_type, 'created_at', e.created_at, 'updated_at', e.updated_at,
      'estimator', (select p.full_name from public.profiles p where p.user_id = e.estimator_id), 'baseline_version_id', e.baseline_version_id, 'current_version_id', e.current_version_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.display_name, 'email', c.email, 'phone', c.phone) from public.clients c where c.id = e.client_id),
    'property', (select jsonb_build_object('id', p.id, 'line1', p.line1, 'city', p.city, 'region', p.region, 'postal_code', p.postal_code) from public.properties p where p.id = e.property_id),
    'request', (select jsonb_build_object('id', r.id, 'number', r.number, 'title', r.title, 'status', r.status, 'stage', st.label, 'stage_kind', st.kind,
                  'outcome_reason', r.outcome_reason, 'outcome_at', r.outcome_at, 'last_contact_at', r.last_contact_at, 'next_action', r.next_action, 'next_action_on', r.next_action_on,
                  'next_follow_up', (select jsonb_build_object('title', t.title, 'due_on', t.due_on) from public.follow_up_tasks t where t.related_type = 'request' and t.related_id = r.id and t.done_at is null order by t.due_on nulls last limit 1))
                from public.requests r left join public.pipeline_stages st on st.id = r.stage_id where r.id = e.request_id),
    'version', jsonb_build_object('id', v.id, 'number', v.number, 'status', v.status, 'saved_at', v.saved_at, 'approved_at', v.approved_at, 'calc_status', v.calc_status,
      'scope', v.scope, 'assumptions', v.assumptions, 'pricing_method', v.pricing_method, 'owner_pay_method', v.owner_pay_method,
      'pricing_pct', case when v_costs then v.pricing_pct end, 'owner_pct', case when v_costs then v.owner_pct end, 'burden_pct', case when v_costs then v.burden_pct end,
      'totals', case when v_costs then jsonb_build_object('base_cost', v.base_cost, 'risk_reserve', v.risk_reserve, 'subtotal', v.subtotal, 'markup_amount', v.markup_amount,
                  'price_before_owner_pay', v.price_before_owner_pay, 'owner_pay', v.owner_pay, 'selling_price', v.selling_price) end,
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('section', l.section, 'name', l.name, 'customer_item', l.customer_item, 'count', l.count, 'hours', l.hours, 'days', l.days,
                  'unit', l.unit, 'risk_pct', l.risk_pct, 'material_stream', l.material_stream, 'facility', l.facility, 'est_tons', l.est_tons, 'est_loose_cy', l.est_loose_cy,
                  'container_cy', l.container_cy, 'expected_loads', l.expected_loads, 'notes', l.notes)
                  || case when v_costs then jsonb_build_object('unit_cost', l.unit_cost, 'rate', l.rate_snapshot, 'base', l.base, 'risk', l.risk, 'subtotal', l.subtotal, 'price', l.price) else '{}' end
                  order by l.sort), '[]') from public.estimate_lines l where l.version_id = v.id)),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('number', x.number, 'status', x.status, 'created_at', x.created_at, 'saved_at', x.saved_at, 'approved_at', x.approved_at,
                  'baseline', x.id = e.baseline_version_id, 'revision_reason', x.revision_reason)
                  || case when v_costs then jsonb_build_object('base_cost', x.base_cost, 'subtotal', x.subtotal, 'selling_price', x.selling_price) else '{}' end order by x.number), '[]')
                 from public.estimate_versions x where x.estimate_id = e.id),
    -- What the customer was actually sent and what they accepted: the documents' own figures.
    'documents', (select coalesce(jsonb_agg(jsonb_build_object('quote_id', q.id, 'number', q.number, 'presentation', q.presentation, 'status', q.status,
                  'from_version', (select number from public.estimate_versions where id = q.estimate_version_id),
                  'sent', (select coalesce(jsonb_agg(jsonb_build_object('version', qv.number, 'total', qv.total, 'issued_at', qv.issued_at,
                             'estimate_version', (select number from public.estimate_versions where id = qv.estimate_version_id)) order by qv.number), '[]')
                           from public.quote_versions qv where qv.quote_id = q.id),
                  'accepted', case when q.status in ('approved', 'converted') then jsonb_build_object('total', coalesce((q.approval -> 'choices' ->> 'total')::numeric, (q.approval ->> 'total')::numeric, q.total),
                             'signed_at', q.approval ->> 'signed_at', 'version', (q.approval ->> 'version_number')::int) end) order by q.created_at), '[]')
                  from public.quotes q where q.company_id = e.company_id and q.estimate_version_id in (select id from public.estimate_versions where estimate_id = e.id)),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'number', j.number, 'title', j.title, 'estimate_version', (select number from public.estimate_versions where id = j.estimate_version_id)) order by j.created_at), '[]')
             from public.jobs j where j.company_id = e.company_id and j.estimate_version_id in (select id from public.estimate_versions where estimate_id = e.id))
  );
end $$;

revoke execute on function private.quote_estimate_link_stays(), private.quote_version_estimate(), private.job_estimate_version_stays(), private.estimate_summary_job(),
  private.estimate_customer_items(uuid), private.estimate_narrative(uuid), private.estimate_handoff_check(public.estimate_versions) from public;
revoke execute on function public.create_quote_from_estimate(uuid, text, uuid), public.estimate_quote_diff(uuid, uuid), public.refresh_quote_from_estimate(uuid, uuid, boolean),
  public.estimate_summary(uuid) from public, anon;
grant execute on function public.create_quote_from_estimate(uuid, text, uuid), public.estimate_quote_diff(uuid, uuid), public.refresh_quote_from_estimate(uuid, uuid, boolean),
  public.estimate_summary(uuid) to authenticated;

notify pgrst, 'reload schema';
