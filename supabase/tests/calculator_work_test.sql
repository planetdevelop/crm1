-- Database tests for 20261113000800_calculator_work_for_weather_and_checklists.sql: a line priced
-- with the paving calculator keeps what it's made of, and the job's line takes it from its quote
-- line; a weather rule can be for a kind of calculator work; a checklist comes up on every job, or
-- on calculator jobs with its kind of work, for the crew too; and a paving business's starter rules
-- and checklist are extended to calculator work, once, leaving what it saved as it was.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_cw;
grant usage on schema t_cw to authenticated, service_role;
create sequence t_cw.passed;
grant usage on sequence t_cw.passed to authenticated, service_role;
create function t_cw.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_cw.passed');
  raise notice 'ok - %', p_what;
end $$;
create function t_cw.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then perform nextval('t_cw.passed'); raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema t_cw to authenticated, service_role;

-- Vera owns Vale Paving; Kit is on its crew; Ron owns Rook Roofing.
insert into auth.users (id, email, raw_user_meta_data) values
  ('ca1c0000-0000-0000-0000-000000000001', 'vera@vale-paving.test', '{"full_name": "Vera Vale"}'),
  ('ca1c0000-0000-0000-0000-000000000002', 'kit@vale-paving.test', '{"full_name": "Kit Vale"}'),
  ('ca1c0000-0000-0000-0000-000000000009', 'ron@rook-roofing.test', '{"full_name": "Ron Rook"}');

\set parts '[{"id": "top", "name": "Top coat asphalt", "unit": "ton", "quantity": 147, "unit_cost": 100, "material": true, "work": "asphalt"}, {"id": "stone21a", "name": "Base stone", "unit": "ton", "quantity": 587, "unit_cost": 30, "material": true, "work": "stone"}, {"id": "fullCrew", "name": "Full crew", "unit": "day", "quantity": 2, "unit_cost": 5000}]'

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "ca1c0000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Vale Paving', 'paving') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', 'ca1c0000-0000-0000-0000-000000000002', 'field_crew');
insert into public.services (company_id, name, unit, unit_price, unit_cost) values (:'co', 'Hot-mix asphalt surface', 'ton', 143, 92) returning id as hotmix \gset
insert into public.services (company_id, name, unit, unit_price) values (:'co', 'Sealcoat', 'sq ft', 0.28) returning id as seal \gset
insert into public.clients (company_id, display_name) values (:'co', 'Vale Client Ada') returning id as client \gset

-- A quote with one calculator line (no price list item) and one price list line.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Vale driveway') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, sort, parts)
values (:'co', :'quote', 'New asphalt paving', 1, 'job', 56310, 42310, 1, :'parts'::jsonb);
insert into public.quote_line_items (company_id, quote_id, service_id, name, quantity, unit, unit_price, unit_cost, sort)
values (:'co', :'quote', :'seal', 'Sealcoat', 4000, 'sq ft', 0.28, 0.14, 2);
select t_cw.expect_error(format('insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, parts) values (%L, %L, %L, 1, %L, 10, %L)', :'co', :'quote', 'Bad parts', 'job', '{"work": "asphalt"}'),
  'a line''s parts are a list');
update public.quotes set status = 'approved' where id = :'quote';
select public.convert_quote_to_job(:'quote') as job \gset
select t_cw.check((select parts = :'parts'::jsonb from public.job_line_items where job_id = :'job' and name = 'New asphalt paving'),
  'a quote turned into a job: the calculator line''s parts go onto the job''s line');
select t_cw.check((select parts is null from public.job_line_items where job_id = :'job' and service_id = :'seal'), 'a price list line has none');

-- A line added to the job by hand with the same name but another price takes nothing.
insert into public.job_line_items (company_id, job_id, name, quantity, unit, unit_price, unit_cost, sort) values (:'co', :'job', 'New asphalt paving', 1, 'job', 999, 500, 9);
select t_cw.check((select parts is null from public.job_line_items where job_id = :'job' and unit_price = 999), 'a line added by hand that isn''t the quote''s line takes none');

-- A change order with a calculator line adds its parts to the job too.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Vale apron', :'job') returning id as change \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, sort, parts)
values (:'co', :'change', 'Tar and chip', 1, 'job', 4000, 2500, 1, '[{"id": "stone8", "name": "#8 stone", "unit": "ton", "quantity": 9, "unit_cost": 30, "material": true, "work": "tar_chip"}]');
commit;
-- The customer signs it (the server records the signature: 20261120000100).
update public.quotes set status = 'approved', approval = jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'signature', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'total', total, 'seen_fingerprint', private.quote_fingerprint(id)) where id = :'change';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "ca1c0000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select t_cw.check((select parts -> 0 ->> 'work' = 'tar_chip' from public.job_line_items where job_id = :'job' and name = 'Tar and chip'),
  'an approved change order''s calculator line brings its parts');

-- ===== Checklists ===============================================================================
insert into public.checklist_templates (company_id, name, items, work) values (:'co', 'Vale asphalt check', '[]', '{asphalt}') returning id as asphalt_list \gset
insert into public.checklist_templates (company_id, name, items, work) values (:'co', 'Vale striping check', '[]', '{striping}') returning id as stripe_list \gset
insert into public.checklist_templates (company_id, name, items, every_job) values (:'co', 'Vale safety', '[]', true) returning id as safety_list \gset
insert into public.checklist_templates (company_id, name, items, every_job, active) values (:'co', 'Vale old safety', '[]', true, false) returning id as old_list \gset
insert into public.checklist_templates (company_id, name, items) values (:'co', 'Vale seal check', '[]') returning id as seal_list \gset
insert into public.checklist_templates (company_id, name, items) values (:'co', 'Vale pick me', '[]') returning id as any_list \gset
select public.set_checklist_services(:'seal_list', array[:'seal']::uuid[]);
select t_cw.expect_error(format('insert into public.checklist_templates (company_id, name, items, work) values (%L, %L, %L, %L)', :'co', 'Vale bad', '[]', '{roofing}'),
  'a checklist''s kinds of work are the calculator''s');
select t_cw.check((select array_agg(c order by c) from public.job_checklists(:'job') c) = (select array_agg(id order by id) from public.checklist_templates where id in (:'asphalt_list', :'safety_list', :'seal_list')),
  'a calculator job brings up the checklist for its kind of work, the one for every job and the one its price list item goes with, each once');

-- A job with no lines at all still gets the every-job checklist, and only that.
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Vale bare job') returning id as bare \gset
select t_cw.check((select array_agg(c) from public.job_checklists(:'bare') c) = array[:'safety_list']::uuid[], 'a job with nothing on it gets the every-job checklist, turned-off ones aside');

insert into public.visits (company_id, job_id, title, starts_at, ends_at) values (:'co', :'job', 'Vale pave', now() + interval '1 day', now() + interval '1 day 8 hours') returning id as visit \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'visit', 'ca1c0000-0000-0000-0000-000000000002');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "ca1c0000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select t_cw.check(not exists (select from public.job_line_items where job_id = :'job'), 'Kit on the crew can''t read the job''s lines or their parts');
select t_cw.check((select count(*) from public.job_checklists(:'job')) = 3, 'but on his visit he gets the three checklists they bring up');
select t_cw.check(not exists (select from public.job_checklists(:'bare')), 'and nothing for a job he isn''t on');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "ca1c0000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
select public.create_company('Rook Roofing', 'roofing_exteriors') as other \gset
select t_cw.check(not exists (select from public.job_checklists(:'job')), 'another business gets nothing of the job');
commit;

-- ===== Weather rules ============================================================================
\o
\echo 'Weather rules for calculator work'
\o /dev/null
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "ca1c0000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.set_weather_rules(:'co', format('[{"service_id": %s, "min_temp_f": 50, "max_rain_pct": 40}, {"work": "asphalt", "applies_to": "anything", "service_id": %s, "min_temp_f": 50},
  {"work": "sealcoat", "requires_dry_hours": 24}, {"max_wind_mph": 30}]', to_jsonb(:'hotmix'::text), to_jsonb(:'seal'::text))::jsonb) as saved \gset
select t_cw.check(:'saved'::jsonb -> 0 = jsonb_build_object('applies_to', 'Hot-mix asphalt surface', 'service_id', :'hotmix', 'min_temp_f', 50, 'max_rain_pct', 40), 'a rule for a price list item is saved as before');
select t_cw.check(:'saved'::jsonb -> 1 = '{"work": "asphalt", "applies_to": "Hot-mix asphalt (paving calculator)", "min_temp_f": 50}',
  'a rule for a kind of calculator work keeps the kind, is called by it, and names no price list item');
select t_cw.check(:'saved'::jsonb -> 2 = '{"work": "sealcoat", "applies_to": "Sealcoat (paving calculator)", "requires_dry_hours": 24}' and :'saved'::jsonb -> 3 = '{"max_wind_mph": 30}',
  'a kind whose name is also an item''s stays a kind, and a rule for every job stays one');
select t_cw.expect_error(format('select public.set_weather_rules(%L, %L)', :'co', '[{"work": "roofing", "min_temp_f": 40}]'), 'a kind the calculator doesn''t have is turned down');
select t_cw.expect_error(format('select public.set_weather_rules(%L, %L)', :'co', '[{"work": 7, "min_temp_f": 40}]'), 'as is one that isn''t a word');
select t_cw.expect_error(format('select public.set_weather_rules(%L, %L)', :'co', '[{"work": "asphalt"}]'), 'and a kind with no limit');
commit;

-- ===== Paving businesses already here ==========================================================
\o
\echo 'Extending the starter rules and checklist'
\o /dev/null
-- Vale as it was before kinds: the starter rules by item, a wind rule of its own, and the starter
-- checklist on its hot-mix item.
update public.companies set settings = settings || jsonb_build_object('paving_app', '{"enabled": true}'::jsonb, 'weather_rules', format('[{"applies_to": "Hot-mix asphalt surface", "service_id": %s, "min_temp_f": 45, "max_rain_pct": 30},
  {"applies_to": "Sealcoat", "min_temp_f": 55, "requires_dry_hours": 36}, {"max_wind_mph": 30}, "not a rule"]', to_jsonb(:'hotmix'::text))::jsonb) where id = :'co';
insert into public.checklist_templates (company_id, name, items) values (:'co', 'Vale driveway check', '[]') returning id as drive_list \gset
insert into public.checklist_template_services (company_id, template_id, service_id) values (:'co', :'drive_list', :'hotmix');
-- Rook has a rule for an item called Sealcoat, but no Paving: left alone.
update public.companies set settings = settings || '{"weather_rules": [{"applies_to": "Sealcoat", "min_temp_f": 50}]}' where id = :'other';
select t_cw.check(private.add_calculator_work() = 1, 'one business gets rules for calculator work');
select t_cw.check((select jsonb_array_length(settings -> 'weather_rules') = 6 and settings -> 'weather_rules' -> 0 ->> 'min_temp_f' = '45' and settings -> 'weather_rules' -> 3 = '"not a rule"'
  from public.companies where id = :'co'), 'what it had saved stays as it was, in its order');
select t_cw.check((select settings -> 'weather_rules' -> 4 = '{"work": "asphalt", "applies_to": "Hot-mix asphalt (paving calculator)", "min_temp_f": 45, "max_rain_pct": 30}'
  and settings -> 'weather_rules' -> 5 = '{"work": "sealcoat", "applies_to": "Sealcoat (paving calculator)", "min_temp_f": 55, "requires_dry_hours": 36}'
  from public.companies where id = :'co'), 'its asphalt and sealcoat limits, as it set them, now cover calculator work too');
select t_cw.check((select work = '{asphalt}' from public.checklist_templates where id = :'drive_list') and (select work = '{}' from public.checklist_templates where id = :'seal_list'),
  'the checklist on its hot-mix item comes up on calculator asphalt jobs too, and no other checklist changes');
select t_cw.check((select settings -> 'weather_rules' = '[{"applies_to": "Sealcoat", "min_temp_f": 50}]' from public.companies where id = :'other'), 'a business without Paving is left alone');
select t_cw.check(private.add_calculator_work() = 0 and (select jsonb_array_length(settings -> 'weather_rules') = 6 from public.companies where id = :'co'), 'run again, it adds nothing');
-- Two rules for the same item: which limits were meant isn't plain, so nothing is added.
update public.companies set settings = settings || '{"weather_rules": [{"applies_to": "Sealcoat", "min_temp_f": 50}, {"applies_to": "sealcoat", "requires_dry_hours": 24}]}' where id = :'co';
select t_cw.check(private.add_calculator_work() = 0, 'two rules for the item: nothing is guessed');

\o
select format('All %s calculator work checks passed.', last_value) from t_cw.passed \gset
\echo :format
