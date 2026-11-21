-- Planet Ops Phase 3: internal estimates, versions, rates and their privacy
-- (20261124000100_planet_ops_estimating.sql). Fictional numbers only. Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_es;
grant usage on schema tpo_es to authenticated, service_role;
create function tpo_es.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_es.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- Runs a statement signed in as someone, and gives back what it returns (as text).
create function tpo_es.as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute p_sql into v;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return v;
exception when others then
  reset role;
  perform set_config('request.jwt.claims', '', true);
  raise;
end $$;
grant execute on all functions in schema tpo_es to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2400000-0000-0000-0000-000000000001', 'owner@planet-es.test', '{"full_name": "Test Owner"}'),
  ('e2400000-0000-0000-0000-000000000002', 'estimator@planet-es.test', '{"full_name": "Test Estimator"}'),
  ('e2400000-0000-0000-0000-000000000003', 'prep@planet-es.test', '{"full_name": "Test Preparer, no costs"}'),
  ('e2400000-0000-0000-0000-000000000004', 'crew@planet-es.test', '{"full_name": "Test Crew Lead"}'),
  ('e2400000-0000-0000-0000-000000000005', 'other@planet-es.test', '{"full_name": "Other Business Owner"}');
\set owner 'e2400000-0000-0000-0000-000000000001'
\set est 'e2400000-0000-0000-0000-000000000002'
\set prep 'e2400000-0000-0000-0000-000000000003'
\set crew 'e2400000-0000-0000-0000-000000000004'
\set other 'e2400000-0000-0000-0000-000000000005'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition ES', 'general') as co \gset
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'other', 'role', 'authenticated')::text, true);
select public.create_company('TEST Other Business ES', 'general') as co2 \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'est', 'estimator'), (:'co', :'crew', 'crew_lead');
insert into public.company_roles (company_id, name, description, base_role, permissions) values (:'co', 'TEST Estimating helper', 'Prepares; no costs.', 'estimator', array['sales', 'estimate']) returning id as prep_role \gset
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', :'prep', 'estimator', :'prep_role');
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Estimate Customer') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '9 Test Court', 'Testville', 'CA', '95000') returning id as property \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Garage demolition') returning id as req \gset

-- ===== Areas =======================================================================================
select tpo_es.check(private.level_permissions('owner') @> '{estimate,estimate_costs,estimate_approve}' and private.level_permissions('estimator') @> '{estimate,estimate_costs}'
                    and not ('estimate_approve' = any (private.level_permissions('estimator'))) and not ('estimate_approve' = any (private.level_permissions('office')))
                    and not ('estimate' = any (private.level_permissions('crew_lead'))),
  'owners and admins prepare, see costs and approve; office and estimators prepare and see costs; crews none');
select tpo_es.check((select permissions @> '{estimate,estimate_costs}' and not ('estimate_approve' = any (permissions)) from public.company_roles where company_id = :'co' and name = 'Office manager')
                    and (select permissions @> '{estimate,estimate_costs,estimate_approve}' from public.company_roles where company_id = :'co' and name = 'General manager'),
  'a new business''s roles have the estimating areas');

-- ===== Creating: one estimate per request key, with its first draft and its one summary ===========
select tpo_es.as(:'est', format('select public.create_estimate(%L, %L, %L, %L, p_project_type => %L)', :'co', 'a2400000-0000-0000-0000-0000000000a1', 'Garage demolition', :'req', 'Garage demolition')) as e1 \gset
select tpo_es.check(tpo_es.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2400000-0000-0000-0000-0000000000a1', 'Again', :'req')) = :'e1',
  'creating again with the same key (a retry) returns the same estimate');
select tpo_es.check((select count(*) = 1 and bool_and(number = 1 and client_id = :'client' and property_id = :'property' and estimator_id = :'est') from public.estimates where company_id = :'co'),
  'one estimate, number 1, linked to the request''s customer and property, its estimator');
select current_version_id as v1 from public.estimates where id = :'e1' \gset
select tpo_es.check((select count(*) = 1 and bool_and(title = 'Estimate 1 - 9 Test Court, Testville - Garage demolition - ' || extract(year from now())::int) from public.estimate_summaries where estimate_id = :'e1'),
  'and its one summary, titled Estimate {number} - {address} - {project type} - {year}');
select tpo_es.check(not exists (select 1 from public.quotes where company_id = :'co') and not exists (select 1 from public.job_folder_provisioning where company_id = :'co'),
  'starting an estimate makes no quote and no folder');

-- ===== Saving: the workbook's order, exact, to the cent (the same case as packages/core/test/estimating.test.ts) =====
select tpo_es.as(:'est', format($f$select public.save_estimate_version(%L, 0, %L::jsonb)::text$f$, :'v1', $j${
  "scope": {"project_type": "Garage demolition", "area_sqft": 480, "structures": [{"name": "Detached garage", "sqft": 480}], "inclusions": "Slab removal", "exclusions": "Utility disconnects"},
  "assumptions": [{"text": "Fictional test: 4 tons of mixed debris", "source": "test"}],
  "pricing_method": "markup", "pricing_pct": 0.4, "owner_pay_method": "percent_of_price", "owner_pct": 0.05,
  "lines": [
    {"key": "crew", "section": "labor", "name": "Crew", "count": 3, "hours": 8, "days": 2, "unit": "hour", "unit_cost": 30, "customer_item": "Demolition"},
    {"key": "debris", "section": "disposal", "name": "Debris", "count": 4, "unit": "ton", "unit_cost": 95.5, "risk_pct": 0.1, "est_tons": 4, "est_loose_cy": 18, "container_cy": 20, "expected_loads": 1, "customer_item": "Haul-off and disposal"},
    {"key": "contingency", "section": "contingency", "name": "Contingency", "count": 1, "unit": "lump", "unit_cost": 250, "customer_item": "Demolition"}
  ]}$j$)) as saved \gset
select tpo_es.check((:'saved'::jsonb ->> 'revision')::int = 1 and :'saved'::jsonb ->> 'calc_status' = 'ok', 'saving moves the revision to 1; the estimate is complete');
select tpo_es.check((select base_cost = 2072 and risk_reserve = 38.2 and subtotal = 2110.2 and markup_amount = 844.08 and price_before_owner_pay = 2954.28
                            and owner_pay = 147.71 and selling_price = 3101.99 from public.estimate_versions where id = :'v1'),
  'base, risk, subtotal, markup, price before owner pay, owner pay, selling price: as the engine computes them');
select tpo_es.check((select sum(price) = 3101.99 from public.estimate_lines where version_id = :'v1'), 'the lines'' prices add up to the selling price');
select tpo_es.check((select est_tons = 4 and est_loose_cy = 18 and container_cy = 20 and expected_loads = 1 from public.estimate_lines where version_id = :'v1' and key = 'debris'),
  'weight, loose volume, container capacity and loads are kept apart');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format($f$select public.save_estimate_version(%L, 0, '{"lines": []}'::jsonb)::text$f$, :'v1')),
  'a save made from an older revision is refused: nobody''s changes are lost', '%Someone else saved%');

-- ===== Privacy: costs only for estimate_costs ======================================================
select tpo_es.check(tpo_es.as(:'prep', format('select count(*)::text from public.estimate_lines where version_id = %L', :'v1')) = '3', 'a preparer without cost access reads the lines');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'prep', format('select unit_cost::text from public.estimate_lines where version_id = %L limit 1', :'v1')), 'but not their costs', '%permission denied%');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'prep', format('select selling_price::text from public.estimate_versions where id = %L', :'v1')), 'nor the totals', '%permission denied%');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'prep', format('select public.estimate_version_costs(%L)::text', :'v1')), 'nor through the costs function', '%Estimating costs area%');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'prep', format($f$select public.save_estimate_version(%L, 1, '{"pricing_pct": 0.9}'::jsonb)::text$f$, :'v1')), 'nor change the markup', '%Estimating costs area%');
-- A preparer changes a quantity; the costs stay as they were.
select tpo_es.as(:'prep', format($f$select public.save_estimate_version(%L, 1, %L::jsonb)::text$f$, :'v1', (
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'count', case when key = 'crew' then 4 else count end,
           'hours', hours, 'days', days, 'unit', unit, 'unit_cost', 999, 'risk_pct', risk_pct, 'customer_item', customer_item) order by sort))
    from public.estimate_lines where version_id = :'v1')));
select tpo_es.check((select unit_cost = 30 and count = 4 from public.estimate_lines where version_id = :'v1' and key = 'crew'), 'their quantity is saved, a typed cost isn''t: the cost stays');
select tpo_es.check((select base_cost = 2552 from public.estimate_versions where id = :'v1'), 'and the totals follow');
select tpo_es.check(tpo_es.as(:'crew', format('select count(*)::text from public.estimates where company_id = %L', :'co')) = '0', 'a crew lead sees no estimates');
select tpo_es.check(tpo_es.as(:'other', format('select count(*)::text from public.estimates where company_id = %L', :'co')) = '0', 'another business sees none');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'other', format('select public.estimate_version_costs(%L)::text', :'v1')), 'nor their costs', '%not found%');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format('insert into public.estimates (company_id, number, title, request_key) values (%L, 99, %L, gen_random_uuid())', :'co', 'Direct')),
  'estimates are written only through their functions');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format('update public.estimate_lines set count = 100 where version_id = %L', :'v1')), 'lines too');

-- ===== Rates: a new cost never changes an earlier estimate =========================================
select tpo_es.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 75, %L)::text', :'co', 'test.loader', 'equipment', 'TEST loader', 'day', current_date - 10)) as r1 \gset
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 80, %L)::text', :'co', 'test.loader', 'equipment', 'TEST loader', 'day', current_date)),
  'an estimator without Settings can''t set rates', '%Settings areas%');
select tpo_es.as(:'est', format($f$select public.save_estimate_version(%L, 2, %L::jsonb)::text$f$, :'v1', (
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'count', count, 'hours', hours, 'days', days,
           'unit', unit, 'unit_cost', unit_cost, 'risk_pct', risk_pct, 'customer_item', customer_item) order by sort)
         || jsonb_build_array(jsonb_build_object('key', 'loader', 'section', 'equipment', 'name', 'Loader', 'count', 1, 'days', 2, 'rate_id', :'r1', 'customer_item', 'Demolition')))
    from public.estimate_lines where version_id = :'v1')));
select tpo_es.check((select unit_cost = 75 and unit = 'day' and (rate_snapshot ->> 'unit_cost')::numeric = 75 and rate_snapshot ->> 'code' = 'test.loader' from public.estimate_lines where version_id = :'v1' and key = 'loader'),
  'a line with a rate takes its cost, unit and a snapshot of it');
select tpo_es.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 90, %L)::text', :'co', 'test.loader', 'equipment', 'TEST loader', 'day', current_date)) as r2 \gset
select tpo_es.check((select effective_to = current_date - 1 from public.estimate_rates where id = :'r1') and (select (jsonb_array_elements(public.estimate_rate_list(:'co')) ->> 'unit_cost')::numeric = 90),
  'the new cost starts today; the old one ends yesterday');
select tpo_es.expect_error(format('update public.estimate_rates set unit_cost = 1 where id = %L', :'r1'), 'a rate''s cost can''t be edited in place', '%stay as they were%');
select tpo_es.check((select unit_cost = 75 from public.estimate_lines where version_id = :'v1' and key = 'loader'), 'the estimate keeps the cost it took');
-- Re-saved: the line keeps its snapshot.
select tpo_es.as(:'est', format($f$select public.save_estimate_version(%L, 3, %L::jsonb)::text$f$, :'v1', (
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'count', count, 'hours', hours, 'days', days,
           'unit', unit, 'rate_id', rate_id, 'risk_pct', risk_pct, 'customer_item', customer_item) || case when rate_id is null then jsonb_build_object('unit_cost', unit_cost) else '{}' end order by sort))
    from public.estimate_lines where version_id = :'v1')));
select tpo_es.check((select unit_cost = 75 and (rate_snapshot ->> 'unit_cost')::numeric = 75 from public.estimate_lines where version_id = :'v1' and key = 'loader'), 'saved again, it still has the rate as it took it');
select tpo_es.check(tpo_es.as(:'prep', format('select (jsonb_array_elements(public.estimate_rate_list(%L)) ->> %L) is null', :'co', 'unit_cost')) = 'true', 'a preparer sees rates without their costs');

-- ===== Approval freezes the original baseline; revisions stay separate ===========================
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'v1')), 'an estimator can''t approve', '%Approve estimates area%');
select tpo_es.as(:'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L), p_note => %2$L)::text', :'v1', 'TEST approval')) as appr \gset
select tpo_es.check((:'appr'::jsonb ->> 'baseline')::boolean and (select baseline_version_id = :'v1' from public.estimates where id = :'e1') and (select status = 'approved' and approved_by = :'owner' from public.estimate_versions where id = :'v1'),
  'the owner approves: version 1 is the original baseline');
select selling_price as v1_price, base_cost as v1_base from public.estimate_versions where id = :'v1' \gset
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format($f$select public.save_estimate_version(%L, 4, '{"lines": []}'::jsonb)::text$f$, :'v1')), 'an approved version can''t be saved over', '%frozen%');
select tpo_es.expect_error(format('update public.estimate_lines set count = 9 where version_id = %L', :'v1'), 'nor its lines changed, even by the server', '%frozen%');
select tpo_es.expect_error(format('delete from public.estimate_versions where id = %L', :'v1'), 'versions are kept', '%kept%');
select tpo_es.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e1', 'Customer added the shed')) as v2 \gset
select tpo_es.check(tpo_es.as(:'est', format('select public.revise_estimate(%L)::text', :'e1')) = :'v2', 'revising again opens the same draft');
select tpo_es.check((select number = 2 and status = 'draft' and based_on_version_id = :'v1' and revision_reason = 'Customer added the shed' from public.estimate_versions where id = :'v2')
                    and (select count(*) from public.estimate_lines where version_id = :'v2') = (select count(*) from public.estimate_lines where version_id = :'v1'),
  'the revision is version 2, a draft copied from version 1, with its reason');
select tpo_es.as(:'est', format($f$select public.save_estimate_version(%L, 0, %L::jsonb)::text$f$, :'v2', (
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'count', case when key = 'debris' then 6 else count end,
           'hours', hours, 'days', days, 'unit', unit, 'rate_id', rate_id, 'risk_pct', risk_pct, 'customer_item', customer_item) || case when rate_id is null then jsonb_build_object('unit_cost', unit_cost) else '{}' end order by sort))
    from public.estimate_lines where version_id = :'v2')));
select tpo_es.check((select selling_price = :'v1_price'::numeric and base_cost = :'v1_base'::numeric from public.estimate_versions where id = :'v1')
                    and (select selling_price > :'v1_price'::numeric from public.estimate_versions where id = :'v2'),
  'the revision''s changes leave the baseline as it was');
select tpo_es.check((select unit_cost = 75 from public.estimate_lines where version_id = :'v2' and key = 'loader'), 'the revision keeps the rate snapshot it was copied with, though the rate has moved on');
select tpo_es.as(:'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'v2')) as appr2 \gset
select tpo_es.check(not (:'appr2'::jsonb ->> 'baseline')::boolean and (select baseline_version_id = :'v1' from public.estimates where id = :'e1'), 'approving the revision keeps version 1 as the original baseline');

-- ===== What can't be approved =======================================================================
select tpo_es.as(:'est', format('select public.create_estimate(%L, %L, %L)', :'co', 'a2400000-0000-0000-0000-0000000000a2', 'Shed removal')) as e2 \gset
select current_version_id as e2v from public.estimates where id = :'e2' \gset
select tpo_es.as(:'est', format($f$select public.save_estimate_version(%L, 0, '{"owner_pay_method": "percent_of_price", "lines": [{"section": "equipment", "name": "Excavator", "count": 1, "days": 1, "unit": "day"}]}'::jsonb)::text$f$, :'e2v')) as unresolved \gset
select tpo_es.check(:'unresolved'::jsonb ->> 'calc_status' = 'unresolved' and :'unresolved'::jsonb -> 'calc_problems' @> '[{"field": "Unit cost"}]' and :'unresolved'::jsonb -> 'calc_problems' @> '[{"field": "Owner pay"}]',
  'a line without a rate, or owner pay without its percentage, leaves the estimate unresolved, saying which');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'e2v')), 'and it can''t be approved', '%can''t be approved yet%');
select tpo_es.expect_error(format('select tpo_es.as(%L, %L)', :'est', format($f$select public.save_estimate_version(%L, 1, '{"pricing_method": "margin", "pricing_pct": 1}'::jsonb)::text$f$, :'e2v')),
  'a target margin of 100% is refused');
select tpo_es.check(not exists (select 1 from public.quotes where company_id = :'co') and not exists (select 1 from public.jobs where company_id = :'co')
                    and not exists (select 1 from public.job_folder_provisioning where company_id = :'co'),
  'saving, approving and revising estimates make no quote, job or folder');

-- The companies are kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops estimating tests passed.'
