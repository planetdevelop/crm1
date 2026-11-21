-- Planet Ops Phase 2 follow-ups, verified as implemented (20261123000100_planet_ops_pipeline_followups.sql):
-- resuming keeps each reminder's own due date (today if it was overdue) and doesn't restart the
-- cadence from the day of resuming; dates are the company's, not the server's; only people in sales
-- move a request to Won. Fictional records only. Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_rp;
grant usage on schema tpo_rp to authenticated, service_role;
create function tpo_rp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_rp.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_rp.as(p_user uuid, p_sql text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute p_sql;
  reset role;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role;
  perform set_config('request.jwt.claims', '', true);
  raise;
end $$;
grant execute on all functions in schema tpo_rp to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2900000-0000-0000-0000-000000000001', 'owner@planet-rp.test', '{"full_name": "Test Owner"}'),
  ('e2900000-0000-0000-0000-000000000002', 'sales@planet-rp.test', '{"full_name": "Test Salesperson"}'),
  ('e2900000-0000-0000-0000-000000000003', 'estonly@planet-rp.test', '{"full_name": "Test Estimator, no sales"}'),
  ('e2900000-0000-0000-0000-000000000004', 'crew@planet-rp.test', '{"full_name": "Test Crew"}');
\set owner 'e2900000-0000-0000-0000-000000000001'
\set sales 'e2900000-0000-0000-0000-000000000002'
\set estonly 'e2900000-0000-0000-0000-000000000003'
\set crew 'e2900000-0000-0000-0000-000000000004'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition RP', 'general') as co \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'sales', 'office'), (:'co', :'crew', 'field_crew');
insert into public.company_roles (company_id, name, description, base_role, permissions) values (:'co', 'TEST Estimating only', 'Estimates; no sales.', 'estimator', array['estimate', 'estimate_costs']);
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', :'estonly', 'estimator', (select id from public.company_roles where company_id = :'co' and name = 'TEST Estimating only'));
select id as s_est from public.pipeline_stages where company_id = :'co' and system_key = 'estimating' \gset
select id as s_won from public.pipeline_stages where company_id = :'co' and system_key = 'won' \gset
select private.company_today(:'co') as today \gset
-- The Estimating stage's cadence, for this test: a call 5 days in, an email 4 days in (added later).
update public.pipeline_cadence_steps set active = false where company_id = :'co' and stage_id = :'s_est';
insert into public.pipeline_cadence_steps (company_id, stage_id, after_days, title, channel, sort) values (:'co', :'s_est', 5, 'TEST call back', 'call', 1) returning id as step5 \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Resume Customer') returning id as client \gset
insert into public.requests (company_id, client_id, title, assigned_to) values (:'co', :'client', 'Deck removal', :'sales') returning id as req \gset
select tpo_rp.as(:'sales', format('update public.requests set stage_id = %L where id = %L', :'s_est', :'req'));
-- As if it entered Estimating 3 days ago: its call is due in 2 days.
-- (History is kept as it happened: the test steps around its guard for this one fixture.)
set session_replication_role = replica;
update public.request_pipeline_events set created_at = now() - interval '3 days' where request_id = :'req' and kind = 'stage' and to_stage_id = :'s_est';
reset session_replication_role;
select id as call from public.follow_up_tasks where related_id = :'req' and title like 'TEST call back%' \gset
update public.follow_up_tasks set due_on = :'today'::date + 2 where id = :'call';

-- ===== Resuming keeps each reminder's own date ====================================================
select tpo_rp.as(:'sales', format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
-- A step added to the cadence while it was paused: it's due 4 days after the stage was entered.
insert into public.pipeline_cadence_steps (company_id, stage_id, after_days, title, channel, sort) values (:'co', :'s_est', 4, 'TEST email check-in', 'email', 2);
select tpo_rp.as(:'sales', format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_rp.check((select done_at is null and due_on = :'today'::date + 2 from public.follow_up_tasks where id = :'call'),
  'the reopened call keeps its own date (in 2 days), not 5 days from the day of resuming');
select tpo_rp.check((select due_on = :'today'::date + 1 from public.follow_up_tasks where related_id = :'req' and title like 'TEST email check-in%'),
  'a reminder the pause kept from being made is due 4 days from entering the stage (tomorrow), not from resuming');
-- Overdue while paused: due today.
select tpo_rp.as(:'sales', format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
update public.follow_up_tasks set due_on = :'today'::date - 6 where id = :'call';
select tpo_rp.as(:'sales', format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_rp.check((select done_at is null and due_on = :'today'::date from public.follow_up_tasks where id = :'call'), 'a reminder that fell overdue while paused is due today');
select tpo_rp.check((select count(*) from public.follow_up_tasks where related_id = :'req' and done_at is null) = 2, 'and still exactly the two reminders');

-- ===== Dates are the company's ==================================================================
-- A time zone whose date isn't the server's right now (ahead or behind, depending on the hour).
update public.companies set timezone = case when (now() at time zone 'Pacific/Kiritimati')::date <> (now() at time zone 'UTC')::date then 'Pacific/Kiritimati' else 'Pacific/Pago_Pago' end where id = :'co';
select private.company_today(:'co') as ctoday, (now() at time zone 'UTC')::date as utoday \gset
select tpo_rp.check(:'ctoday'::date <> :'utoday'::date, 'the company''s date differs from the server''s for this check');
select tpo_rp.as(:'sales', format('update public.follow_up_tasks set due_on = %L where id = %L', :'ctoday', :'call'));
select tpo_rp.check((select due_on = :'ctoday'::date from public.follow_up_tasks where id = :'call'), 'snoozing to the company''s today is allowed');
select tpo_rp.expect_error(format('select tpo_rp.as(%L, %L)', :'sales', format('update public.follow_up_tasks set due_on = %L where id = %L', :'ctoday'::date - 1, :'call')),
  'and to the company''s yesterday is refused, whatever the server''s date', '%today or a later day%');
select tpo_rp.check((select next_action_on is distinct from :'ctoday'::date - 1 from public.requests where id = :'req'), 'nothing moved');

-- ===== Won: people in sales, with a note =========================================================
select tpo_rp.expect_error(format('select tpo_rp.as(%L, %L)', :'estonly', format('update public.requests set stage_id = %L, outcome_reason = %L where id = %L', :'s_won', 'Says yes', :'req')),
  'estimating without sales can''t move the pipeline', '%needs the Sales area%');
-- Crew don't see the request at all (the update reaches no row).
select tpo_rp.as(:'crew', format('update public.requests set stage_id = %L, outcome_reason = %L where id = %L', :'s_won', 'Says yes', :'req'));
select tpo_rp.check((select stage_id = :'s_est' from public.requests where id = :'req')
                    and not exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'outcome'),
  'someone who estimates without sales, or crew, can''t mark it Won (nothing changes, nothing recorded)');
select tpo_rp.as(:'sales', format('update public.requests set stage_id = %L, outcome_reason = %L where id = %L', :'s_won', 'Verbal yes on site', :'req'));
select tpo_rp.check((select stage_id = :'s_won' from public.requests where id = :'req')
                    and not exists (select 1 from public.quotes where request_id = :'req') and not exists (select 1 from public.jobs where request_id = :'req')
                    and not exists (select 1 from public.invoices where company_id = :'co') and not exists (select 1 from public.payments where company_id = :'co')
                    and not exists (select 1 from public.job_folder_provisioning where company_id = :'co'),
  'someone in sales marks it Won with a note: no document, signature, deposit, invoice, payment, job or folder is made');
select tpo_rp.check((select count(*) from public.follow_up_tasks where related_id = :'req' and done_at is null) = 0, 'and its open reminders close');
select tpo_rp.expect_error(format('select tpo_rp.as(%L, %L)', :'sales', format('update public.requests set follow_up_paused_at = null where id = %L', :'req')), 'a decided request doesn''t resume', '%decided%');

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops pipeline resume policy tests passed.'
