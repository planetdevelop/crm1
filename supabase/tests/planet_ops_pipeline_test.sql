-- Planet Ops Phase 2: the sales pipeline (20261122000100_planet_ops_pipeline.sql). Run with
-- scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_pl;
grant usage on schema tpo_pl to authenticated, service_role;
create function tpo_pl.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_pl.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- Signs in as someone for the rest of the transaction.
create function tpo_pl.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema tpo_pl to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2200000-0000-0000-0000-000000000001', 'owner@planet-pl.test', '{"full_name": "Test Owner"}'),
  ('e2200000-0000-0000-0000-000000000002', 'sales@planet-pl.test', '{"full_name": "Test Salesperson"}'),
  ('e2200000-0000-0000-0000-000000000003', 'estimator@planet-pl.test', '{"full_name": "Test Estimator"}'),
  ('e2200000-0000-0000-0000-000000000004', 'scheduler@planet-pl.test', '{"full_name": "Test Scheduler, no sales"}'),
  ('e2200000-0000-0000-0000-000000000005', 'crew@planet-pl.test', '{"full_name": "Test Crew Lead"}');
\set owner 'e2200000-0000-0000-0000-000000000001'
\set sales 'e2200000-0000-0000-0000-000000000002'
\set estimator 'e2200000-0000-0000-0000-000000000003'
\set scheduler 'e2200000-0000-0000-0000-000000000004'
\set crew 'e2200000-0000-0000-0000-000000000005'

begin;
set local role authenticated;
select tpo_pl.as_user(:'owner');
select public.create_company('TEST Planet Demolition PL', 'general') as co \gset
commit;
-- The business's own date (reminders are due on its days, not the database's).
select (now() at time zone timezone)::date as today from public.companies where id = :'co' \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'sales', 'office'), (:'co', :'estimator', 'estimator'), (:'co', :'crew', 'crew_lead');
insert into public.company_roles (company_id, name, description, base_role, permissions) values (:'co', 'TEST Scheduler', 'Schedules; no sales.', 'office', array['schedule']) returning id as sched_role \gset
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', :'scheduler', 'office', :'sched_role');

-- ===== Stages and cadence come with a new business ===========================================
select tpo_pl.check((select count(*) = 11 and count(*) filter (where kind = 'open') = 7 and count(*) filter (where kind = 'won') = 1
                            and count(*) filter (where kind in ('nurture', 'lost', 'unqualified')) = 3
                     from public.pipeline_stages where company_id = :'co'),
  'a new business has the plan''s stages: seven open steps, Won, and Nurture, Lost and Unqualified apart');
select tpo_pl.check((select string_agg(label, ' → ' order by sort) from public.pipeline_stages where company_id = :'co' and kind in ('open', 'won'))
                    = 'New inquiry → Contacting → Site visit scheduled → Site visit complete → Estimating → Quote/proposal sent → Follow-up → Won',
  'in the plan''s order');
select tpo_pl.check((select count(*) from public.pipeline_cadence_steps where company_id = :'co') = 4, 'and the starter cadence (first response, site-visit check-in, post-proposal, nurture)');
select tpo_pl.check(not exists (select 1 from public.pipeline_templates where company_id = :'co'), 'no template wording is preset: the business writes its own');
select id as s_new from public.pipeline_stages where company_id = :'co' and system_key = 'new_inquiry' \gset
select id as s_contacting from public.pipeline_stages where company_id = :'co' and system_key = 'contacting' \gset
select id as s_visit from public.pipeline_stages where company_id = :'co' and system_key = 'site_visit_scheduled' \gset
select id as s_estimating from public.pipeline_stages where company_id = :'co' and system_key = 'estimating' \gset
select id as s_sent from public.pipeline_stages where company_id = :'co' and system_key = 'quote_sent' \gset
select id as s_won from public.pipeline_stages where company_id = :'co' and system_key = 'won' \gset
select id as s_nurture from public.pipeline_stages where company_id = :'co' and system_key = 'nurture' \gset
select id as s_lost from public.pipeline_stages where company_id = :'co' and system_key = 'lost' \gset
select id as s_unq from public.pipeline_stages where company_id = :'co' and system_key = 'unqualified' \gset

-- ===== A request comes in: stage, owner, next action, history, its first follow-up ============
insert into public.clients (company_id, display_name, email) values (:'co', 'TEST – Pipeline Customer', 'pipeline.customer@example.com') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '1 Test Way', 'Roanoke', 'VA', '24011') returning id as property \gset
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
insert into public.requests (company_id, client_id, property_id, title, source, last_contact_at) values (:'co', :'client', :'property', 'House demolition', 'phone', now() - interval '3 days') returning id as req \gset
commit;
select tpo_pl.check((select stage_id = :'s_new' and assigned_to is null and next_action = 'Make first contact' and next_action_on is not null and stage_entered_at is not null
                     from public.requests where id = :'req'),
  'a new request is a New inquiry with a visible next action; nobody covers its zip and no default owner is set, so it has no owner yet (flagged)');
select tpo_pl.check((select last_contact_at is null from public.requests where id = :'req'), 'staff can''t write its last contact: it comes from logged contacts');
select tpo_pl.check((select count(*) = 1 and bool_and(to_value = 'New inquiry' and actor_id = :'sales') from public.request_pipeline_events where request_id = :'req' and kind = 'stage'),
  'its history starts with the stage it came in at, and who');
select tpo_pl.check((select count(*) = 1 and bool_and(source = 'cadence' and assigned_to is null and title = 'First response: House demolition' and done_at is null)
                     from public.follow_up_tasks where related_type = 'request' and related_id = :'req'),
  'and the office gets the stage''s first-response follow-up');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set assigned_to = :'owner' where id = :'req';
commit;
select tpo_pl.check((select assigned_to = :'owner' from public.follow_up_tasks where related_id = :'req' and title like 'First response%'), 'taking it gives its owner the open follow-up');

-- A default owner, when one is set: a request nobody covers goes to them.
update public.companies set settings = settings || jsonb_build_object('pipeline', jsonb_build_object('default_owner', :'sales')) where id = :'co';
insert into public.requests (company_id, client_id, title) values (:'co', :'client', 'Garage demolition') returning id as req2 \gset
select tpo_pl.check((select assigned_to = :'sales' from public.requests where id = :'req2'), 'with a pipeline default owner set, a request nobody covers goes to them');

-- ===== One client, two independent opportunities ===============================================
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set stage_id = :'s_contacting' where id = :'req';
commit;
select tpo_pl.check((select stage_id = :'s_contacting' and next_action = 'Reach the customer' from public.requests where id = :'req')
                    and (select stage_id = :'s_new' from public.requests where id = :'req2'),
  'moving one of a client''s requests leaves the other where it was');
select tpo_pl.check((select count(*) from public.request_pipeline_events where request_id = :'req' and kind = 'stage') = 2
                    and exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'stage' and from_value = 'New inquiry' and to_value = 'Contacting'),
  'the move is in its history, from and to');
select tpo_pl.check((select closed_reason = 'stage_changed' and done_at is not null from public.follow_up_tasks where related_id = :'req' and title like 'First response%'),
  'the last stage''s reminder is closed (as left behind, not done)');

-- A next action given with the move is kept; one changed later is in the history.
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set stage_id = :'s_visit', next_action = 'Meet the owner at the house', next_action_on = current_date + 2 where id = :'req';
update public.requests set next_action_on = current_date + 3 where id = :'req';
commit;
select tpo_pl.check((select next_action = 'Meet the owner at the house' and next_action_on = current_date + 3 from public.requests where id = :'req'), 'a next action given with a move is kept');
select tpo_pl.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'next_action' and to_value like 'Meet the owner at the house%'),
  'and a later change to it is in the history');

-- ===== The existing flows move it forward, never back ==========================================
update public.requests set status = 'assessment_complete' where id = :'req';
select tpo_pl.check((select system_key = 'site_visit_complete' from public.pipeline_stages where id = (select stage_id from public.requests where id = :'req')),
  'a finished site visit moves it to Site visit complete');
update public.requests set stage_id = :'s_estimating' where id = :'req';
update public.requests set status = 'assessment_scheduled' where id = :'req';
select tpo_pl.check((select stage_id = :'s_estimating' from public.requests where id = :'req'), 'a status that means an earlier stage doesn''t move it back');

-- Sending its quote: Quote/proposal sent.
insert into public.quotes (company_id, client_id, property_id, request_id, title) values (:'co', :'client', :'property', :'req', 'House demolition') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 21000);
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
select tpo_pl.check((select stage_id = :'s_sent' and next_action = 'Follow up on the quote/proposal' from public.requests where id = :'req'), 'sending its quote moves it to Quote/proposal sent');
select tpo_pl.check(exists (select 1 from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal follow-up%' and due_on = :'today'::date + 3 and done_at is null),
  'with its post-proposal follow-up, due in three days');

-- ===== Contacts: logged on the request and the client, never a new lead, never sent ===========
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select public.log_request_contact(:'req', 'call', 'out', 'Called to walk through the proposal. They''re comparing bids.') as call1 \gset
commit;
select tpo_pl.check((select client_id = :'client' and related_type = 'request' and related_id = :'req' and channel = 'call' and status = 'sent' and sent_by = :'sales' from public.messages where id = :'call1'),
  'a logged call is kept with the client and the request, by who logged it');
select tpo_pl.check((select last_contact_at is not null and first_response_at is not null from public.requests where id = :'req'), 'it sets the last contact and the first response');
select tpo_pl.check((select count(*) from public.requests where client_id = :'client') = 2, 'and makes no new request');
select tpo_pl.expect_error(format('select public.log_request_contact(%L, %L, %L, %L)', :'req', 'sms', 'internal', 'x'), 'a text is to or from the customer, not internal', '%Log a call%');
select tpo_pl.expect_error(format('select public.log_request_contact(%L, %L, %L, %L)', :'req', 'call', 'out', '  '), 'a contact says what was said', '%Say what was said%');

-- The customer replies: follow-ups pause, and the cadence reminders close.
select public.log_request_contact(:'req', 'sms', 'in', 'We''d like to go ahead if you can start in May.') as reply \gset
select tpo_pl.check((select follow_up_paused_reason = 'customer_replied' from public.requests where id = :'req'), 'an inbound reply pauses its follow-ups');
select tpo_pl.check(not exists (select 1 from public.follow_up_tasks where related_id = :'req' and source = 'cadence' and done_at is null), 'and closes its open cadence reminders');
select tpo_pl.check(exists (select 1 from public.follow_up_tasks where related_id = :'req' and title like 'Post-proposal%' and closed_reason = 'customer_replied'), 'saying why');
select tpo_pl.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'paused' and to_value = 'customer_replied'), 'the pause is in the history');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set follow_up_paused_at = null, follow_up_paused_reason = null where id = :'req';
select public.add_request_follow_up(:'req', 'Send the May start dates', current_date + 1) as manual \gset
commit;
select tpo_pl.check(exists (select 1 from public.request_pipeline_events where request_id = :'req' and kind = 'resumed'), 'staff resume them, in the history');
select tpo_pl.check((select source = 'manual' and assigned_to = :'owner' and due_on = current_date + 1 and created_by = :'sales' from public.follow_up_tasks where id = :'manual'),
  'a follow-up added by hand goes to the request''s owner');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set assigned_to = :'sales', estimator_id = :'estimator' where id = :'req';
commit;
select tpo_pl.check((select assigned_to = :'sales' from public.follow_up_tasks where id = :'manual'), 'a new owner takes its open follow-ups with them');
select tpo_pl.check((select count(*) from public.request_pipeline_events where request_id = :'req' and kind in ('owner', 'estimator')) = 3, 'owner (taken, then handed on) and estimator changes are in the history');
select tpo_pl.expect_error(format('update public.requests set estimator_id = %L where id = %L', 'a1000000-0000-0000-0000-00000000ffff', :'req'), 'the estimator must be on the team', '%estimator must be on the team%');

-- Opting out pauses an open request's follow-ups too.
update public.clients set marketing_opt_out = true where id = :'client';
select tpo_pl.check((select follow_up_paused_reason = 'opted_out' from public.requests where id = :'req2'), 'the customer opting out pauses their open requests'' follow-ups');

-- ===== Outcomes: lost needs a reason, stops follow-ups; back in the pipeline it starts over ===
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select tpo_pl.expect_error(format('update public.requests set stage_id = %L where id = %L', :'s_lost', :'req2'), 'Lost needs a reason', '%outcome reason%');
update public.requests set stage_id = :'s_lost', outcome_reason = 'Went with a cheaper bid' where id = :'req2';
commit;
select tpo_pl.check((select outcome_at is not null and next_action is null and next_action_on is null and follow_up_paused_at is not null from public.requests where id = :'req2'),
  'lost: decided, no next action, follow-ups stopped');
select tpo_pl.check(exists (select 1 from public.request_pipeline_events where request_id = :'req2' and kind = 'outcome' and to_value = 'Went with a cheaper bid'), 'the reason is in the history');
select tpo_pl.check(not exists (select 1 from public.follow_up_tasks where related_id = :'req2' and done_at is null), 'and nothing is left to do on it');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
update public.requests set stage_id = :'s_nurture' where id = :'req2';
commit;
select tpo_pl.check((select outcome_reason is null and outcome_at is null and next_action = 'Check back in' from public.requests where id = :'req2'),
  'moved to Nurture/on hold, it''s open again with a next action (the lost reason stays in the history)');
select tpo_pl.check((select follow_up_paused_reason = 'opted_out' from public.requests where id = :'req2'), 'its opt-out pause stays');

-- ===== Accepting the quote: Won, once, with the right request and job ========================
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select tpo_pl.expect_error(format('update public.requests set stage_id = %L where id = %L', :'s_won', :'req'), 'staff can''t mark a request Won without a note saying why', '%Say why it''s won%');
commit;
select planet_test.sign(:'quote');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select public.convert_quote_to_job(:'quote') as job \gset
commit;
select tpo_pl.check((select status = 'converted' and stage_id = :'s_won' and outcome_at is not null and next_action is null from public.requests where id = :'req'),
  'converting its signed quote makes the request Won');
select tpo_pl.check((select request_id = :'req' from public.jobs where id = :'job') and (select count(*) from public.jobs where request_id = :'req') = 1, 'its one job links the request');
select tpo_pl.check(public.convert_quote_to_job(:'quote') = :'job'
                    and (select count(*) from public.request_pipeline_events where request_id = :'req' and kind = 'stage' and to_value = 'Won') = 1,
  'converting again: the same job, and Won once in the history');
select tpo_pl.check((select stage_id = :'s_nurture' from public.requests where id = :'req2'), 'the client''s other request is unaffected');

-- ===== Permissions ===============================================================================
begin;
set local role authenticated;
select tpo_pl.as_user(:'scheduler');
select tpo_pl.expect_error(format('update public.requests set stage_id = %L where id = %L', :'s_contacting', :'req2'), 'someone without the Sales area can''t move a request', '%needs the Sales area%');
select tpo_pl.expect_error(format('select public.log_request_contact(%L, %L, %L, %L)', :'req2', 'call', 'out', 'x'), 'nor log a contact', '%not found%');
select tpo_pl.expect_error(format('select public.pipeline_report(%L, current_date - 30, current_date)', :'co'), 'nor read the report', '%need the Sales area%');
select tpo_pl.check(not exists (select 1 from public.request_pipeline_events where company_id = :'co'), 'nor its history');
update public.requests set title = title where id = :'req2';
commit;
begin;
set local role authenticated;
select tpo_pl.as_user(:'crew');
select tpo_pl.check(not exists (select 1 from public.pipeline_templates where company_id = :'co') and not exists (select 1 from public.request_pipeline_events where company_id = :'co'),
  'a crew lead sees no templates or pipeline history');
commit;
begin;
set local role authenticated;
select tpo_pl.as_user(:'estimator');
-- Row security leaves them nothing to change: the update finds no stage.
update public.pipeline_stages set label = 'Calling' where id = :'s_contacting';
commit;
select tpo_pl.check((select label = 'Contacting' from public.pipeline_stages where id = :'s_contacting'), 'an estimator can''t change the stages (Settings): unchanged');

-- ===== Stages are the business's to edit, within limits =========================================
begin;
set local role authenticated;
select tpo_pl.as_user(:'owner');
update public.pipeline_stages set label = 'First call', default_due_days = 2 where id = :'s_contacting';
insert into public.pipeline_stages (company_id, label, kind, sort, default_next_action, default_due_days) values (:'co', 'Permitting check', 'open', 55, 'Check the permit', 2) returning id as s_custom \gset
select tpo_pl.expect_error(format('update public.pipeline_stages set kind = %L where id = %L', 'won', :'s_contacting'), 'a stage''s kind can''t change');
select tpo_pl.expect_error(format('update public.pipeline_stages set active = false where id = %L', :'s_lost'), 'Lost stays on', '%stay on%');
select tpo_pl.expect_error(format('insert into public.pipeline_stages (company_id, label, kind, sort) values (%L, %L, %L, 1)', :'co', 'Another won', 'won'), 'only open stages can be added');
delete from public.pipeline_stages where id = :'s_lost';
update public.requests set stage_id = :'s_custom' where id = :'req2';
select tpo_pl.expect_error(format('update public.pipeline_stages set active = false where id = %L', :'s_custom'), 'a stage with requests in it can''t be switched off', '%Move the requests%');
update public.requests set stage_id = :'s_nurture' where id = :'req2';
delete from public.pipeline_stages where id = :'s_custom';
commit;
select tpo_pl.check((select label = 'First call' from public.pipeline_stages where id = :'s_contacting') and exists (select 1 from public.pipeline_stages where id = :'s_lost'),
  'renamed, and a starter stage can''t be deleted');
select tpo_pl.check(not exists (select 1 from public.pipeline_stages where company_id = :'co' and label = 'Permitting check'), 'a custom stage, empty again, can be deleted');
select tpo_pl.check((select count(*) from public.request_pipeline_events where request_id = :'req2' and kind = 'stage' and to_value = 'Permitting check') = 1,
  'the history keeps the stage''s name as it was');

-- A template, written by the business (Settings), and a cadence step that points staff to it.
begin;
set local role authenticated;
select tpo_pl.as_user(:'owner');
insert into public.pipeline_templates (company_id, name, channel, body) values (:'co', 'TEST quote check-in', 'call', 'TEST script: ask whether they have questions about the proposal.') returning id as tpl \gset
update public.pipeline_cadence_steps set template_id = :'tpl' where company_id = :'co' and stage_id = :'s_sent';
commit;
begin;
set local role authenticated;
select tpo_pl.as_user(:'estimator');
select tpo_pl.check((select count(*) = 1 from public.pipeline_templates where company_id = :'co'), 'people who sell read the templates');
select tpo_pl.expect_error(format('insert into public.pipeline_templates (company_id, name, channel, body) values (%L, %L, %L, %L)', :'co', 'Mine', 'sms', 'Hi'), 'but only Settings writes them');
commit;

-- ===== The history is kept as it happened ======================================================
select tpo_pl.expect_error(format('update public.request_pipeline_events set to_value = %L where request_id = %L', 'Edited', :'req'), 'history can''t be edited', '%kept as it happened%');
select tpo_pl.expect_error(format('delete from public.request_pipeline_events where request_id = %L', :'req'), 'or deleted', '%kept as it happened%');

-- ===== Reports and pricing history ===============================================================
insert into public.requests (company_id, client_id, title, source) values (:'co', :'client', 'Shed removal', 'web_form') returning id as req3 \gset
insert into public.quotes (company_id, client_id, request_id, title) values (:'co', :'client', :'req3', 'Shed removal') returning id as quote3 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote3', 'Remove shed', 1, 'ea', 3200);
update public.quotes set status = 'sent', sent_at = now() where id = :'quote3';
update public.requests set stage_id = (select id from public.pipeline_stages where company_id = :'co' and system_key = 'lost'), outcome_reason = 'No response after three follow-ups' where id = :'req3';
insert into public.requests (company_id, client_id, title, source) values (:'co', :'client', 'Spam: buy followers', 'web_form') returning id as req4 \gset
update public.requests set stage_id = :'s_unq', outcome_reason = 'Spam' where id = :'req4';
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select public.pipeline_report(:'co', current_date - 30, current_date) as report \gset
commit;
select tpo_pl.check((:'report'::jsonb ->> 'won')::int = 1 and (:'report'::jsonb ->> 'lost')::int = 1 and (:'report'::jsonb ->> 'unqualified')::int = 1,
  'the report counts the outcomes decided in the period');
select tpo_pl.check((:'report'::jsonb ->> 'conversion')::numeric = 0.5, 'conversion is won ÷ (won + lost), unqualified apart');
select tpo_pl.check((:'report'::jsonb ->> 'won_value')::numeric = 21000 and (:'report'::jsonb ->> 'lost_value')::numeric = 3200, 'won and lost value are the quoted amounts');
select tpo_pl.check((:'report'::jsonb ->> 'requests')::int = 4 and (:'report'::jsonb -> 'by_source' ->> 'web_form')::int = 2 and (:'report'::jsonb -> 'response' ->> 'responded')::int = 1,
  'requests by source, and how many got a first response');
select tpo_pl.expect_error(format('select public.pipeline_report(%L, current_date, current_date - 1)', :'co'), 'a backwards period is refused', '%Pick a period%');
begin;
set local role authenticated;
select tpo_pl.as_user(:'sales');
select tpo_pl.check((select count(*) = 2 from public.pipeline_pricing_history(:'co')), 'pricing history lists each sent quote for a request');
select tpo_pl.check((select outcome = 'lost' and amount = 3200 from public.pipeline_pricing_history(:'co', p_outcome => 'lost')), 'a lost bid''s price stays as sales evidence');
select tpo_pl.check((select count(*) = 1 and bool_and(outcome = 'won' and estimator_id = :'estimator' and city = 'Roanoke') from public.pipeline_pricing_history(:'co', p_estimator => :'estimator', p_location => 'roanoke')),
  'filtered by estimator and location');
select tpo_pl.check((select count(*) = 1 from public.pipeline_pricing_history(:'co', p_service => 'shed')), 'and by service');
commit;

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops pipeline tests passed.'
