-- Planet Ops Phase 3 hardening (after 20261125000100_planet_ops_estimate_handoff.sql).
--
-- 1. The estimate behind every customer document is kept exactly as it was used. Before this, with
--    "require approval" off, a document could be made from a saved draft version, and that draft
--    stayed editable: the document, its issued versions and the job all pointed at a version whose
--    scope, quantities, rates and prices could still change. Now making or refreshing a document
--    from a draft *locks* that version (status 'locked', with when and by whom): it can't be saved
--    again, and later changes are a revision, as for an approved version. Locking isn't approval:
--    no approver or approval time is recorded; a locked version can still be approved later, as it
--    is. Versions already used by a document are locked by this migration.
-- 2. No mixed or unreviewed snapshots: making a document locks the version row first (a save waits,
--    or is refused once it's locked) and, from a draft, carries the revision the person was looking
--    at; approving carries the revision the approver reviewed; refreshing carries the token of the
--    differences the person was shown, and is refused if the document or the version has changed
--    since. A retried "create" with the same key but another version, document type or estimate is
--    refused instead of silently returning a different record.
-- 3. A preparer without "See estimating costs" can't move hidden pricing through the save payload:
--    a line's risk % and "rate includes burden" stay as they were (new lines: the estimate's default
--    risk and the rate's own flag), a line's carried cost stays with the same line in the same
--    section, and a newly picked rate must be in effect today. Errors from a save don't echo the
--    row (a constraint's "failing row" would show its costs).
-- 4. Links stay consistent: an estimate's property is its customer's, its customer is its request's,
--    its estimator is on the team; a document is refreshed only from an estimate for its customer.

-- ---------------------------------------------------------------------------------------------
-- 1. Locked versions
-- ---------------------------------------------------------------------------------------------

alter table public.estimate_versions drop constraint estimate_versions_status_check;
alter table public.estimate_versions add constraint estimate_versions_status_check check (status in ('draft', 'locked', 'approved'));
alter table public.estimate_versions add column locked_at timestamptz;
alter table public.estimate_versions add column locked_by uuid references auth.users (id) on delete set null;
alter table public.estimate_versions add constraint estimate_versions_locked_check
  check ((status <> 'draft' or locked_at is null) and (status <> 'locked' or locked_at is not null));
comment on column public.estimate_versions.locked_at is 'Planet Ops: when this version was locked because a customer document was made or refreshed from it without approval. Locking is not approval.';
grant select (locked_at, locked_by) on public.estimate_versions to authenticated;
comment on table public.estimate_versions is 'Planet Ops: each version of an internal estimate: a draft; locked once a customer document uses it; approved and frozen. The first approved one is the estimate''s original baseline.';

-- Approved and locked versions are kept; a locked one may only become approved, unchanged.
create or replace function private.estimate_version_stays() returns trigger
language plpgsql set search_path = '' as $$
declare v_fields text[] := array['status', 'approved_by', 'approved_at', 'approval_note'];
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'An estimate''s versions are kept.' using errcode = '22023';
  end if;
  if old.status = 'approved' then
    raise exception 'An approved estimate version is frozen. Make a revision to change it.' using errcode = '22023';
  end if;
  if old.status = 'locked' then
    if new.status = 'approved' and (to_jsonb(new) - v_fields) = (to_jsonb(old) - v_fields) then return new; end if;
    raise exception 'This estimate version was used for a customer document and is kept as it was. Make a revision to change it.' using errcode = '22023';
  end if;
  return new;
end $$;

create or replace function private.estimate_line_stays() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 and not exists (select 1 from public.estimate_versions where id = old.version_id) then return old; end if;
  select status into v_status from public.estimate_versions where id = coalesce(new.version_id, old.version_id);
  if v_status = 'approved' then
    raise exception 'An approved estimate version is frozen. Make a revision to change it.' using errcode = '22023';
  end if;
  if v_status = 'locked' then
    raise exception 'This estimate version was used for a customer document and is kept as it was. Make a revision to change it.' using errcode = '22023';
  end if;
  return coalesce(new, old);
end $$;

-- Versions a document, an issued version or a job already uses are locked as they are now.
update public.estimate_versions set status = 'locked', locked_at = now()
 where status = 'draft'
   and (id in (select estimate_version_id from public.quotes where estimate_version_id is not null)
        or id in (select estimate_version_id from public.quote_versions where estimate_version_id is not null)
        or id in (select estimate_version_id from public.jobs where estimate_version_id is not null));

create function private.lock_estimate_version(p_version uuid) returns void
language sql security definer set search_path = '' as $$
  update public.estimate_versions set status = 'locked', locked_at = now(), locked_by = (select auth.uid())
   where id = p_version and status = 'draft';
$$;

-- ---------------------------------------------------------------------------------------------
-- 2 and 4. Creating and saving estimates
-- ---------------------------------------------------------------------------------------------

-- The customer, property, request and estimator of an estimate belong together.
create function private.estimate_links_check(p_company uuid, p_request uuid, p_client uuid, p_property uuid, p_estimator uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
declare v_request_client uuid;
begin
  if p_client is not null and not exists (select 1 from public.clients c where c.id = p_client and c.company_id = p_company) then
    raise exception 'That customer isn''t one of this business''s.' using errcode = '22023';
  end if;
  if p_request is not null then
    select r.client_id into v_request_client from public.requests r where r.id = p_request and r.company_id = p_company;
    if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
    if v_request_client is not null and p_client is distinct from v_request_client then
      raise exception 'The estimate''s customer is its request''s. Change the request''s customer first.' using errcode = '22023';
    end if;
  end if;
  if p_property is not null and not exists (select 1 from public.properties p where p.id = p_property and p.company_id = p_company and p.client_id is not distinct from p_client) then
    raise exception 'That property isn''t the estimate''s customer''s.' using errcode = '22023';
  end if;
  if p_estimator is not null and not exists (select 1 from public.memberships m where m.company_id = p_company and m.user_id = p_estimator and m.active) then
    raise exception 'The estimator must be on the team.' using errcode = '22023';
  end if;
end $$;

-- As in 20261124000100, and: a retried key opens its estimate only for the same request, customer and
-- property; the links are checked.
create or replace function public.create_estimate(p_company uuid, p_request_key uuid, p_title text, p_request uuid default null,
  p_client uuid default null, p_property uuid default null, p_project_type text default null, p_estimator uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_version uuid; v_number integer; r public.requests; e public.estimates;
begin
  if not private.estimating_can(p_company, 'estimate') then
    raise exception 'Estimating needs the Estimating area.' using errcode = '42501';
  end if;
  if p_request_key is null then
    raise exception 'A new estimate needs its request key.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('estimate_number:' || p_company, 0));
  select * into e from public.estimates where company_id = p_company and request_key = p_request_key;
  if e.id is not null then
    if (p_request is not null and p_request is distinct from e.request_id) or (p_client is not null and p_client is distinct from e.client_id)
       or (p_property is not null and p_property is distinct from e.property_id) then
      raise exception 'This request key was already used for a different estimate.' using errcode = '22023';
    end if;
    return e.id;
  end if;
  if p_request is not null then
    select * into r from public.requests where id = p_request and company_id = p_company;
    if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
  end if;
  perform private.estimate_links_check(p_company, p_request, coalesce(p_client, r.client_id), coalesce(p_property, r.property_id), p_estimator);
  select coalesce(max(number), 0) + 1 into v_number from public.estimates where company_id = p_company;
  insert into public.estimates (company_id, number, request_id, client_id, property_id, title, project_type, estimator_id, request_key)
  values (p_company, v_number, p_request, coalesce(p_client, r.client_id), coalesce(p_property, r.property_id),
          coalesce(nullif(btrim(coalesce(p_title, '')), ''), r.title, 'Estimate ' || v_number), nullif(btrim(coalesce(p_project_type, '')), ''),
          coalesce(p_estimator, r.estimator_id, (select auth.uid())), p_request_key)
  returning id into v_id;
  insert into public.estimate_versions (company_id, estimate_id, number) values (p_company, v_id, 1) returning id into v_version;
  update public.estimates set current_version_id = v_version where id = v_id;
  perform private.estimate_totals(v_version);
  insert into public.estimate_summaries (company_id, estimate_id, title) values (p_company, v_id, private.estimate_summary_title(v_id));
  return v_id;
end $$;

-- As in 20261124000100, and: a locked version can't be saved; someone without costs can't change a
-- line's risk %, "includes burden", or carry a cost into another section, and picks only rates in
-- effect today; the links are checked; a refused value is named without echoing the row.
create or replace function public.save_estimate_version(p_version uuid, p_expected_revision integer, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v public.estimate_versions;
  e public.estimates;
  v_costs boolean;
  v_line jsonb;
  v_old public.estimate_lines;
  v_rate public.estimate_rates;
  v_sort integer := 0;
  v_cost numeric;
  v_snapshot jsonb;
  v_today date;
  v_rate_id uuid;
  v_client uuid; v_property uuid; v_estimator uuid;
begin
  select * into v from public.estimate_versions where id = p_version for update;
  if not found or not private.estimating_can(v.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
  end if;
  if v.status = 'locked' then
    raise exception 'This estimate version was used for a customer document and is kept as it was. Make a revision to change it.' using errcode = '22023';
  end if;
  if v.status <> 'draft' then
    raise exception 'An approved estimate version is frozen. Make a revision to change it.' using errcode = '22023';
  end if;
  if p_expected_revision is distinct from v.revision then
    raise exception 'Someone else saved this estimate since you opened it. Reload it to see their changes, then make yours.' using errcode = '40001';
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' or jsonb_typeof(coalesce(p_payload -> 'lines', '[]')) <> 'array' then
    raise exception 'The estimate to save isn''t in the expected shape.' using errcode = '22023';
  end if;
  v_costs := private.estimating_can(v.company_id, 'estimate_costs');
  if not v_costs and (p_payload ? 'pricing_pct' or p_payload ? 'owner_pct' or p_payload ? 'burden_pct' or p_payload ? 'pricing_method' or p_payload ? 'owner_pay_method' or p_payload ? 'default_risk_pct') then
    raise exception 'Pricing needs the Estimating costs area.' using errcode = '42501';
  end if;
  select * into e from public.estimates where id = v.estimate_id for update;
  v_client := case when p_payload ? 'client_id' then nullif(p_payload ->> 'client_id', '')::uuid else e.client_id end;
  v_property := case when p_payload ? 'property_id' then nullif(p_payload ->> 'property_id', '')::uuid else e.property_id end;
  v_estimator := case when p_payload ? 'estimator_id' then nullif(p_payload ->> 'estimator_id', '')::uuid else e.estimator_id end;
  perform private.estimate_links_check(v.company_id, e.request_id, v_client, v_property, v_estimator);
  v_today := private.company_today(v.company_id);

  -- The lines kept by id: their old rate snapshot and cost go with them.
  create temporary table if not exists pg_temp.estimate_old_lines on commit drop as select * from public.estimate_lines limit 0;
  delete from pg_temp.estimate_old_lines where true;  -- hosted Supabase refuses a DELETE without WHERE (pg-safeupdate)
  insert into pg_temp.estimate_old_lines select * from public.estimate_lines where version_id = p_version;
  delete from public.estimate_lines where version_id = p_version;

  for v_line in select * from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]')) loop
    v_sort := v_sort + 1;
    if jsonb_typeof(v_line) is distinct from 'object' then
      raise exception 'Line % isn''t in the expected shape.', v_sort using errcode = '22023';
    end if;
    v_old := null;
    begin
      v_rate_id := nullif(v_line ->> 'rate_id', '')::uuid;
      if v_line ? 'id' then
        select * into v_old from pg_temp.estimate_old_lines where id = (v_line ->> 'id')::uuid;
        -- Someone without costs keeps a line's cost only on that same line in the same section.
        if not v_costs and v_old.id is not null and v_old.section is distinct from (v_line ->> 'section') then v_old := null; end if;
      end if;
    exception when invalid_text_representation then
      raise exception 'Line % has an id or rate that isn''t valid.', v_sort using errcode = '22023';
    end;
    v_rate := null;
    v_snapshot := null;
    if v_rate_id is not null then
      if v_old.id is not null and v_old.rate_id = v_rate_id then
        v_snapshot := v_old.rate_snapshot;  -- kept: a rate change since doesn't move this estimate
      else
        select * into v_rate from public.estimate_rates where id = v_rate_id and company_id = v.company_id;
        if not found then raise exception 'That rate isn''t one of this business''s.' using errcode = '22023'; end if;
        if not v_costs and not (v_rate.effective_from <= v_today and (v_rate.effective_to is null or v_rate.effective_to >= v_today)) then
          raise exception 'Line %: that rate isn''t in effect today. Pick one from the current rates.', v_sort using errcode = '22023';
        end if;
        v_snapshot := jsonb_build_object('rate_id', v_rate.id, 'code', v_rate.code, 'name', v_rate.name, 'unit', v_rate.unit, 'unit_cost', v_rate.unit_cost,
                                         'includes_burden', v_rate.includes_burden, 'includes_fuel', v_rate.includes_fuel, 'owned', v_rate.owned,
                                         'effective_from', v_rate.effective_from, 'effective_to', v_rate.effective_to, 'taken_at', now());
      end if;
    end if;
    begin
      -- The cost: as typed (by someone who sees costs), else the line's own, else its rate's.
      v_cost := case
        when v_costs and v_line ? 'unit_cost' then nullif(v_line ->> 'unit_cost', '')::numeric
        when v_old.id is not null and (v_old.rate_id is not distinct from v_rate_id) then v_old.unit_cost
        when v_snapshot is not null then (v_snapshot ->> 'unit_cost')::numeric
      end;
      insert into public.estimate_lines (company_id, version_id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit,
        unit_cost, rate_id, rate_snapshot, risk_pct, role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility,
        est_tons, est_loose_cy, container_cy, expected_loads, notes)
      values (v.company_id, p_version, v_sort, nullif(v_line ->> 'key', ''), v_line ->> 'section', btrim(coalesce(v_line ->> 'name', '')),
        nullif(btrim(coalesce(v_line ->> 'customer_item', '')), ''), nullif(btrim(coalesce(v_line ->> 'customer_description', '')), ''),
        nullif(v_line ->> 'count', '')::numeric, nullif(v_line ->> 'hours', '')::numeric, nullif(v_line ->> 'days', '')::numeric,
        coalesce(nullif(v_line ->> 'unit', ''), v_snapshot ->> 'unit', 'each'), v_cost, v_rate_id, v_snapshot,
        case when v_costs then coalesce(nullif(v_line ->> 'risk_pct', '')::numeric, v.default_risk_pct, 0)
             when v_old.id is not null then v_old.risk_pct
             else coalesce(v.default_risk_pct, 0) end,
        nullif(v_line ->> 'role', ''), coalesce((v_line ->> 'overtime')::boolean, false),
        case when v_costs then coalesce((v_line ->> 'includes_burden')::boolean, (v_snapshot ->> 'includes_burden')::boolean, false)
             when v_old.id is not null and v_old.rate_id is not distinct from v_rate_id then v_old.includes_burden
             else coalesce((v_snapshot ->> 'includes_burden')::boolean, false) end,
        coalesce((v_line ->> 'includes_fuel')::boolean, (v_snapshot ->> 'includes_fuel')::boolean, false),
        coalesce((v_line ->> 'owned')::boolean, (v_snapshot ->> 'owned')::boolean), nullif(v_line ->> 'fuel_for', ''),
        nullif(v_line ->> 'material_stream', ''), nullif(v_line ->> 'facility', ''), nullif(v_line ->> 'est_tons', '')::numeric,
        nullif(v_line ->> 'est_loose_cy', '')::numeric, nullif(v_line ->> 'container_cy', '')::numeric, nullif(v_line ->> 'expected_loads', '')::numeric,
        nullif(v_line ->> 'notes', ''));
    exception
      when check_violation or not_null_violation then
        raise exception 'Line % has a value that isn''t allowed: it needs a name, a section and a unit the estimate knows; counts, hours, days, weights and volumes can''t be negative; only an "Other" line can be a credit.', v_sort using errcode = '22023';
      when invalid_text_representation or numeric_value_out_of_range or datatype_mismatch then
        raise exception 'Line % has a number or a yes/no that isn''t valid.', v_sort using errcode = '22023';
    end;
  end loop;

  begin
    update public.estimate_versions set
      scope = case when p_payload ? 'scope' then p_payload -> 'scope' else scope end,
      assumptions = case when p_payload ? 'assumptions' then p_payload -> 'assumptions' else assumptions end,
      pricing_method = case when p_payload ? 'pricing_method' then p_payload ->> 'pricing_method' else pricing_method end,
      pricing_pct = case when p_payload ? 'pricing_pct' then nullif(p_payload ->> 'pricing_pct', '')::numeric else pricing_pct end,
      owner_pay_method = case when p_payload ? 'owner_pay_method' then p_payload ->> 'owner_pay_method' else owner_pay_method end,
      owner_pct = case when p_payload ? 'owner_pct' then nullif(p_payload ->> 'owner_pct', '')::numeric else owner_pct end,
      burden_pct = case when p_payload ? 'burden_pct' then nullif(p_payload ->> 'burden_pct', '')::numeric else burden_pct end,
      default_risk_pct = case when p_payload ? 'default_risk_pct' then nullif(p_payload ->> 'default_risk_pct', '')::numeric else default_risk_pct end,
      revision = revision + 1, saved_by = (select auth.uid()), saved_at = now()
    where id = p_version;
  exception
    when check_violation then
      raise exception 'A pricing setting isn''t allowed: percentages can''t be negative, a target margin is under 100%%, owner pay is under 100%%, burden and risk under 500%%; the project details and assumptions have a size limit.' using errcode = '22023';
    when invalid_text_representation or numeric_value_out_of_range or datatype_mismatch then
      raise exception 'A pricing setting has a number that isn''t valid.' using errcode = '22023';
  end;
  perform private.estimate_totals(p_version);
  begin
    update public.estimates set
      title = coalesce(nullif(btrim(coalesce(p_payload ->> 'title', '')), ''), title),
      project_type = case when p_payload ? 'project_type' then nullif(btrim(coalesce(p_payload ->> 'project_type', '')), '') else project_type end,
      estimator_id = v_estimator, client_id = v_client, property_id = v_property,
      current_version_id = p_version, updated_at = now()
    where id = v.estimate_id;
  exception when check_violation then
    raise exception 'The title is 1 to 200 characters and the project type up to 120.' using errcode = '22023';
  end;
  update public.estimate_summaries set title = private.estimate_summary_title(v.estimate_id), updated_at = now() where estimate_id = v.estimate_id;
  return (select jsonb_build_object('revision', revision, 'calc_status', calc_status, 'calc_problems', calc_problems) from public.estimate_versions where id = p_version);
end $$;

-- Approves the version the approver reviewed (the revision they were shown): frozen from now on.
-- A locked version (used for a document) is approved as it is.
drop function public.approve_estimate_version(uuid, text);
create function public.approve_estimate_version(p_version uuid, p_expected_revision integer default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.estimate_versions; v_baseline boolean;
begin
  select * into v from public.estimate_versions where id = p_version for update;
  if not found or not private.estimating_can(v.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
  end if;
  if not private.estimating_can(v.company_id, 'estimate_approve') then
    raise exception 'Approving an estimate needs the Approve estimates area.' using errcode = '42501';
  end if;
  if v.status = 'approved' then
    return jsonb_build_object('status', 'approved', 'baseline', (select baseline_version_id = v.id from public.estimates where id = v.estimate_id));
  end if;
  if ((select auth.uid()) is not null or p_expected_revision is not null) and p_expected_revision is distinct from v.revision then
    raise exception 'This estimate was saved again since you opened it. Reload it and review the changes before approving.' using errcode = '40001';
  end if;
  if v.status = 'draft' then
    perform private.estimate_totals(p_version);
    select * into v from public.estimate_versions where id = p_version;
  end if;
  if v.calc_status <> 'ok' then
    raise exception 'This estimate can''t be approved yet: %', (select string_agg(p ->> 'message', '; ') from jsonb_array_elements(v.calc_problems) p) using errcode = '22023';
  end if;
  if v.revision = 0 then
    raise exception 'Save the estimate before approving it.' using errcode = '22023';
  end if;
  update public.estimate_versions set status = 'approved', approved_by = (select auth.uid()), approved_at = now(), approval_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_version;
  update public.estimates set baseline_version_id = coalesce(baseline_version_id, p_version), updated_at = now()
   where id = v.estimate_id returning baseline_version_id = p_version into v_baseline;
  update public.estimate_summaries set updated_at = now() where estimate_id = v.estimate_id;
  return jsonb_build_object('status', 'approved', 'baseline', v_baseline);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Creating and refreshing documents
-- ---------------------------------------------------------------------------------------------

-- As in 20261125000100, and: the version is locked while it's read (no mixed snapshot), a draft must
-- be the revision the person saw and is locked by being used, and a retried key must ask for the same
-- document.
drop function public.create_quote_from_estimate(uuid, text, uuid);
create function public.create_quote_from_estimate(p_version uuid, p_presentation text, p_request_key uuid, p_expected_revision integer default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v public.estimate_versions; e public.estimates; q public.quotes; v_quote uuid;
begin
  if p_presentation = 'quote' then p_presentation := 'line_items'; end if;
  if p_presentation is null or p_presentation not in ('line_items', 'proposal') then
    raise exception 'Choose a line-item quote or a proposal.' using errcode = '22023';
  end if;
  if p_request_key is null then
    raise exception 'A new document needs its request key.' using errcode = '22023';
  end if;
  -- Locked first: a save in progress finishes before this reads, and none can start after.
  select * into v from public.estimate_versions where id = p_version for update;
  if not found then raise exception 'Estimate not found.' using errcode = 'P0002'; end if;
  perform private.estimate_handoff_check(v);
  select * into q from public.quotes where company_id = v.company_id and from_estimate_key = p_request_key;
  if q.id is not null then
    if q.estimate_version_id is distinct from p_version or q.presentation is distinct from p_presentation then
      raise exception 'This request was already used to make a different document. Start again from the estimate.' using errcode = '22023';
    end if;
    return q.id;
  end if;
  if v.status = 'draft' and ((select auth.uid()) is not null or p_expected_revision is not null) and p_expected_revision is distinct from v.revision then
    raise exception 'This estimate was saved again since you opened it. Reload it and review it before making a document from it.' using errcode = '40001';
  end if;
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
  perform private.lock_estimate_version(p_version);
  update public.estimate_summaries set updated_at = now() where estimate_id = v.estimate_id;
  return v_quote;
end $$;

-- A token for what a refresh would replace: the document's lines and narrative, its estimate link,
-- and the version's content (its revision).
create function private.estimate_refresh_token(p_quote uuid, p_version uuid) returns text
language sql stable security definer set search_path = '' as $$
  select md5(jsonb_build_object(
    'lines', (select coalesce(jsonb_agg(jsonb_build_array(l.id, l.name, l.description, l.quantity, l.unit_price, l.selected) order by l.sort, l.id), '[]') from public.quote_line_items l where l.quote_id = p_quote),
    'narrative', (select q.narrative from public.quotes q where q.id = p_quote),
    'link', (select q.estimate_version_id from public.quotes q where q.id = p_quote),
    'version', p_version,
    'revision', (select v.revision from public.estimate_versions v where v.id = p_version))::text)
$$;

-- As in 20261125000100, with the version's status and the token a refresh must carry.
create or replace function public.estimate_quote_diff(p_quote uuid, p_version uuid) returns jsonb
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
    'to_status', v.status,
    'token', private.estimate_refresh_token(q.id, v.id),
    'current', (select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'amount', round(l.quantity * l.unit_price, 2)) order by l.sort), '[]') from public.quote_line_items l where l.quote_id = q.id),
    'proposed', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'amount', i.price) order by i.sort), '[]') from private.estimate_customer_items(p_version) i),
    'current_subtotal', (select coalesce(sum(round(l.quantity * l.unit_price, 2)), 0) from public.quote_line_items l where l.quote_id = q.id and l.selected),
    'proposed_subtotal', (select coalesce(sum(i.price), 0) from private.estimate_customer_items(p_version) i));
end $$;

-- As in 20261125000100, and: only with the token of the differences the person reviewed (refused if
-- the document or the version changed since), only from an estimate for the document's customer, and
-- a draft version used this way is locked.
drop function public.refresh_quote_from_estimate(uuid, uuid, boolean);
create function public.refresh_quote_from_estimate(p_quote uuid, p_version uuid, p_narrative boolean default false, p_expected text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v public.estimate_versions; e public.estimates;
begin
  select * into q from public.quotes where id = p_quote for update;
  select * into v from public.estimate_versions where id = p_version for update;
  if q.id is null or v.id is null or q.company_id <> v.company_id then
    raise exception 'Not found.' using errcode = 'P0002';
  end if;
  perform private.estimate_handoff_check(v);
  if q.status not in ('draft', 'sent', 'changes_requested') or q.is_template or q.change_order_for is not null then
    raise exception 'Only an unsigned quote or proposal can be refreshed from an estimate.' using errcode = '22023';
  end if;
  select * into e from public.estimates where id = v.estimate_id;
  if q.estimate_version_id is not null and (select estimate_id from public.estimate_versions where id = q.estimate_version_id) <> v.estimate_id then
    raise exception 'That version is from another estimate.' using errcode = '22023';
  end if;
  if e.client_id is distinct from q.client_id then
    raise exception 'That estimate is for another customer.' using errcode = '22023';
  end if;
  if ((select auth.uid()) is not null or p_expected is not null) and p_expected is distinct from private.estimate_refresh_token(q.id, v.id) then
    raise exception 'The document or the estimate changed since you reviewed the differences. Review them again before refreshing.' using errcode = '40001';
  end if;
  delete from public.quote_line_items where quote_id = q.id;
  insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price, sort)
  select q.company_id, q.id, i.name, i.description, 1, 'job', i.price, row_number() over (order by i.sort)
    from private.estimate_customer_items(p_version) i;
  update public.quotes set estimate_version_id = p_version,
         narrative = case when p_narrative then private.estimate_narrative(p_version) else narrative end
   where id = q.id;
  perform private.lock_estimate_version(p_version);
  update public.estimate_summaries set updated_at = now() where estimate_id = v.estimate_id;
  return public.estimate_quote_diff(q.id, p_version);
end $$;

revoke execute on function private.lock_estimate_version(uuid), private.estimate_links_check(uuid, uuid, uuid, uuid, uuid),
  private.estimate_refresh_token(uuid, uuid) from public;
revoke execute on function public.approve_estimate_version(uuid, integer, text), public.create_quote_from_estimate(uuid, text, uuid, integer),
  public.refresh_quote_from_estimate(uuid, uuid, boolean, text) from public, anon;
grant execute on function public.approve_estimate_version(uuid, integer, text), public.create_quote_from_estimate(uuid, text, uuid, integer),
  public.refresh_quote_from_estimate(uuid, uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
