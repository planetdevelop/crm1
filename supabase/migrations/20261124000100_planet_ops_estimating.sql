-- Planet Ops Phase 3: the internal demolition estimate (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §5,
-- docs/planet-ops/ESTIMATING_MAPPING.md). Estimating is the business's own calculator; Quotes &
-- Proposals are the customer's documents. Separate records, separate versions.
--
-- 1. Areas: estimate ("Prepare internal estimates"), estimate_costs ("See estimating costs, rates and
--    profit") and estimate_approve ("Approve estimates"), apart from sales and send_pricing. Owners
--    and admins have all three; office and estimators prepare and see costs; approving is owners' and
--    admins' unless a custom role is given it. Existing custom roles that sell prepare and see costs.
-- 2. public.estimate_rates: the business's rates, each with a unit, cost and the day it takes effect.
--    A new cost is a new row from its day (the earlier one ends the day before): changing a rate never
--    changes an estimate, which keeps a snapshot of each rate it used.
-- 3. public.estimates (one per estimate, stable), public.estimate_versions (each saved version: a
--    draft, then approved and frozen; the first approved is the original baseline, later approved
--    ones are revisions) and public.estimate_lines (labor, travel, equipment, disposal, hauling,
--    materials, permits, subcontractors, other, contingency; count × hours × days × unit cost, with a
--    risk %). Totals are the database's: private.estimate_totals, the bid workbook's order with exact
--    numerics (the same as packages/core/src/estimating.ts). A save carries the revision it was made
--    from, so two people saving at once never lose each other's changes.
-- 4. Costs are private: the tables hold costs in columns that aren't granted to anyone signed in;
--    public.estimate_version_costs, public.estimate_rate_list and public.estimate_summary return them
--    only to people with estimate_costs. Someone who only prepares sees the scope, quantities and
--    rates' names, never a cost or a profit. No customer, link or document page ever reads these.
-- 5. public.estimate_summaries: one internal summary per estimate, made with it and kept current
--    (public.estimate_summary renders it), with where its permanent copy is to go once Drive backup
--    exists (Phase 4): Jobs Bid before a job, the job's folder after. Nothing is backed up yet.
-- Writes go through the functions below (security definer, each checking who may); nothing here
-- sends a customer anything, makes a job, or makes a folder.

-- ---------------------------------------------------------------------------------------------
-- 1. Areas
-- ---------------------------------------------------------------------------------------------

-- As in 20261121000200, with estimate, estimate_costs, estimate_approve (mirrors packages/core/src/roles.ts).
create or replace function private.level_permissions(p_level public.member_role) returns text[]
language sql immutable parallel safe set search_path = '' as $$
  select case p_level
    when 'owner' then array['sales','send_pricing','estimate','estimate_costs','estimate_approve','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','apps','equipment','subs','hiring']
    when 'admin' then array['sales','send_pricing','estimate','estimate_costs','estimate_approve','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','apps','equipment','subs','hiring']
    when 'office' then array['sales','send_pricing','estimate','estimate_costs','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','equipment','subs','hiring']
    when 'estimator' then array['sales','send_pricing','estimate','estimate_costs','schedule','equipment']
    when 'crew_lead' then array['schedule','timesheets','equipment']
    else array[]::text[]
  end
$$;

-- Custom roles that sell can prepare estimates and see their costs (approving is given by hand).
update public.company_roles set permissions = permissions || array['estimate', 'estimate_costs']
 where 'sales' = any (permissions) and not ('estimate' = any (permissions)) and base_role in ('admin', 'office', 'estimator');
update public.company_roles set permissions = permissions || array['estimate_approve']
 where base_role = 'admin' and 'sales' = any (permissions) and not ('estimate_approve' = any (permissions));

-- As in 20261121000200, with the estimating areas.
create or replace function private.install_default_roles(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.company_roles (company_id, name, description, base_role, permissions) values
    (p_company, 'General manager', 'Runs the business day to day.', 'admin',
     array['sales','send_pricing','estimate','estimate_costs','estimate_approve','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','equipment','subs','hiring']),
    (p_company, 'Office manager', 'Books work, schedules crews, sends quotes and invoices, and approves time.', 'office',
     array['sales','send_pricing','estimate','estimate_costs','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','equipment','subs','hiring']),
    (p_company, 'Operations manager', 'Schedules crews and keeps jobs on track.', 'office',
     array['sales','send_pricing','estimate','estimate_costs','job_costs','reports','schedule','timesheets','kb_edit','equipment','subs']),
    (p_company, 'Foreman', 'Runs their crew: schedules its visits, assigns its people and sees its time. No prices.', 'crew_lead', array['equipment']),
    (p_company, 'Employee', 'Works their own visits.', 'field_crew', array[]::text[])
  on conflict do nothing
$$;

-- Who may do what with estimates (the server, with nobody signed in, may do everything).
create function private.estimating_can(p_company uuid, p_area text) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is null
      or (private.has_role(p_company, '{owner,admin,office,estimator}') and private.has_perm(p_company, 'estimate')
          and (p_area = 'estimate' or private.has_perm(p_company, p_area)))
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Rates
-- ---------------------------------------------------------------------------------------------

create table public.estimate_rates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The rate's key across its versions (each new cost is a new row with the same code).
  code text not null check (code ~ '^[a-z0-9][a-z0-9_.-]{0,59}$'),
  section text not null check (section in ('labor', 'travel', 'equipment', 'disposal', 'hauling', 'materials', 'permits', 'subcontractor', 'other', 'contingency')),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  unit text not null check (unit in ('hour', 'day', 'week', 'ton', 'cy', 'load', 'haul', 'trip', 'mile', 'gallon', 'each', 'sqft', 'lf', 'lump')),
  unit_cost numeric(14, 4) not null check (unit_cost >= 0),
  includes_burden boolean not null default false,
  includes_fuel boolean not null default false,
  owned boolean,
  effective_from date not null,
  effective_to date,
  notes text check (char_length(notes) <= 1000),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, code, effective_from),
  check (effective_to is null or effective_to >= effective_from)
);
comment on table public.estimate_rates is 'Planet Ops: the business''s estimating rates, each cost from the day it takes effect. A new cost is a new row; estimates keep a snapshot of the rate they used.';
create index estimate_rates_code_idx on public.estimate_rates (company_id, code, effective_from desc);
alter table public.estimate_rates enable row level security;
create policy estimate_rates_read on public.estimate_rates for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'estimate'));
-- Not unit_cost: costs come through estimate_rate_list, for people with estimate_costs.
revoke all on public.estimate_rates from anon, authenticated;
grant select (id, company_id, code, section, name, unit, includes_burden, includes_fuel, owned, effective_from, effective_to, notes, created_by, created_at) on public.estimate_rates to authenticated;

create function private.estimate_rate_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'A rate is kept: give it an end date instead.' using errcode = '22023';
  end if;
  if (new.company_id, new.code, new.section, new.unit, new.unit_cost, new.includes_burden, new.includes_fuel, new.effective_from)
     is distinct from (old.company_id, old.code, old.section, old.unit, old.unit_cost, old.includes_burden, old.includes_fuel, old.effective_from) then
    raise exception 'A rate''s cost and unit stay as they were: add the new cost from the day it starts.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger estimate_rate_stays before update or delete on public.estimate_rates
  for each row execute function private.estimate_rate_stays();

-- A new cost for a rate (a new rate, or a new cost for an existing code from a day): the earlier
-- version ends the day before. People with estimate_costs and the Settings area.
create function public.set_estimate_rate(p_company uuid, p_code text, p_section text, p_name text, p_unit text, p_unit_cost numeric,
  p_effective_from date, p_includes_burden boolean default false, p_includes_fuel boolean default false, p_owned boolean default null, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (private.estimating_can(p_company, 'estimate_costs') and ((select auth.uid()) is null or private.has_perm(p_company, 'settings'))) then
    raise exception 'Setting estimating rates needs the Estimating costs and Settings areas.' using errcode = '42501';
  end if;
  if p_effective_from is null then
    raise exception 'Say the day the rate starts.' using errcode = '22023';
  end if;
  if exists (select 1 from public.estimate_rates r where r.company_id = p_company and r.code = p_code and r.effective_from > p_effective_from) then
    raise exception 'A later cost for this rate exists already.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('estimate_rate:' || p_company || ':' || p_code, 0));
  update public.estimate_rates set effective_to = p_effective_from - 1
   where company_id = p_company and code = p_code and effective_to is null and effective_from < p_effective_from;
  insert into public.estimate_rates (company_id, code, section, name, unit, unit_cost, includes_burden, includes_fuel, owned, effective_from, notes)
  values (p_company, p_code, p_section, btrim(p_name), p_unit, p_unit_cost, coalesce(p_includes_burden, false), coalesce(p_includes_fuel, false), p_owned, p_effective_from, p_notes)
  on conflict (company_id, code, effective_from) do nothing
  returning id into v_id;
  if v_id is null then
    raise exception 'This rate already has a cost from that day.' using errcode = '23505';
  end if;
  return v_id;
end $$;

-- The rates in effect on a day (today by default), with their costs for people with estimate_costs.
create function public.estimate_rate_list(p_company uuid, p_on date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_on date := coalesce(p_on, private.company_today(p_company)); v_costs boolean := private.estimating_can(p_company, 'estimate_costs');
begin
  if not private.estimating_can(p_company, 'estimate') then
    raise exception 'Estimating needs the Estimating area.' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'code', r.code, 'section', r.section, 'name', r.name, 'unit', r.unit,
            'unit_cost', case when v_costs then r.unit_cost end, 'includes_burden', r.includes_burden, 'includes_fuel', r.includes_fuel,
            'owned', r.owned, 'effective_from', r.effective_from, 'effective_to', r.effective_to, 'notes', r.notes) order by r.section, r.name), '[]')
    from public.estimate_rates r
   where r.company_id = p_company and r.effective_from <= v_on and (r.effective_to is null or r.effective_to >= v_on));
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. Estimates, versions, lines
-- ---------------------------------------------------------------------------------------------

create table public.estimates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  number integer not null,
  request_id uuid,
  client_id uuid,
  property_id uuid,
  title text not null check (char_length(btrim(title)) between 1 and 200),
  project_type text check (char_length(project_type) <= 120),
  estimator_id uuid references auth.users (id) on delete set null,
  -- The first approved version (the original baseline) and the latest saved one.
  baseline_version_id uuid,
  current_version_id uuid,
  -- The create request's key, so a retried "New estimate" opens the one it made.
  request_key uuid not null,
  archived_at timestamptz,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, number),
  unique (company_id, request_key),
  foreign key (company_id, request_id) references public.requests (company_id, id) on delete set null (request_id),
  foreign key (company_id, client_id) references public.clients (company_id, id) on delete set null (client_id),
  foreign key (company_id, property_id) references public.properties (company_id, id) on delete set null (property_id)
);
comment on table public.estimates is 'Planet Ops: an internal estimate (Estimating), apart from the customer''s quotes and proposals. Its versions are estimate_versions.';
create index estimates_request_idx on public.estimates (company_id, request_id);

create table public.estimate_versions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  estimate_id uuid not null,
  number integer not null,
  status text not null default 'draft' check (status in ('draft', 'approved')),
  -- Each save adds one: a save made from an older revision is refused (no lost changes).
  revision integer not null default 0,
  -- Project and site: type, scope, structures and measurements, materials and foundations, access,
  -- utilities, hazards and testing, inclusions and exclusions, notes, files.
  scope jsonb not null default '{}' check (jsonb_typeof(scope) = 'object' and pg_column_size(scope) <= 200000),
  -- The assumption log: [{text, source}].
  assumptions jsonb not null default '[]' check (jsonb_typeof(assumptions) = 'array' and pg_column_size(assumptions) <= 100000),
  pricing_method text not null default 'markup' check (pricing_method in ('markup', 'margin')),
  pricing_pct numeric(9, 6) check (pricing_pct >= 0 and (pricing_method <> 'margin' or pricing_pct < 1)),
  owner_pay_method text not null default 'none' check (owner_pay_method in ('none', 'percent_of_price')),
  owner_pct numeric(9, 6) check (owner_pct >= 0 and owner_pct < 1),
  burden_pct numeric(9, 6) check (burden_pct >= 0 and burden_pct < 5),
  default_risk_pct numeric(9, 6) check (default_risk_pct >= 0 and default_risk_pct < 5),
  -- The database's totals (private.estimate_totals), to the cent.
  base_cost numeric(14, 2),
  risk_reserve numeric(14, 2),
  subtotal numeric(14, 2),
  markup_amount numeric(14, 2),
  price_before_owner_pay numeric(14, 2),
  owner_pay numeric(14, 2),
  selling_price numeric(14, 2),
  calc_status text not null default 'unresolved' check (calc_status in ('ok', 'unresolved')),
  calc_problems jsonb not null default '[]',
  based_on_version_id uuid,
  revision_reason text check (char_length(revision_reason) <= 1000),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  saved_by uuid references auth.users (id) on delete set null,
  saved_at timestamptz,
  approved_by uuid references auth.users (id) on delete set null,
  approved_at timestamptz,
  approval_note text check (char_length(approval_note) <= 1000),
  unique (company_id, id),
  unique (estimate_id, number),
  foreign key (company_id, estimate_id) references public.estimates (company_id, id) on delete cascade
);
comment on table public.estimate_versions is 'Planet Ops: each version of an internal estimate: a draft, then approved and frozen. The first approved one is the estimate''s original baseline.';
create unique index estimate_versions_one_draft on public.estimate_versions (estimate_id) where status = 'draft';
alter table public.estimates add constraint estimates_baseline_fkey foreign key (company_id, baseline_version_id) references public.estimate_versions (company_id, id);
alter table public.estimates add constraint estimates_current_fkey foreign key (company_id, current_version_id) references public.estimate_versions (company_id, id);

create table public.estimate_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  version_id uuid not null,
  sort integer not null default 0,
  -- The line's key within the version (a fuel line names its equipment's key).
  key text check (char_length(key) <= 60),
  section text not null check (section in ('labor', 'travel', 'equipment', 'disposal', 'hauling', 'materials', 'permits', 'subcontractor', 'other', 'contingency')),
  name text not null check (char_length(btrim(name)) between 1 and 200),
  -- How it reads on a customer document (lines with the same item are one customer line).
  customer_item text check (char_length(customer_item) <= 200),
  customer_description text check (char_length(customer_description) <= 2000),
  count numeric(14, 4) check (count >= 0),
  hours numeric(14, 4) check (hours >= 0),
  days numeric(14, 4) check (days >= 0),
  unit text not null check (unit in ('hour', 'day', 'week', 'ton', 'cy', 'load', 'haul', 'trip', 'mile', 'gallon', 'each', 'sqft', 'lf', 'lump')),
  unit_cost numeric(14, 4) check (unit_cost >= 0 or section = 'other'),
  rate_id uuid,
  -- The rate as it was when this line took it: code, name, unit, cost, includes, effective dates.
  rate_snapshot jsonb,
  risk_pct numeric(9, 6) not null default 0 check (risk_pct >= 0 and risk_pct < 5),
  role text check (char_length(role) <= 80),
  overtime boolean not null default false,
  includes_burden boolean not null default false,
  includes_fuel boolean not null default false,
  owned boolean,
  fuel_for text check (char_length(fuel_for) <= 60),
  -- Disposal and hauling, each kept to its own meaning: weight, loose volume, container capacity, loads.
  material_stream text check (char_length(material_stream) <= 120),
  facility text check (char_length(facility) <= 200),
  est_tons numeric(14, 4) check (est_tons >= 0),
  est_loose_cy numeric(14, 4) check (est_loose_cy >= 0),
  container_cy numeric(14, 4) check (container_cy >= 0),
  expected_loads numeric(14, 4) check (expected_loads >= 0),
  notes text check (char_length(notes) <= 2000),
  base numeric(14, 2),
  risk numeric(14, 2),
  subtotal numeric(14, 2),
  price numeric(14, 2),
  unique (company_id, id),
  foreign key (company_id, version_id) references public.estimate_versions (company_id, id) on delete cascade,
  foreign key (company_id, rate_id) references public.estimate_rates (company_id, id)
);
comment on table public.estimate_lines is 'Planet Ops: an internal estimate version''s cost lines. Costs and prices are private (estimate_version_costs).';
create index estimate_lines_version_idx on public.estimate_lines (version_id, sort);

create table public.estimate_summaries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  estimate_id uuid not null unique,
  title text not null check (char_length(title) <= 300),
  -- Where its permanent copy belongs once Drive backup exists (Phase 4): Jobs Bid before a job; the
  -- job's folder after. Nothing here backs anything up.
  drive_destination text not null default 'jobs_bid' check (drive_destination in ('jobs_bid', 'job')),
  job_id uuid,
  drive_status text not null default 'not_backed_up' check (drive_status in ('not_backed_up', 'backed_up', 'failed')),
  drive_file_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, estimate_id) references public.estimates (company_id, id) on delete cascade,
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete set null (job_id)
);
comment on table public.estimate_summaries is 'Planet Ops: the one internal Estimate Summary per estimate (estimate_summary renders it), and where its permanent copy is to go (Phase 4).';

-- Read: the estimating people. Write: only the functions below.
alter table public.estimates enable row level security;
alter table public.estimate_versions enable row level security;
alter table public.estimate_lines enable row level security;
alter table public.estimate_summaries enable row level security;
create policy estimates_read on public.estimates for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'estimate'));
create policy estimate_versions_read on public.estimate_versions for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'estimate'));
create policy estimate_lines_read on public.estimate_lines for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'estimate'));
create policy estimate_summaries_read on public.estimate_summaries for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'estimate'));
revoke all on public.estimates, public.estimate_versions, public.estimate_lines, public.estimate_summaries from anon, authenticated;
grant select on public.estimates, public.estimate_summaries to authenticated;
-- Not the costs, percentages, totals or prices: those come through estimate_version_costs.
grant select (id, company_id, estimate_id, number, status, revision, scope, assumptions, pricing_method, owner_pay_method, calc_status, calc_problems,
              based_on_version_id, revision_reason, created_by, created_at, saved_by, saved_at, approved_by, approved_at, approval_note) on public.estimate_versions to authenticated;
grant select (id, company_id, version_id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit, rate_id, risk_pct,
              role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility, est_tons, est_loose_cy, container_cy, expected_loads, notes) on public.estimate_lines to authenticated;

-- An approved version is frozen; so are its lines.
create function private.estimate_version_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'An estimate''s versions are kept.' using errcode = '22023';
  end if;
  if old.status = 'approved' then
    raise exception 'An approved estimate version is frozen. Make a revision to change it.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger estimate_version_stays before update or delete on public.estimate_versions
  for each row execute function private.estimate_version_stays();
create function private.estimate_line_stays() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 and not exists (select 1 from public.estimate_versions where id = old.version_id) then return old; end if;
  select status into v_status from public.estimate_versions where id = coalesce(new.version_id, old.version_id);
  if v_status = 'approved' then
    raise exception 'An approved estimate version is frozen. Make a revision to change it.' using errcode = '22023';
  end if;
  return coalesce(new, old);
end $$;
create trigger estimate_line_stays before insert or update or delete on public.estimate_lines
  for each row execute function private.estimate_line_stays();

-- The totals, in the bid workbook's order with exact numerics (as packages/core/src/estimating.ts):
-- line base = count × hours × days × unit cost (× (1 + burden) for labor whose rate excludes it),
-- risk = base × risk %, subtotal = base + risk; markup on Σ subtotal (or the target margin's price,
-- carried to 10 decimals), owner pay on the price before it. Each stored amount is rounded half up
-- to the cent from full precision; each line's share of the selling price takes the cent left over
-- on its largest line, so the shares add up to the selling price.
create function private.estimate_totals(p_version uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.estimate_versions;
  v_base numeric; v_risk numeric; v_sub numeric; v_markup numeric; v_before numeric; v_owner numeric; v_sell numeric;
  v_problems jsonb := '[]';
  v_drift numeric;
begin
  select * into v from public.estimate_versions where id = p_version;
  create temporary table if not exists pg_temp.estimate_calc (id uuid, sort integer, base numeric, risk numeric) on commit drop;
  delete from pg_temp.estimate_calc;
  insert into pg_temp.estimate_calc
  select l.id, l.sort, x.base, x.base * l.risk_pct
    from public.estimate_lines l
    cross join lateral (select coalesce(l.count, 1) * coalesce(l.hours, 1) * coalesce(l.days, 1) * coalesce(l.unit_cost, 0)
                               * case when l.section = 'labor' and not l.includes_burden then 1 + coalesce(v.burden_pct, 0) else 1 end as base) x
   where l.version_id = p_version;
  select coalesce(jsonb_agg(jsonb_build_object('line', l.sort, 'field', 'Unit cost', 'message', l.name || ' has no rate yet') order by l.sort), '[]')
    into v_problems from public.estimate_lines l where l.version_id = p_version and l.unit_cost is null;
  if v.owner_pay_method = 'percent_of_price' and v.owner_pct is null then
    v_problems := v_problems || jsonb_build_array(jsonb_build_object('field', 'Owner pay', 'message', 'Owner pay is on: say its percentage (0% is allowed)'));
  end if;
  select coalesce(sum(base), 0), coalesce(sum(risk), 0) into v_base, v_risk from pg_temp.estimate_calc;
  v_sub := v_base + v_risk;
  v_markup := case when v.pricing_method = 'margin' then case when v_sub = 0 then 0 else round(v_sub / (1 - coalesce(v.pricing_pct, 0)), 10) - v_sub end
                   else v_sub * coalesce(v.pricing_pct, 0) end;
  v_before := v_sub + v_markup;
  v_owner := case when v.owner_pay_method = 'percent_of_price' then v_before * coalesce(v.owner_pct, 0) else 0 end;
  v_sell := v_before + v_owner;
  update public.estimate_lines l set base = round(c.base, 2), risk = round(c.risk, 2), subtotal = round(c.base + c.risk, 2),
         price = case when v_sub = 0 then 0 else round(round((c.base + c.risk) * v_sell / v_sub, 6), 2) end
    from pg_temp.estimate_calc c where l.id = c.id;
  select round(v_sell, 2) - coalesce(sum(price), 0) into v_drift from public.estimate_lines where version_id = p_version;
  if v_drift <> 0 then
    update public.estimate_lines set price = price + v_drift
     where id = (select id from public.estimate_lines where version_id = p_version order by abs(price) desc, sort, id limit 1);
  end if;
  update public.estimate_versions set base_cost = round(v_base, 2), risk_reserve = round(v_risk, 2), subtotal = round(v_sub, 2),
         markup_amount = round(v_markup, 2), price_before_owner_pay = round(v_before, 2), owner_pay = round(v_owner, 2),
         selling_price = round(v_sell, 2), calc_status = case when jsonb_array_length(v_problems) = 0 then 'ok' else 'unresolved' end,
         calc_problems = v_problems
   where id = p_version;
end $$;

-- The summary's title: Estimate {number} - {address} - {project type} - {year}.
create function private.estimate_summary_title(p_estimate uuid) returns text
language sql stable security definer set search_path = '' as $$
  select left('Estimate ' || e.number || ' - ' || coalesce(nullif(concat_ws(', ', p.line1, p.city), ''), 'No address') || ' - '
              || coalesce(nullif(e.project_type, ''), 'Project') || ' - ' || extract(year from e.created_at)::int, 300)
    from public.estimates e left join public.properties p on p.id = e.property_id where e.id = p_estimate
$$;

-- A new estimate (for a request, or on its own), with its first draft version and its one summary.
-- A retried call with the same key returns the estimate it made.
create function public.create_estimate(p_company uuid, p_request_key uuid, p_title text, p_request uuid default null,
  p_client uuid default null, p_property uuid default null, p_project_type text default null, p_estimator uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_version uuid; v_number integer; r public.requests;
begin
  if not private.estimating_can(p_company, 'estimate') then
    raise exception 'Estimating needs the Estimating area.' using errcode = '42501';
  end if;
  if p_request_key is null then
    raise exception 'A new estimate needs its request key.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('estimate_number:' || p_company, 0));
  select id into v_id from public.estimates where company_id = p_company and request_key = p_request_key;
  if v_id is not null then return v_id; end if;
  if p_request is not null then
    select * into r from public.requests where id = p_request and company_id = p_company;
    if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
  end if;
  if p_estimator is not null and not exists (select 1 from public.memberships m where m.company_id = p_company and m.user_id = p_estimator and m.active) then
    raise exception 'The estimator must be on the team.' using errcode = '22023';
  end if;
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

-- Saves a draft version: its project and site, assumptions, pricing settings and lines, all at once,
-- from the revision it was made from. People who prepare without seeing costs keep the costs as they
-- are (a line keeps its own; a line with a rate takes the rate's) and can't change the percentages.
create function public.save_estimate_version(p_version uuid, p_expected_revision integer, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v public.estimate_versions;
  v_costs boolean;
  v_line jsonb;
  v_old public.estimate_lines;
  v_rate public.estimate_rates;
  v_sort integer := 0;
  v_cost numeric;
  v_snapshot jsonb;
  v_keep jsonb := '[]';
begin
  select * into v from public.estimate_versions where id = p_version for update;
  if not found or not private.estimating_can(v.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
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
  if not v_costs and (p_payload ? 'pricing_pct' or p_payload ? 'owner_pct' or p_payload ? 'burden_pct' or p_payload ? 'pricing_method' or p_payload ? 'owner_pay_method') then
    raise exception 'Pricing needs the Estimating costs area.' using errcode = '42501';
  end if;

  -- The lines kept by id: their old rate snapshot and cost go with them.
  create temporary table if not exists pg_temp.estimate_old_lines on commit drop as select * from public.estimate_lines limit 0;
  delete from pg_temp.estimate_old_lines;
  insert into pg_temp.estimate_old_lines select * from public.estimate_lines where version_id = p_version;
  delete from public.estimate_lines where version_id = p_version;

  for v_line in select * from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]')) loop
    v_sort := v_sort + 1;
    v_old := null;
    if v_line ? 'id' then
      select * into v_old from pg_temp.estimate_old_lines where id = (v_line ->> 'id')::uuid;
    end if;
    v_rate := null;
    v_snapshot := null;
    if nullif(v_line ->> 'rate_id', '') is not null then
      if v_old.id is not null and v_old.rate_id = (v_line ->> 'rate_id')::uuid then
        v_snapshot := v_old.rate_snapshot;  -- kept: a rate change since doesn't move this estimate
      else
        select * into v_rate from public.estimate_rates where id = (v_line ->> 'rate_id')::uuid and company_id = v.company_id;
        if not found then raise exception 'That rate isn''t one of this business''s.' using errcode = '22023'; end if;
        v_snapshot := jsonb_build_object('rate_id', v_rate.id, 'code', v_rate.code, 'name', v_rate.name, 'unit', v_rate.unit, 'unit_cost', v_rate.unit_cost,
                                         'includes_burden', v_rate.includes_burden, 'includes_fuel', v_rate.includes_fuel, 'owned', v_rate.owned,
                                         'effective_from', v_rate.effective_from, 'effective_to', v_rate.effective_to, 'taken_at', now());
      end if;
    end if;
    -- The cost: as typed (by someone who sees costs), else the line's own, else its rate's.
    v_cost := case
      when v_costs and v_line ? 'unit_cost' then nullif(v_line ->> 'unit_cost', '')::numeric
      when v_old.id is not null and (v_old.rate_id is not distinct from nullif(v_line ->> 'rate_id', '')::uuid) then v_old.unit_cost
      when v_snapshot is not null then (v_snapshot ->> 'unit_cost')::numeric
    end;
    insert into public.estimate_lines (company_id, version_id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit,
      unit_cost, rate_id, rate_snapshot, risk_pct, role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility,
      est_tons, est_loose_cy, container_cy, expected_loads, notes)
    values (v.company_id, p_version, v_sort, nullif(v_line ->> 'key', ''), v_line ->> 'section', btrim(coalesce(v_line ->> 'name', '')),
      nullif(btrim(coalesce(v_line ->> 'customer_item', '')), ''), nullif(btrim(coalesce(v_line ->> 'customer_description', '')), ''),
      nullif(v_line ->> 'count', '')::numeric, nullif(v_line ->> 'hours', '')::numeric, nullif(v_line ->> 'days', '')::numeric,
      coalesce(nullif(v_line ->> 'unit', ''), v_snapshot ->> 'unit', 'each'), v_cost, nullif(v_line ->> 'rate_id', '')::uuid, v_snapshot,
      coalesce(nullif(v_line ->> 'risk_pct', '')::numeric, v.default_risk_pct, 0), nullif(v_line ->> 'role', ''), coalesce((v_line ->> 'overtime')::boolean, false),
      coalesce((v_line ->> 'includes_burden')::boolean, (v_snapshot ->> 'includes_burden')::boolean, false),
      coalesce((v_line ->> 'includes_fuel')::boolean, (v_snapshot ->> 'includes_fuel')::boolean, false),
      coalesce((v_line ->> 'owned')::boolean, (v_snapshot ->> 'owned')::boolean), nullif(v_line ->> 'fuel_for', ''),
      nullif(v_line ->> 'material_stream', ''), nullif(v_line ->> 'facility', ''), nullif(v_line ->> 'est_tons', '')::numeric,
      nullif(v_line ->> 'est_loose_cy', '')::numeric, nullif(v_line ->> 'container_cy', '')::numeric, nullif(v_line ->> 'expected_loads', '')::numeric,
      nullif(v_line ->> 'notes', ''));
  end loop;

  update public.estimate_versions set
    scope = case when p_payload ? 'scope' then p_payload -> 'scope' else scope end,
    assumptions = case when p_payload ? 'assumptions' then p_payload -> 'assumptions' else assumptions end,
    pricing_method = case when p_payload ? 'pricing_method' then p_payload ->> 'pricing_method' else pricing_method end,
    pricing_pct = case when p_payload ? 'pricing_pct' then nullif(p_payload ->> 'pricing_pct', '')::numeric else pricing_pct end,
    owner_pay_method = case when p_payload ? 'owner_pay_method' then p_payload ->> 'owner_pay_method' else owner_pay_method end,
    owner_pct = case when p_payload ? 'owner_pct' then nullif(p_payload ->> 'owner_pct', '')::numeric else owner_pct end,
    burden_pct = case when p_payload ? 'burden_pct' then nullif(p_payload ->> 'burden_pct', '')::numeric else burden_pct end,
    default_risk_pct = case when p_payload ? 'default_risk_pct' and v_costs then nullif(p_payload ->> 'default_risk_pct', '')::numeric else default_risk_pct end,
    revision = revision + 1, saved_by = (select auth.uid()), saved_at = now()
  where id = p_version;
  perform private.estimate_totals(p_version);
  update public.estimates set
    title = coalesce(nullif(btrim(coalesce(p_payload ->> 'title', '')), ''), title),
    project_type = case when p_payload ? 'project_type' then nullif(btrim(coalesce(p_payload ->> 'project_type', '')), '') else project_type end,
    estimator_id = case when p_payload ? 'estimator_id' then nullif(p_payload ->> 'estimator_id', '')::uuid else estimator_id end,
    client_id = case when p_payload ? 'client_id' then nullif(p_payload ->> 'client_id', '')::uuid else client_id end,
    property_id = case when p_payload ? 'property_id' then nullif(p_payload ->> 'property_id', '')::uuid else property_id end,
    current_version_id = p_version, updated_at = now()
  where id = v.estimate_id;
  update public.estimate_summaries set title = private.estimate_summary_title(v.estimate_id), updated_at = now() where estimate_id = v.estimate_id;
  return (select jsonb_build_object('revision', revision, 'calc_status', calc_status, 'calc_problems', calc_problems) from public.estimate_versions where id = p_version);
end $$;

-- Approves a saved draft (estimate_approve): frozen from now on. The estimate's first approved
-- version is its original baseline; later ones are approved revisions.
create function public.approve_estimate_version(p_version uuid, p_note text default null) returns jsonb
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
  perform private.estimate_totals(p_version);
  select * into v from public.estimate_versions where id = p_version;
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

-- A revision: a new draft copied from the latest version (its lines, rate snapshots and settings),
-- with the reason. If a draft is open already, that draft.
create function public.revise_estimate(p_estimate uuid, p_reason text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare e public.estimates; v_from public.estimate_versions; v_id uuid;
begin
  select * into e from public.estimates where id = p_estimate for update;
  if not found or not private.estimating_can(e.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
  end if;
  select id into v_id from public.estimate_versions where estimate_id = e.id and status = 'draft';
  if v_id is not null then return v_id; end if;
  select * into v_from from public.estimate_versions where estimate_id = e.id order by number desc limit 1;
  insert into public.estimate_versions (company_id, estimate_id, number, scope, assumptions, pricing_method, pricing_pct, owner_pay_method, owner_pct,
    burden_pct, default_risk_pct, based_on_version_id, revision_reason)
  values (e.company_id, e.id, v_from.number + 1, v_from.scope, v_from.assumptions, v_from.pricing_method, v_from.pricing_pct, v_from.owner_pay_method,
    v_from.owner_pct, v_from.burden_pct, v_from.default_risk_pct, v_from.id, nullif(btrim(coalesce(p_reason, '')), ''))
  returning id into v_id;
  insert into public.estimate_lines (company_id, version_id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit,
    unit_cost, rate_id, rate_snapshot, risk_pct, role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility,
    est_tons, est_loose_cy, container_cy, expected_loads, notes)
  select company_id, v_id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit,
    unit_cost, rate_id, rate_snapshot, risk_pct, role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility,
    est_tons, est_loose_cy, container_cy, expected_loads, notes
    from public.estimate_lines where version_id = v_from.id order by sort;
  perform private.estimate_totals(v_id);
  update public.estimates set current_version_id = v_id, updated_at = now() where id = e.id;
  update public.estimate_summaries set updated_at = now() where estimate_id = e.id;
  return v_id;
end $$;

-- A version's costs, percentages, totals and each line's cost and price: people with estimate_costs.
create function public.estimate_version_costs(p_version uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.estimate_versions;
begin
  select * into v from public.estimate_versions where id = p_version;
  if not found or not private.estimating_can(v.company_id, 'estimate') then
    raise exception 'Estimate not found.' using errcode = 'P0002';
  end if;
  if not private.estimating_can(v.company_id, 'estimate_costs') then
    raise exception 'Estimating costs need the Estimating costs area.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'pricing_method', v.pricing_method, 'pricing_pct', v.pricing_pct, 'owner_pay_method', v.owner_pay_method, 'owner_pct', v.owner_pct,
    'burden_pct', v.burden_pct, 'default_risk_pct', v.default_risk_pct,
    'base_cost', v.base_cost, 'risk_reserve', v.risk_reserve, 'subtotal', v.subtotal, 'markup_amount', v.markup_amount,
    'price_before_owner_pay', v.price_before_owner_pay, 'owner_pay', v.owner_pay, 'selling_price', v.selling_price,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'unit_cost', l.unit_cost, 'rate_snapshot', l.rate_snapshot, 'base', l.base,
                'risk', l.risk, 'subtotal', l.subtotal, 'price', l.price) order by l.sort), '[]') from public.estimate_lines l where l.version_id = v.id));
end $$;

revoke execute on function private.estimating_can(uuid, text), private.estimate_rate_stays(), private.estimate_version_stays(), private.estimate_line_stays(),
  private.estimate_totals(uuid), private.estimate_summary_title(uuid) from public;
revoke execute on function public.set_estimate_rate(uuid, text, text, text, text, numeric, date, boolean, boolean, boolean, text), public.estimate_rate_list(uuid, date),
  public.create_estimate(uuid, uuid, text, uuid, uuid, uuid, text, uuid), public.save_estimate_version(uuid, integer, jsonb),
  public.approve_estimate_version(uuid, text), public.revise_estimate(uuid, text), public.estimate_version_costs(uuid) from public, anon;
grant execute on function public.set_estimate_rate(uuid, text, text, text, text, numeric, date, boolean, boolean, boolean, text), public.estimate_rate_list(uuid, date),
  public.create_estimate(uuid, uuid, text, uuid, uuid, uuid, text, uuid), public.save_estimate_version(uuid, integer, jsonb),
  public.approve_estimate_version(uuid, text), public.revise_estimate(uuid, text), public.estimate_version_costs(uuid) to authenticated;

select private.fold_member_checks('public.estimate_rates');
select private.fold_member_checks('public.estimates');
select private.fold_member_checks('public.estimate_versions');
select private.fold_member_checks('public.estimate_lines');
select private.fold_member_checks('public.estimate_summaries');

notify pgrst, 'reload schema';
