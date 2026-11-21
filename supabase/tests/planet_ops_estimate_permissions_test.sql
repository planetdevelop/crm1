-- Planet Ops Phase 3 hardening: who can do what with estimates, tried against the database itself
-- (not the screens): raw reads, forged save payloads, other companies' ids, direct writes, and errors
-- that could show a hidden cost (20261124000100, 20261125000100, 20261126000100). Fictional only.
-- Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_epm;
grant usage on schema tpo_epm to authenticated, anon, service_role;
create function tpo_epm.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_epm.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- Everything an error tells the caller (what PostgREST passes on: message, detail, hint).
create function tpo_epm.error_text(p_sql text) returns text language plpgsql as $$
declare m text; d text; h text;
begin
  begin execute p_sql; exception when others then
    get stacked diagnostics m = message_text, d = pg_exception_detail, h = pg_exception_hint;
    return concat_ws(' | ', m, d, h);
  end;
  return null;
end $$;
create function tpo_epm.as(p_user uuid, p_sql text) returns text language plpgsql as $$
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
-- A line of the version as stored (read as the database's owner, to check what a save did).
create function tpo_epm.line(p_version uuid, p_key text) returns public.estimate_lines language sql as $$
  select * from public.estimate_lines where version_id = p_version and key = p_key
$$;
grant execute on all functions in schema tpo_epm to authenticated, anon, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2700000-0000-0000-0000-000000000001', 'owner@planet-epm.test', '{"full_name": "Test Owner"}'),
  ('e2700000-0000-0000-0000-000000000002', 'costs@planet-epm.test', '{"full_name": "Test Estimator, costs"}'),
  ('e2700000-0000-0000-0000-000000000003', 'prep@planet-epm.test', '{"full_name": "Test Preparer, no costs"}'),
  ('e2700000-0000-0000-0000-000000000004', 'approver@planet-epm.test', '{"full_name": "Test Approver"}'),
  ('e2700000-0000-0000-0000-000000000005', 'seller@planet-epm.test', '{"full_name": "Test Seller, no estimating"}'),
  ('e2700000-0000-0000-0000-000000000006', 'nosend@planet-epm.test', '{"full_name": "Test Estimator, can''t send"}'),
  ('e2700000-0000-0000-0000-000000000007', 'crew@planet-epm.test', '{"full_name": "Test Crew"}'),
  ('e2700000-0000-0000-0000-000000000008', 'other@planet-epm.test', '{"full_name": "Test Other Company Owner"}');
\set owner 'e2700000-0000-0000-0000-000000000001'
\set costs 'e2700000-0000-0000-0000-000000000002'
\set prep 'e2700000-0000-0000-0000-000000000003'
\set approver 'e2700000-0000-0000-0000-000000000004'
\set seller 'e2700000-0000-0000-0000-000000000005'
\set nosend 'e2700000-0000-0000-0000-000000000006'
\set crew 'e2700000-0000-0000-0000-000000000007'
\set other 'e2700000-0000-0000-0000-000000000008'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition EPM', 'general') as co \gset
select set_config('request.jwt.claims', json_build_object('sub', :'other', 'role', 'authenticated')::text, true);
select public.create_company('TEST Other Demolition EPM', 'general') as co2 \gset
commit;
insert into public.company_roles (company_id, name, description, base_role, permissions) values
  (:'co', 'TEST Costs', 'Prepares and sees costs.', 'estimator', array['sales', 'send_pricing', 'estimate', 'estimate_costs']),
  (:'co', 'TEST Preparer', 'Prepares; no costs.', 'estimator', array['sales', 'send_pricing', 'estimate']),
  (:'co', 'TEST Approver', 'Approves; no costs.', 'admin', array['estimate', 'estimate_approve']),
  (:'co', 'TEST Seller', 'Sells; no estimating.', 'estimator', array['sales', 'send_pricing']),
  (:'co', 'TEST No send', 'Estimates and prepares documents; can''t send.', 'estimator', array['sales', 'estimate', 'estimate_costs']);
insert into public.memberships (company_id, user_id, role, role_id) values
  (:'co', :'costs', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Costs')),
  (:'co', :'prep', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Preparer')),
  (:'co', :'approver', 'admin', (select id from public.company_roles where company_id = :'co' and name = 'TEST Approver')),
  (:'co', :'seller', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Seller')),
  (:'co', :'nosend', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST No send'));
insert into public.memberships (company_id, user_id, role) values (:'co', :'crew', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Permissions Customer A') returning id as client \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Permissions Customer B') returning id as client_b \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '9 Test Court', 'Testburg', 'CA', '95001') returning id as property \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client_b', '11 Test Court', 'Testburg', 'CA', '95001') returning id as property_b \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Barn demolition') returning id as req \gset
insert into public.clients (company_id, display_name) values (:'co2', 'TEST – Other company''s customer') returning id as client_other \gset
-- Rates: a crew rate (excludes burden) whose cost was superseded today, and a loader.
select tpo_epm.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 20, %L)::text', :'co', 'test.crew', 'labor', 'TEST crew hour', 'hour', current_date - 60)) as crew_old \gset
select tpo_epm.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 27.25, %L)::text', :'co', 'test.crew', 'labor', 'TEST crew hour', 'hour', current_date)) as crew_now \gset
select tpo_epm.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 410, %L, p_includes_fuel => true)::text', :'co', 'test.loader', 'equipment', 'TEST loader day', 'day', current_date - 5)) as loader \gset

-- The estimate, priced by someone who sees costs: crew at the rate (10% burden), a typed hauling
-- cost of $123.4567 a load with 12% risk, an "Other" credit, 25% markup.
select tpo_epm.as(:'costs', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2700000-0000-0000-0000-0000000000e1', 'Barn demolition', :'req')) as e1 \gset
select current_version_id as v1 from public.estimates where id = :'e1' \gset
select tpo_epm.as(:'costs', format($f$select public.save_estimate_version(%L, 0, %L::jsonb)::text$f$, :'v1', jsonb_build_object(
  'pricing_method', 'markup', 'pricing_pct', 0.25, 'owner_pay_method', 'none', 'burden_pct', 0.1, 'default_risk_pct', 0.05,
  'lines', jsonb_build_array(
    jsonb_build_object('key', 'crew', 'section', 'labor', 'name', 'Crew', 'count', 2, 'hours', 8, 'days', 2, 'unit', 'hour', 'rate_id', :'crew_now', 'risk_pct', 0, 'customer_item', 'Demolition'),
    jsonb_build_object('key', 'haul', 'section', 'hauling', 'name', 'Haul loads', 'count', 4, 'unit', 'load', 'unit_cost', 123.4567, 'risk_pct', 0.12, 'customer_item', 'Haul-off'),
    jsonb_build_object('key', 'credit', 'section', 'other', 'name', 'Salvage credit', 'count', 1, 'unit', 'lump', 'unit_cost', -50, 'risk_pct', 0, 'customer_item', 'Demolition')))));
select id as haul_id from public.estimate_lines where version_id = :'v1' and key = 'haul' \gset
select id as crew_id from public.estimate_lines where version_id = :'v1' and key = 'crew' \gset
select selling_price as v1_price, base_cost as v1_base from public.estimate_versions where id = :'v1' \gset
-- crew 2×8×2×27.25×1.1 = 959.20; haul 493.8268 (+12% 59.26); credit −50 → base 1,403.03.
select tpo_epm.check((select base_cost = 1403.03 and risk_reserve = 59.26 from public.estimate_versions where id = :'v1'), 'priced: base $1,403.03, risk $59.26');

-- ===== Reading: no cost, wage, margin or reserve for those without "See estimating costs" ========
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select unit_cost::text from public.estimate_lines where version_id = %L limit 1', :'v1')), 'a preparer can''t read a line''s cost', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select rate_snapshot::text from public.estimate_lines where version_id = %L limit 1', :'v1')), 'nor its rate snapshot', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select base::text from public.estimate_lines where version_id = %L limit 1', :'v1')), 'nor its base or price', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select selling_price::text from public.estimate_versions where id = %L', :'v1')), 'nor the version''s totals', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select pricing_pct::text from public.estimate_versions where id = %L', :'v1')), 'nor its markup', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select burden_pct::text from public.estimate_versions where id = %L', :'v1')), 'nor its burden', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select count(*)::text from (select * from public.estimate_lines where version_id = %L) x', :'v1')), 'nor everything at once (select *)', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', 'select unit_cost::text from public.estimate_rates limit 1'), 'nor a rate''s cost', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select public.estimate_version_costs(%L)::text', :'v1')), 'nor the costs function', '%Estimating costs area%');
select tpo_epm.check(not (tpo_epm.as(:'prep', format('select public.estimate_rate_list(%L)::text', :'co')) ~ ': (27\.25|410)|"unit_cost": [0-9]'), 'the rate list a preparer gets has the rates'' names but no cost');
select tpo_epm.check(not (tpo_epm.as(:'prep', format('select public.estimate_summary(%L)::text', :'e1')) ~ ': (123\.45|27\.25|1403|959|493|59\.26)|"(selling_price|unit_cost|pricing_pct|burden_pct|owner_pct|base_cost|price)": [-0-9]'),
  'the summary a preparer gets has no cost, wage, reserve, markup or price');
select tpo_epm.check(not (tpo_epm.as(:'approver', format('select public.estimate_summary(%L)::text', :'e1')) ~ ': (123\.45|27\.25|1403)|"(selling_price|unit_cost|pricing_pct)": [-0-9]'), 'nor does an approver''s without costs');
select tpo_epm.check(tpo_epm.as(:'costs', format('select public.estimate_version_costs(%L)::text', :'v1')) ~ '123\.4567', 'someone with costs gets them');

-- ===== Saving as a preparer: quantities and scope, never hidden pricing ==========================
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v1', '{"default_risk_pct": 0}')),
  'a preparer can''t change the default risk', '%Estimating costs area%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v1', '{"owner_pay_method": "percent_of_price", "owner_pct": 0.5}')),
  'nor owner pay', '%Estimating costs area%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v1', '{"pricing_method": "margin", "pricing_pct": 0.9}')),
  'nor the markup or margin', '%Estimating costs area%');
-- The forged payload: unit costs, risk 0, "includes burden" on the crew line, a more expensive count.
select tpo_epm.as(:'prep', format($f$select public.save_estimate_version(%L, 1, %L::jsonb)::text$f$, :'v1', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('id', :'crew_id', 'key', 'crew', 'section', 'labor', 'name', 'Crew', 'count', 3, 'hours', 8, 'days', 2, 'unit', 'hour', 'rate_id', :'crew_now', 'unit_cost', 1, 'risk_pct', 0.9, 'includes_burden', true, 'customer_item', 'Demolition'),
  jsonb_build_object('id', :'haul_id', 'key', 'haul', 'section', 'hauling', 'name', 'Haul loads', 'count', 5, 'unit', 'load', 'unit_cost', 1, 'risk_pct', 0, 'customer_item', 'Haul-off'),
  jsonb_build_object('key', 'credit', 'section', 'other', 'name', 'Salvage credit', 'count', 1, 'unit', 'lump', 'unit_cost', -5000, 'customer_item', 'Demolition'),
  jsonb_build_object('key', 'new', 'section', 'equipment', 'name', 'Loader', 'count', 1, 'days', 1, 'unit', 'day', 'rate_id', :'loader', 'risk_pct', 0, 'customer_item', 'Demolition')))));
select tpo_epm.check((select unit_cost = 27.25 and risk_pct = 0 and not includes_burden and count = 3 from tpo_epm.line(:'v1', 'crew')),
  'the crew line takes the new count, but keeps its rate''s cost, its risk % and "excludes burden" (forged values ignored)');
select tpo_epm.check((select unit_cost = 123.4567 and risk_pct = 0.12 and count = 5 from tpo_epm.line(:'v1', 'haul')), 'the typed hauling cost and its 12% risk stay; only the count changed');
select tpo_epm.check((select unit_cost is null and risk_pct = 0.05 from tpo_epm.line(:'v1', 'credit')),
  'a line sent without its id can''t carry a forged credit: no cost (so the estimate is incomplete), the default risk');
select tpo_epm.check((select unit_cost = 410 and risk_pct = 0.05 and includes_fuel and rate_snapshot ->> 'code' = 'test.loader' from tpo_epm.line(:'v1', 'new')),
  'picking a current rate works as designed: its cost and snapshot, the estimate''s default risk');
select tpo_epm.check((select calc_status = 'unresolved' and revision = 2 from public.estimate_versions where id = :'v1'), 'saved, and incomplete until someone with costs prices the credit');
-- A typed cost can't be carried into another section (where burden or a credit would apply).
select tpo_epm.as(:'prep', format($f$select public.save_estimate_version(%L, 2, %L::jsonb)::text$f$, :'v1', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('id', (tpo_epm.line(:'v1', 'haul')).id, 'key', 'haul', 'section', 'labor', 'name', 'Haul loads', 'count', 5, 'unit', 'load')))));
select tpo_epm.check((select unit_cost is null and section = 'labor' from tpo_epm.line(:'v1', 'haul')), 'moving a typed-cost line to Labor drops the cost (no burden on a cost they never saw)');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format($f$select public.save_estimate_version(%L, 3, %L::jsonb)::text$f$, :'v1',
  jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('key', 'old', 'section', 'labor', 'name', 'Crew', 'count', 1, 'unit', 'hour', 'rate_id', :'crew_old'))))),
  'a preparer can''t pick a superseded (cheaper) rate', '%isn''t in effect today%');
select tpo_epm.check(tpo_epm.as(:'costs', format($f$select public.save_estimate_version(%L, 3, %L::jsonb)::text$f$, :'v1',
  jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('key', 'old', 'section', 'labor', 'name', 'Crew', 'count', 1, 'unit', 'hour', 'rate_id', :'crew_old'))))) is not null
  and (select unit_cost = 20 from tpo_epm.line(:'v1', 'old')),
  'someone who sees costs can, on purpose (it shows its dates and cost)');
-- Put the original back (as the cost person) for the rest.
select tpo_epm.as(:'costs', format($f$select public.save_estimate_version(%L, 4, %L::jsonb)::text$f$, :'v1', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('key', 'crew', 'section', 'labor', 'name', 'Crew', 'count', 2, 'hours', 8, 'days', 2, 'unit', 'hour', 'rate_id', :'crew_now', 'risk_pct', 0, 'customer_item', 'Demolition'),
  jsonb_build_object('key', 'haul', 'section', 'hauling', 'name', 'Haul loads', 'count', 4, 'unit', 'load', 'unit_cost', 123.4567, 'risk_pct', 0.12, 'customer_item', 'Haul-off'),
  jsonb_build_object('key', 'credit', 'section', 'other', 'name', 'Salvage credit', 'count', 1, 'unit', 'lump', 'unit_cost', -50, 'risk_pct', 0, 'customer_item', 'Demolition')))));
select tpo_epm.check((select selling_price = :'v1_price' from public.estimate_versions where id = :'v1'), 'back to the cost person''s price');

-- ===== Errors don't show hidden values ===========================================================
select tpo_epm.error_text(format('select tpo_epm.as(%L, %L)', :'prep', format($f$select public.save_estimate_version(%L, 5, %L::jsonb)::text$f$, :'v1', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('id', (tpo_epm.line(:'v1', 'haul')).id, 'key', 'haul', 'section', 'hauling', 'name', 'Haul loads', 'count', -1, 'unit', 'load')))))) as err \gset
select tpo_epm.check(:'err' like '%value that isn''t allowed%' and :'err' !~ '123\.45|Failing row', 'a refused negative count names the line, not the row (whose cost the preparer can''t see)');
select tpo_epm.error_text(format('select tpo_epm.as(%L, %L)', :'prep', format($f$select public.save_estimate_version(%L, 5, %L::jsonb)::text$f$, :'v1', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('id', (tpo_epm.line(:'v1', 'haul')).id, 'key', 'haul', 'section', 'hauling', 'name', 'Haul loads', 'count', 'lots', 'unit', 'load')))))) as err \gset
select tpo_epm.check(:'err' like '%isn''t valid%' and :'err' !~ '123\.4567', 'nor does a number that isn''t one');
select tpo_epm.error_text(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.save_estimate_version(%L, 5, %L::jsonb)::text', :'v1', '{"pricing_method": "margin", "pricing_pct": 1.5}'))) as err \gset
select tpo_epm.check(:'err' like '%target margin is under 100%%' and :'err' !~ 'Failing row', 'a margin of 150% is refused in words');
select tpo_epm.check((select revision = 5 from public.estimate_versions where id = :'v1'), 'refused saves change nothing');

-- ===== Approving: the right area, the reviewed revision ==========================================
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.approve_estimate_version(%L, 5)::text', :'v1')), 'seeing costs isn''t approving', '%Approve estimates area%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'prep', format('select public.approve_estimate_version(%L, 5)::text', :'v1')), 'nor is preparing', '%Approve estimates area%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'approver', format('select public.approve_estimate_version(%L, 4)::text', :'v1')), 'an approver must approve the revision they reviewed', '%saved again%');
select tpo_epm.as(:'approver', format('select public.approve_estimate_version(%L, 5)::text', :'v1'));
select tpo_epm.check((select status = 'approved' and approved_by = :'approver' from public.estimate_versions where id = :'v1'), 'the approver approves revision 5 (they see the scope and quantities; costs only with the costs area)');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('update public.estimate_versions set approved_by = %L where id = %L', :'costs', :'v1')), 'nobody can write an approval by hand', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'owner', format('update public.estimates set baseline_version_id = null where id = %L', :'e1')), 'or replace the baseline', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'owner', format('insert into public.estimate_versions (company_id, estimate_id, number, status) values (%L, %L, 9, %L)', :'co', :'e1', 'approved')), 'or add an approved version', '%permission denied%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'owner', format('delete from public.estimate_summaries where estimate_id = %L', :'e1')), 'or remove the summary', '%permission denied%');

-- ===== Documents: Estimating and sales to make one; send_pricing to send it =====================
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'seller', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2700000-0000-0000-0000-0000000000f1')), 'selling without estimating can''t make one from an estimate', '%Estimating%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'approver', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2700000-0000-0000-0000-0000000000f1')), 'nor can approving without sales', '%Quotes and sales%');
select tpo_epm.as(:'nosend', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2700000-0000-0000-0000-0000000000f1')) as q1 \gset
select tpo_epm.check((select status = 'draft' and sent_at is null from public.quotes where id = :'q1'), 'someone without "Send pricing" makes the unsent draft');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'nosend', format('update public.quotes set status = %L, sent_at = now() where id = %L', 'sent', :'q1')), 'but can''t send it', '%Send pricing to customers%');
select tpo_epm.check((select bool_and(unit_cost is null) and sum(unit_price) = :'v1_price' from public.quote_line_items where quote_id = :'q1'), 'its lines are prices only, adding up to the calculated price');
select tpo_epm.check(tpo_epm.as(:'seller', format('select count(*)::text from public.estimates where company_id = %L', :'co')) = '0', 'someone who sells without estimating sees no estimates');
select tpo_epm.check(tpo_epm.as(:'seller', format('select coalesce(estimate_version_id::text, %L) from public.quotes where id = %L', 'none', :'q1')) is not null, 'they see the document itself (it''s theirs to send), never the estimate behind it');

-- ===== Crew, other companies, no one signed in ==================================================
select tpo_epm.check(tpo_epm.as(:'crew', format('select count(*)::text from public.estimates where company_id = %L', :'co')) = '0'
                     and tpo_epm.as(:'crew', format('select count(*)::text from public.estimate_versions where company_id = %L', :'co')) = '0', 'crew see no estimates or versions');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'crew', format('select public.estimate_summary(%L)::text', :'e1')), 'nor a summary', '%not found%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'crew', format('select public.create_estimate(%L, gen_random_uuid(), %L)', :'co', 'X')), 'nor can they start one', '%Estimating area%');
select tpo_epm.check(tpo_epm.as(:'other', format('select count(*)::text from public.estimates where company_id = %L', :'co')) = '0', 'another company''s owner sees none of ours');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'other', format('select public.estimate_version_costs(%L)::text', :'v1')), 'nor our costs', '%not found%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'other', format('select public.revise_estimate(%L)::text', :'e1')), 'nor can they revise ours', '%not found%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'other', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2700000-0000-0000-0000-0000000000f9')), 'nor make a document from ours', '%Estimating%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'other', format('select public.create_estimate(%L, gen_random_uuid(), %L, p_client => %L)', :'co2', 'Theirs', :'client')), 'nor start one of theirs for our customer', '%isn''t one of this business''s%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.create_estimate(%L, gen_random_uuid(), %L, p_client => %L)', :'co', 'Ours', :'client_other')), 'and we can''t use theirs', '%isn''t one of this business''s%');
select tpo_epm.expect_error(format('set local role anon; select public.estimate_summary(%L)', :'e1'), 'no one signed in gets nothing', '%permission denied%');
select tpo_epm.expect_error(format('set local role anon; select public.create_quote_from_estimate(%L, %L, gen_random_uuid())', :'v1', 'proposal'), 'nor makes anything', '%permission denied%');
select tpo_epm.expect_error('set local role anon; select count(*) from public.estimate_lines', 'nor reads a table', '%permission denied%');

-- ===== Links that don't belong together are refused ==============================================
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.create_estimate(%L, gen_random_uuid(), %L, p_client => %L, p_property => %L)', :'co', 'Mixed', :'client', :'property_b')),
  'another customer''s property', '%isn''t the estimate''s customer''s%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.create_estimate(%L, gen_random_uuid(), %L, %L, p_client => %L)', :'co', 'Mixed', :'req', :'client_b')),
  'a customer other than the request''s', '%request''s%');
select tpo_epm.as(:'costs', format('select public.revise_estimate(%L)::text', :'e1')) as v2 \gset
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v2', jsonb_build_object('property_id', :'property_b'))),
  'a save can''t move the estimate to another customer''s property', '%isn''t the estimate''s customer''s%');
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v2', jsonb_build_object('estimator_id', :'other'))),
  'or give it an estimator from outside the team', '%on the team%');
insert into public.quotes (company_id, client_id, title) values (:'co', :'client_b', 'B''s own quote') returning id as qb \gset
select tpo_epm.expect_error(format('select tpo_epm.as(%L, %L)', :'costs', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'qb', :'v1', public.estimate_quote_diff(:'qb', :'v1') ->> 'token')),
  'customer B''s quote can''t be filled from customer A''s estimate', '%another customer%');

-- The companies are kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops estimate permission tests passed.'
