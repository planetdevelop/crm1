-- Database tests for 20261113000810_job_costs_count_once.sql: a calculator line's labor goes from the
-- quote line to the job's line with its parts; lines the calculator priced before this get their
-- labor from their worksheets, on the quote and on the job, without touching either's updated_at;
-- an expense can be marked as already in the line item costs; and the Log material list knows
-- what's on a job by name and unit, for the office and the crew on it, and nobody else.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_jco;
grant usage on schema t_jco to authenticated, service_role;
create sequence t_jco.passed;
grant usage on sequence t_jco.passed to authenticated, service_role;
create function t_jco.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_jco.passed');
  raise notice 'ok - %', p_what;
end $$;
grant execute on all functions in schema t_jco to authenticated, service_role;

-- Pia owns Pine Paving; Cole is on its crew, Dee is crew who isn't on the job; Rex owns Reed Roofing.
insert into auth.users (id, email, raw_user_meta_data) values
  ('c0570000-0000-0000-0000-000000000001', 'pia@pine-paving.test', '{"full_name": "Pia Pine"}'),
  ('c0570000-0000-0000-0000-000000000002', 'cole@pine-paving.test', '{"full_name": "Cole Pine"}'),
  ('c0570000-0000-0000-0000-000000000003', 'dee@pine-paving.test', '{"full_name": "Dee Pine"}'),
  ('c0570000-0000-0000-0000-000000000009', 'rex@reed-roofing.test', '{"full_name": "Rex Reed"}');

\set parts '[{"id": "top", "name": "Top coat asphalt", "unit": "ton", "quantity": 147, "unit_cost": 100, "material": true, "work": "asphalt"}, {"id": "liquid", "name": "Tack coat", "unit": "gal", "quantity": 134, "unit_cost": 4.5, "material": true}, {"id": "fullCrew", "name": "Full crew", "unit": "day", "quantity": 2, "unit_cost": 5000}, {"id": "blank", "name": " ", "unit": "ton", "quantity": 1, "unit_cost": 1, "material": true}]'
-- A worksheet as the calculator saves it: two full-crew days at $5,000, half a day of the half crew at $2,500, and a truck that isn't crew.
\set sheet '{"v": 1, "setup": {"items": [{"id": "top", "name": "Top coat asphalt", "section": "Asphalt", "basis": "depth", "price": 100}, {"id": "fullCrew", "name": "Full crew", "section": "Crew", "basis": "days", "price": 5000, "crew": true}, {"id": "halfCrew", "name": "Half crew", "section": "Crew", "basis": "days", "price": 2500, "crew": true}, {"id": "truck", "name": "Truck hire", "section": "Crew", "basis": "days", "price": 800}], "jobs": []}, "input": {"values": {"top": 2, "fullCrew": 2, "halfCrew": 0.5, "truck": 3}}, "overrides": {}}'

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0570000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Pine Paving', 'paving') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', 'c0570000-0000-0000-0000-000000000002', 'field_crew'), (:'co', 'c0570000-0000-0000-0000-000000000003', 'field_crew');
insert into public.services (company_id, name, unit, unit_price, unit_cost) values (:'co', 'Pine sealcoat', 'sq ft', 0.28, 0.14) returning id as seal \gset
insert into public.clients (company_id, display_name) values (:'co', 'Pine Client Ada') returning id as client \gset

-- ===== A quote priced now ======================================================================
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Pine lot') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, unit_labor_cost, sort, parts)
values (:'co', :'quote', 'New asphalt paving', 1, 'job', 39303, 25303, 10000, 1, :'parts'::jsonb);
insert into public.quote_line_items (company_id, quote_id, service_id, name, quantity, unit, unit_price, unit_cost, sort)
values (:'co', :'quote', :'seal', 'Sealcoat the old lot', 4000, 'sq ft', 0.28, 0.14, 2);
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, sort) values (:'co', :'quote', 'Permit', 1, 'ea', 150, 3);
select planet_test.sign(:'quote');
select public.convert_quote_to_job(planet_test.sign(:'quote')) as job \gset
select t_jco.check((select unit_labor_cost = 10000 and parts = :'parts'::jsonb from public.job_line_items where job_id = :'job' and name = 'New asphalt paving'),
  'a quote turned into a job: the calculator line''s labor goes onto the job''s line with its parts');
select t_jco.check((select unit_labor_cost is null and parts is null from public.job_line_items where job_id = :'job' and name = 'Permit'), 'a plain line with no price list item gets neither');
select t_jco.check((select unit_labor_cost is null from public.job_line_items where job_id = :'job' and service_id = :'seal'), 'and a price list line still takes its item''s labor (none here)');

-- ===== What's on the job, for the Log material list =============================================
select t_jco.check((select array_agg(name || ' / ' || unit order by name) from public.job_estimated_materials(:'job')) = '{"Pine sealcoat / sq ft","Tack coat / gal","Top coat asphalt / ton"}',
  'the job''s price list items by their own names, and its calculator line''s materials (not its crew days, nor a part with no name)');
select t_jco.check((select service_id = :'seal' from public.job_estimated_materials(:'job') where name = 'Pine sealcoat') and (select service_id is null from public.job_estimated_materials(:'job') where name = 'Tack coat'),
  'each with its price list item, where it has one');
insert into public.visits (company_id, job_id, title, starts_at, ends_at) values (:'co', :'job', 'Pine pave', now() + interval '1 day', now() + interval '1 day 8 hours') returning id as visit \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'visit', 'c0570000-0000-0000-0000-000000000002');

-- ===== An expense already in the line items =====================================================
insert into public.expenses (company_id, job_id, amount, incurred_on, vendor) values (:'co', :'job', 14950, current_date, 'Pine Asphalt Plant') returning id as expense \gset
select t_jco.check((select not in_line_costs from public.expenses where id = :'expense'), 'an expense isn''t marked as in the line items until the office says');
update public.expenses set in_line_costs = true where id = :'expense';
select t_jco.check((select in_line_costs from public.expenses where id = :'expense'), 'the office marks it');
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0570000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select t_jco.check(not exists (select from public.job_line_items where job_id = :'job'), 'Cole on the crew can''t read the job''s lines');
select t_jco.check((select count(*) = 3 from public.job_estimated_materials(:'job')), 'but gets what to log materials against, by name and unit');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0570000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select t_jco.check(not exists (select from public.job_estimated_materials(:'job')), 'crew who aren''t on the job get nothing');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0570000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
select public.create_company('Reed Roofing', 'roofing_exteriors') as other \gset
select t_jco.check(not exists (select from public.job_estimated_materials(:'job')), 'nor does another business');
commit;
select t_jco.check(not has_function_privilege('anon', 'public.job_estimated_materials(uuid)', 'execute'), 'and nobody signed out can ask');

-- ===== Lines the calculator priced before this ==================================================
\o
\echo 'Labor for lines already priced'
\o /dev/null
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0570000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
-- An old quote and its job: the line has the bid's cost and nothing about labor. Its worksheet has.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Pine old drive') returning id as old_quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, sort) values (:'co', :'old_quote', 'Mill and overlay', 1, 'job', 40000, 28000, 1) returning id as old_line \gset
insert into public.paving_worksheets (company_id, quote_id, line_id, name, data) values (:'co', :'old_quote', :'old_line', 'Mill and overlay', :'sheet'::jsonb);
select planet_test.sign(:'old_quote');
select public.convert_quote_to_job(planet_test.sign(:'old_quote')) as old_job \gset
-- A line whose cost was typed down below the worksheet's labor: nothing can be said about it.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Pine odd drive') returning id as odd_quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, sort) values (:'co', :'odd_quote', 'Mill and overlay', 1, 'job', 9000, 6000, 1) returning id as odd_line \gset
insert into public.paving_worksheets (company_id, quote_id, line_id, name, data) values (:'co', :'odd_quote', :'odd_line', 'Mill and overlay', :'sheet'::jsonb);
-- A crew item with choices is priced by the one picked, which this can't know.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Pine choice drive') returning id as choice_quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, unit_cost, sort) values (:'co', :'choice_quote', 'Mill and overlay', 1, 'job', 40000, 28000, 1) returning id as choice_line \gset
insert into public.paving_worksheets (company_id, quote_id, line_id, name, data)
values (:'co', :'choice_quote', :'choice_line', 'Mill and overlay', jsonb_set(:'sheet'::jsonb, '{setup,items,1,choices}', '[{"label": "Night", "value": 2, "price": 7000}]'));
commit;

select updated_at as quote_was from public.quotes where id = :'old_quote' \gset
select updated_at as job_was from public.jobs where id = :'old_job' \gset
select t_jco.check((select unit_labor_cost is null from public.job_line_items where job_id = :'old_job'), 'before: the old job''s line says nothing about labor');
select t_jco.check(private.fill_calculator_labor() = 1, 'one quote line gets its labor from its worksheet');
select t_jco.check((select unit_labor_cost = 11250 from public.quote_line_items where id = :'old_line'), 'its crew days at their day prices: 2 full days and half a half-crew day, not the truck');
select t_jco.check((select unit_labor_cost = 11250 from public.job_line_items where job_id = :'old_job'), 'and so does the line of the job made from it');
select t_jco.check((select updated_at = :'quote_was' from public.quotes where id = :'old_quote') and (select updated_at = :'job_was' from public.jobs where id = :'old_job'),
  'without the quote or the job counting as changed');
select t_jco.check((select unit_labor_cost is null from public.quote_line_items where id = :'odd_line'), 'a line that costs less than the worksheet''s labor is left alone');
select t_jco.check((select unit_labor_cost is null from public.quote_line_items where id = :'choice_line'), 'as is one whose crew item has choices');
select t_jco.check((select unit_labor_cost = 10000 from public.quote_line_items where quote_id = :'quote' and name = 'New asphalt paving'), 'a line that already says keeps what it says');
select t_jco.check(private.fill_calculator_labor() = 0, 'run again, it changes nothing');
select t_jco.check((select tgenabled = 'O' from pg_trigger where tgname = 'touch_quote' and tgrelid = 'public.quote_line_items'::regclass)
  and (select tgenabled = 'O' from pg_trigger where tgname = 'touch_job' and tgrelid = 'public.job_line_items'::regclass), 'and the triggers it worked around are back on');

\o
select format('All %s job-costs-once checks passed.', last_value) from t_jco.passed \gset
\echo :format
