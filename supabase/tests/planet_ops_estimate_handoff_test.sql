-- Planet Ops Phase 3: from an internal estimate to an unsent customer document, its versions, the
-- job, and the one summary (20261125000100_planet_ops_estimate_handoff.sql). Fictional numbers only.
-- Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_eh;
grant usage on schema tpo_eh to authenticated, service_role;
create function tpo_eh.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_eh.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_eh.as(p_user uuid, p_sql text) returns text language plpgsql as $$
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
-- An estimate version's lines as the editor sends them back, with one line's count changed.
create function tpo_eh.lines(p_version uuid, p_key text default null, p_count numeric default null) returns jsonb language sql as $$
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'customer_item', customer_item,
           'count', case when key = p_key then p_count else count end, 'hours', hours, 'days', days, 'unit', unit, 'unit_cost', unit_cost, 'risk_pct', risk_pct) order by sort))
    from public.estimate_lines where version_id = p_version
$$;
grant execute on all functions in schema tpo_eh to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2500000-0000-0000-0000-000000000001', 'owner@planet-eh.test', '{"full_name": "Test Owner"}'),
  ('e2500000-0000-0000-0000-000000000002', 'estimator@planet-eh.test', '{"full_name": "Test Estimator"}'),
  ('e2500000-0000-0000-0000-000000000003', 'prep@planet-eh.test', '{"full_name": "Test Preparer"}'),
  ('e2500000-0000-0000-0000-000000000004', 'seller@planet-eh.test', '{"full_name": "Test Seller, no estimating"}');
\set owner 'e2500000-0000-0000-0000-000000000001'
\set est 'e2500000-0000-0000-0000-000000000002'
\set prep 'e2500000-0000-0000-0000-000000000003'
\set seller 'e2500000-0000-0000-0000-000000000004'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition EH', 'general') as co \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'est', 'estimator');
insert into public.company_roles (company_id, name, description, base_role, permissions) values
  (:'co', 'TEST Preparer', 'Prepares; no costs.', 'estimator', array['sales', 'estimate']),
  (:'co', 'TEST Seller', 'Sells; no estimating.', 'estimator', array['sales', 'send_pricing']);
insert into public.memberships (company_id, user_id, role, role_id) values
  (:'co', :'prep', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Preparer')),
  (:'co', :'seller', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Seller'));
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Handoff Customer') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '5 Test Road', 'Testburg', 'CA', '95001') returning id as property \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'House demolition') returning id as req \gset

-- An estimate: $2,000 crew, $1,200 disposal, $300 contingency; 25% markup, no owner pay → $4,375.
select tpo_eh.as(:'est', format('select public.create_estimate(%L, %L, %L, %L, p_project_type => %L)', :'co', 'a2500000-0000-0000-0000-0000000000e1', 'House demolition', :'req', 'House demolition')) as e1 \gset
select current_version_id as v1 from public.estimates where id = :'e1' \gset
select tpo_eh.as(:'est', format($f$select public.save_estimate_version(%L, 0, %L::jsonb)::text$f$, :'v1', $j${
  "scope": {"customer_overview": "Demolish the house and remove its foundation.", "customer_exclusions": "Utility disconnects by the owner.", "site_notes": "INTERNAL: neighbor complains about noise"},
  "pricing_method": "markup", "pricing_pct": 0.25, "owner_pay_method": "none",
  "lines": [
    {"key": "crew", "section": "labor", "name": "Crew (internal wage note)", "count": 4, "hours": 10, "days": 2, "unit": "hour", "unit_cost": 25, "customer_item": "Demolition"},
    {"key": "debris", "section": "disposal", "name": "C&D tons", "count": 12, "unit": "ton", "unit_cost": 100, "customer_item": "Haul-off and disposal"},
    {"key": "contingency", "section": "contingency", "name": "Contingency", "count": 1, "unit": "lump", "unit_cost": 300, "customer_item": "Demolition"}
  ]}$j$));
select tpo_eh.check((select selling_price = 4375 from public.estimate_versions where id = :'v1'), 'the estimate''s calculated selling price is $4,375');

-- ===== A customer document needs an approved estimate (by default) and the right areas =========
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2500000-0000-0000-0000-0000000000f1')),
  'an unapproved estimate can''t become a customer document while approval is required', '%requires an approved estimate%');
select tpo_eh.as(:'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'v1'));
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'seller', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2500000-0000-0000-0000-0000000000f1')),
  'someone who sells but doesn''t estimate can''t make one from it', '%Estimating%');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'brochure', 'a2500000-0000-0000-0000-0000000000f1')),
  'it''s a quote or a proposal', '%quote or a proposal%');

-- ===== Created: an unsent proposal draft, prices only, linked to the exact version ==============
select tpo_eh.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2500000-0000-0000-0000-0000000000f1')) as q1 \gset
select tpo_eh.check(tpo_eh.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a2500000-0000-0000-0000-0000000000f1')) = :'q1'
                    and (select count(*) from public.quotes where company_id = :'co') = 1, 'creating it again (a retry) returns the same draft');
select tpo_eh.check((select status = 'draft' and sent_at is null and presentation = 'proposal' and client_id = :'client' and property_id = :'property' and request_id = :'req' and estimate_version_id = :'v1'
                     from public.quotes where id = :'q1'),
  'an unsent proposal draft for the request''s customer and property, linked to estimate version 1');
select tpo_eh.check((select narrative ->> 'overview' = 'Demolish the house and remove its foundation.' and narrative ->> 'exclusions' = 'Utility disconnects by the owner.' and not (narrative::text like '%INTERNAL%') from public.quotes where id = :'q1'),
  'its narrative is the customer-facing scope only, never internal site notes');
select tpo_eh.check((select string_agg(name || '=' || unit_price, ', ' order by sort) from public.quote_line_items where quote_id = :'q1') = 'Demolition=2875.00, Haul-off and disposal=1500.00',
  'its lines are the customer items at their selling prices, adding up to $4,375');
select tpo_eh.check((select bool_and(unit_cost is null and unit_labor_cost is null and material_cost is null and name not like '%internal%' and name not like '%tons%') from public.quote_line_items where quote_id = :'q1'),
  'no cost, wage or internal line name crosses into the document');
select tpo_eh.check(not exists (select 1 from public.job_folder_provisioning where company_id = :'co') and not exists (select 1 from public.jobs where company_id = :'co'),
  'making the document makes no job or folder');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('update public.quotes set estimate_version_id = null where id = %L', :'q1')), 'staff can''t change the document''s estimate link by hand', '%estimate link%');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('insert into public.quotes (company_id, client_id, title, estimate_version_id) values (%L, %L, %L, %L)', :'co', :'client', 'Fake', :'v1')), 'nor make one claiming an estimate', '%estimate link%');
select tpo_eh.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'line_items', 'a2500000-0000-0000-0000-0000000000f2')) as q2 \gset
select tpo_eh.check((select presentation = 'line_items' and status = 'draft' from public.quotes where id = :'q2'),
  'a line-item quote can be made from the same version');

-- ===== Separate histories: negotiating the document leaves the estimate; revising the estimate leaves the document
update public.quote_line_items set unit_price = 2600 where quote_id = :'q1' and name = 'Demolition';
select tpo_eh.check((select selling_price = 4375 and base_cost = 3500 from public.estimate_versions where id = :'v1'), 'a negotiated price on the document doesn''t change the estimate');
select tpo_eh.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e1', 'Larger foundation')) as v2 \gset
select tpo_eh.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v2', tpo_eh.lines(:'v2', 'debris', 15)));
select tpo_eh.check((select sum(unit_price) = 4100 from public.quote_line_items where quote_id = :'q1'), 'revising the estimate doesn''t change the document');
select tpo_eh.as(:'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'v2'));
select tpo_eh.as(:'est', format('select public.estimate_quote_diff(%L, %L)::text', :'q1', :'v2')) as diff \gset
select tpo_eh.check((:'diff'::jsonb ->> 'current_subtotal')::numeric = 4100 and (:'diff'::jsonb ->> 'proposed_subtotal')::numeric = 4750
                    and (:'diff'::jsonb ->> 'from_version')::int = 1 and (:'diff'::jsonb ->> 'to_version')::int = 2,
  'the differences show before refreshing: now $4,100 (negotiated), version 2 gives $4,750');
select tpo_eh.as(:'est', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'q1', :'v2', :'diff'::jsonb ->> 'token'));
select tpo_eh.check((select estimate_version_id = :'v2' from public.quotes where id = :'q1') and (select sum(unit_price) = 4750 from public.quote_line_items where quote_id = :'q1'),
  'refreshed on purpose: version 2''s prices and link');

-- ===== Sent and signed: each issued version keeps its estimate version; signed, it can't be refreshed
update public.quotes set status = 'sent', sent_at = now() where id = :'q1';
select tpo_eh.check((select estimate_version_id = :'v2' from public.quote_versions where quote_id = :'q1' and number = 1), 'the issued version keeps the estimate version it carried');
select planet_test.sign(:'q1');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'q1', :'v2', public.estimate_quote_diff(:'q1', :'v2') ->> 'token')), 'a signed document can''t be refreshed', '%Only an unsigned%');
-- A newer estimate version exists before the job is made: the job still takes the signed one's.
select tpo_eh.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e1', 'After signing')) as v3 \gset
select tpo_eh.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v3', tpo_eh.lines(:'v3', 'debris', 20)));
select tpo_eh.as(:'owner', format('select public.approve_estimate_version(%1$L, (select revision from public.estimate_versions where id = %1$L))::text', :'v3'));
select tpo_eh.as(:'est', format('select public.convert_quote_to_job(%L)::text', :'q1')) as job \gset
select tpo_eh.check((select estimate_version_id = :'v2' and quote_version_id is not null from public.jobs where id = :'job'), 'the job links estimate version 2 (the signed version''s), not the newer version 3');
select tpo_eh.check(tpo_eh.as(:'est', format('select public.convert_quote_to_job(%L)::text', :'q1')) = :'job' and (select count(*) from public.jobs where quote_id = :'q1') = 1, 'converting again: the same job');
select tpo_eh.check((select drive_destination = 'job' and job_id = :'job' and drive_status = 'not_backed_up' from public.estimate_summaries where estimate_id = :'e1'),
  'the summary''s permanent copy now belongs with the job (still not backed up)');
select tpo_eh.check((select count(*) = 1 from public.job_folder_provisioning where company_id = :'co'), 'one folder handoff, for the job only');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('update public.jobs set estimate_version_id = %L where id = %L', :'v3', :'job')), 'staff can''t move the job to another estimate version', '%keeps the estimate version%');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'est', format('insert into public.jobs (company_id, client_id, title, estimate_version_id) values (%L, %L, %L, %L)', :'co', :'client', 'Direct', :'v3')), 'nor make a job claiming one', '%estimate version is set only%');
-- A document with no estimate converts as before, with none; Create Job too.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Legacy shed') returning id as legacy \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'legacy', 'Remove shed', 1, 'ea', 900);
update public.quotes set status = 'sent', sent_at = now() where id = :'legacy';
select planet_test.sign(:'legacy');
select public.convert_quote_to_job(:'legacy') as legacy_job \gset
select tpo_eh.check((select estimate_version_id is null from public.jobs where id = :'legacy_job'), 'a document made without an estimate makes a job without one: no link is guessed');
select tpo_eh.as(:'est', format('insert into public.jobs (company_id, client_id, title) values (%L, %L, %L) returning id::text', :'co', :'client', 'Direct job')) as direct \gset
select tpo_eh.check((select estimate_version_id is null and quote_version_id is null from public.jobs where id = :'direct'), 'Create Job links no estimate');

-- ===== The summary: one, current, private ========================================================
select tpo_eh.as(:'est', format('select public.estimate_summary(%L)::text', :'e1')) as summary \gset
select tpo_eh.check((select count(*) from public.estimate_summaries where estimate_id = :'e1') = 1, 'still one summary after every save, approval, document and job');
select tpo_eh.check((:'summary'::jsonb -> 'version' ->> 'number')::int = 3 and jsonb_array_length(:'summary'::jsonb -> 'versions') = 3
                    and (:'summary'::jsonb -> 'versions' -> 0 ->> 'baseline')::boolean and (:'summary'::jsonb -> 'versions' -> 0 ->> 'selling_price')::numeric = 4375,
  'it shows the current version and every version with its dated figures, version 1 the baseline');
select tpo_eh.check((select bool_or((d -> 'sent' -> 0 ->> 'total')::numeric = 4750 and (d -> 'sent' -> 0 ->> 'estimate_version')::int = 2 and (d -> 'accepted' ->> 'total')::numeric = 4750)
                     from jsonb_array_elements(:'summary'::jsonb -> 'documents') d),
  'the price actually sent and the price accepted, from the document, apart from the calculated price');
select tpo_eh.check((:'summary'::jsonb -> 'jobs' -> 0 ->> 'estimate_version')::int = 2 and (:'summary'::jsonb -> 'request' ->> 'number') is not null, 'its job and its request');
select tpo_eh.as(:'prep', format('select public.estimate_summary(%L)::text', :'e1')) as prep_summary \gset
select tpo_eh.check(not (:'prep_summary'::jsonb ->> 'costs_visible')::boolean and (:'prep_summary'::jsonb -> 'version' -> 'totals') = 'null'::jsonb
                    and not (:'prep_summary'::jsonb::text like '%unit_cost%') and not (:'prep_summary'::jsonb::text like '%selling_price%'),
  'someone without cost access gets the summary without a single cost, total or price');
select tpo_eh.expect_error(format('select tpo_eh.as(%L, %L)', :'seller', format('select public.estimate_summary(%L)::text', :'e1')), 'someone without estimating gets none', '%not found%');
select tpo_eh.expect_error(format('set local role anon; select public.estimate_summary(%L)', :'e1'), 'nor does anyone not signed in', '%permission denied%');

-- A lost, unanswered opportunity keeps its estimate, summary and history.
select tpo_eh.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2500000-0000-0000-0000-0000000000e2', 'Barn removal', :'req')) as e2 \gset
update public.requests set stage_id = (select id from public.pipeline_stages where company_id = :'co' and system_key = 'lost'), outcome_reason = 'No reply after three follow-ups' where id = :'req';
select tpo_eh.check((select (s -> 'request' ->> 'stage_kind') = 'lost' and (s -> 'request' ->> 'outcome_reason') = 'No reply after three follow-ups' and s -> 'summary' ->> 'drive_destination' = 'jobs_bid'
                     from (select public.estimate_summary(:'e2') as s) x),
  'a lost bid''s estimate keeps its summary (bound for Jobs Bid) with the reason it was lost, none invented');

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops estimate handoff tests passed.'
