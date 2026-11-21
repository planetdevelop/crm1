-- Planet Ops Phase 2 follow-ups: resuming restores the current stage's reminders once; snoozing
-- keeps a follow-up's identity; a next action can be a follow-up; Won as a sales call
-- (20261123000100_planet_ops_pipeline_followups.sql). Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_fu;
grant usage on schema tpo_fu to authenticated, service_role;
create function tpo_fu.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_fu.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_fu.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- As the salesperson, in its own transaction (each statement here is one).
create function tpo_fu.run(p_sql text) returns void language plpgsql as $$
begin
  perform tpo_fu.as_user('e2300000-0000-0000-0000-000000000002');
  set local role authenticated;
  execute p_sql;
  reset role;
end $$;
grant execute on all functions in schema tpo_fu to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2300000-0000-0000-0000-000000000001', 'owner@planet-fu.test', '{"full_name": "Test Owner"}'),
  ('e2300000-0000-0000-0000-000000000002', 'sales@planet-fu.test', '{"full_name": "Test Salesperson"}');
\set owner 'e2300000-0000-0000-0000-000000000001'
\set sales 'e2300000-0000-0000-0000-000000000002'
begin;
set local role authenticated;
select tpo_fu.as_user(:'owner');
select public.create_company('TEST Planet Demolition FU', 'general') as co \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'sales', 'office');
select private.company_today(:'co') as today \gset
select id as s_sent from public.pipeline_stages where company_id = :'co' and system_key = 'quote_sent' \gset
select id as s_est from public.pipeline_stages where company_id = :'co' and system_key = 'estimating' \gset
select id as s_won from public.pipeline_stages where company_id = :'co' and system_key = 'won' \gset
select id as s_lost from public.pipeline_stages where company_id = :'co' and system_key = 'lost' \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Follow-up Customer') returning id as client \gset
insert into public.requests (company_id, client_id, title, assigned_to) values (:'co', :'client', 'Barn demolition', :'sales') returning id as req \gset
insert into public.requests (company_id, client_id, title, assigned_to) values (:'co', :'client', 'Pool removal', :'sales') returning id as other \gset
select id as t1 from public.follow_up_tasks where related_id = :'req' and source = 'cadence' \gset

-- ===== Pause, resume: the same reminder comes back, once =====================================
select tpo_fu.run(format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
select tpo_fu.check((select done_at is not null and closed_reason = 'paused' from public.follow_up_tasks where id = :'t1'), 'pausing cancels the stage''s reminder (closed as paused, not done)');
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select done_at is null and closed_reason is null and due_on = :'today'::date from public.follow_up_tasks where id = :'t1'), 'resuming reopens that same reminder, due today');
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select count(*) from public.follow_up_tasks where related_id = :'req') = 1, 'resuming again (repeated clicks, retries) makes nothing more');
select tpo_fu.check((select string_agg(from_value, ',' order by created_at) from public.request_pipeline_events where request_id = :'req' and kind = 'follow_up') = 'created,cancelled:paused,reopened',
  'the history says created, cancelled (paused), reopened');
select tpo_fu.check((select count(*) from public.request_pipeline_events where request_id = :'req' and kind = 'resumed') = 1, 'and one resume');

-- A completed reminder stays completed through a pause and resume.
select tpo_fu.run(format('update public.follow_up_tasks set done_at = now(), done_by = %L where id = %L', :'sales', :'t1'));
select tpo_fu.run(format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select done_at is not null and closed_reason is null from public.follow_up_tasks where id = :'t1'), 'a done reminder stays done');
select tpo_fu.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'follow_up' and from_value = 'done'), 'its completion is in the history');

-- ===== Changing stage while paused ===============================================================
select tpo_fu.run(format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
select tpo_fu.run(format('update public.requests set stage_id = %L where id = %L', :'s_sent', :'req'));
select tpo_fu.check(not exists (select 1 from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal%'), 'entering a stage while paused makes no reminder');
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select count(*) = 1 and bool_and(done_at is null and due_on = :'today'::date + 3) from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal%'),
  'resuming makes the current stage''s reminder, due as it would have been');
select id as p1 from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal%' \gset
select tpo_fu.run(format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select count(*) from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal%') = 1
                    and (select done_at is null from public.follow_up_tasks where id = :'p1'), 'pausing and resuming again: still that one reminder, open');
-- Paused, then moved on to a stage with no cadence: the old stage's reminder isn't brought back.
select tpo_fu.run(format('update public.requests set follow_up_paused_at = now() where id = %L', :'req'));
select tpo_fu.run(format('update public.requests set stage_id = %L where id = %L', :'s_est', :'req'));
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'req'));
select tpo_fu.check((select done_at is not null from public.follow_up_tasks where id = :'p1'), 'a reminder from an earlier stage stays closed on resume');
select tpo_fu.check((select count(*) from public.follow_up_tasks where related_id = :'req' and done_at is null) = 0, 'and nothing else is opened');

-- ===== Snooze and reschedule =====================================================================
select tpo_fu.run(format('select public.add_request_follow_up(%L, %L, %L::date, null, true)', :'req', 'Call about the barn permit', :'today'::date + 1));
select id as nt from public.follow_up_tasks where related_id = :'req' and source = 'manual' \gset
select tpo_fu.check((select next_action = 'Call about the barn permit' and next_action_on = :'today'::date + 1 and next_action_task_id = :'nt' from public.requests where id = :'req'),
  'a follow-up can be the request''s next action');
select tpo_fu.run(format('update public.follow_up_tasks set due_on = %L where id = %L', :'today'::date + 4, :'nt'));
select tpo_fu.check((select due_on = :'today'::date + 4 from public.follow_up_tasks where id = :'nt') and (select next_action_on = :'today'::date + 4 from public.requests where id = :'req'),
  'snoozing it keeps the same follow-up and moves the next action''s date with it');
select tpo_fu.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'follow_up' and from_value = 'rescheduled' and to_value like '%→ ' || (:'today'::date + 4)::text),
  'the reschedule is in the history, from and to');
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.follow_up_tasks set due_on = %L where id = %L', :'today'::date - 1, :'nt')), 'not to a past day (the business''s own date)', '%today or a later day%');
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.follow_up_tasks set title = %L where id = %L', 'Something else', :'nt')), 'a follow-up keeps what it is', '%keeps what it is%');
select tpo_fu.run(format('update public.follow_up_tasks set done_at = now(), done_by = %L where id = %L', :'sales', :'nt'));
select tpo_fu.check((select next_action is null and next_action_on is null and next_action_task_id is null from public.requests where id = :'req'), 'doing it clears the next action it was');
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.follow_up_tasks set due_on = %L where id = %L', :'today'::date + 9, :'nt')), 'a done follow-up can''t be rescheduled', '%closed%');
-- A next action typed by hand stands on its own.
select tpo_fu.run(format('select public.add_request_follow_up(%L, %L, %L::date, null, true)', :'req', 'Send the revised price', :'today'::date + 2));
select tpo_fu.run(format('update public.requests set next_action = %L where id = %L', 'Wait for their architect', :'req'));
select tpo_fu.check((select next_action = 'Wait for their architect' and next_action_task_id is null from public.requests where id = :'req'), 'a next action typed by hand unlinks it');
select tpo_fu.check((select done_at is null from public.follow_up_tasks where related_id = :'req' and title = 'Send the revised price'), 'and the follow-up stays open');

-- ===== Opt-outs and decided requests aren't resumed ==============================================
update public.clients set marketing_opt_out = true where id = :'client';
select tpo_fu.check((select follow_up_paused_reason = 'opted_out' from public.requests where id = :'other'), 'an opt-out pauses the customer''s open requests');
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.requests set follow_up_paused_at = null where id = %L', :'other')), 'staff can''t resume over an opt-out', '%opted out%');
update public.clients set marketing_opt_out = false where id = :'client';
select tpo_fu.run(format('update public.requests set follow_up_paused_at = null where id = %L', :'other'));
select tpo_fu.check((select follow_up_paused_at is null from public.requests where id = :'other'), 'once they opt back in, it can be resumed');
select tpo_fu.run(format('update public.requests set stage_id = %L, outcome_reason = %L where id = %L', :'s_lost', 'Chose to wait a year', :'other'));
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.requests set follow_up_paused_at = null where id = %L', :'other')), 'a lost request can''t be resumed by hand', '%decided%');

-- ===== Won as a sales call: no job, no signature, no payment ===================================
insert into public.quotes (company_id, client_id, request_id, title) values (:'co', :'client', :'req', 'Barn demolition') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish barn', 1, 'ea', 9000);
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
select tpo_fu.expect_error(format('select tpo_fu.run(%L)', format('update public.requests set stage_id = %L where id = %L', :'s_won', :'req')), 'Won without a job needs a note', '%Say why it''s won%');
select tpo_fu.run(format('update public.requests set stage_id = %L, outcome_reason = %L where id = %L', :'s_won', 'Verbal yes; contract to follow', :'req'));
select tpo_fu.check((select stage_id = :'s_won' and outcome_reason = 'Verbal yes; contract to follow' and status <> 'converted' from public.requests where id = :'req'), 'someone in sales marks it won, with the note');
select tpo_fu.check(not exists (select 1 from public.jobs where company_id = :'co') and not exists (select 1 from public.job_folder_provisioning where company_id = :'co')
                    and not exists (select 1 from public.invoices where company_id = :'co') and not exists (select 1 from public.payments where company_id = :'co'),
  'no job, folder handoff, invoice or payment is made');
select tpo_fu.check((select status = 'sent' and approval is null from public.quotes where id = :'quote'), 'and its quote is still sent and unsigned: no acceptance is made up');
select tpo_fu.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'outcome' and to_value = 'Verbal yes; contract to follow' and actor_id = :'sales'), 'who did it, and why, are in the history');
-- Signed and converted later: the same request, one job, Won stays once.
select planet_test.sign(:'quote');
select public.convert_quote_to_job(:'quote') as job \gset
select tpo_fu.check((select request_id = :'req' from public.jobs where id = :'job') and (select count(*) from public.jobs where request_id = :'req') = 1
                    and (select count(*) from public.request_pipeline_events where request_id = :'req' and kind = 'stage' and to_value = 'Won') = 1,
  'converting its signed quote later links the one job to it, and Won stays once in the history');

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops pipeline follow-up tests passed.'
