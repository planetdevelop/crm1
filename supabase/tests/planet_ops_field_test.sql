-- Planet Ops Phase 5: tailgate meetings, machines on jobs and their checks, and what each person sees
-- (20261128000100_planet_ops_field.sql). Fictional records only. Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_fd;
grant usage on schema tpo_fd to authenticated, service_role;
create function tpo_fd.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_fd.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_fd.as(p_user uuid, p_sql text) returns text language plpgsql as $$
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
-- A drawn signature (as SQL, for format's %s).
create function tpo_fd.sig() returns text language sql as $$ select quote_literal('data:image/png;base64,' || repeat('A', 300)) $$;
grant execute on all functions in schema tpo_fd to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e3100000-0000-0000-0000-000000000001', 'owner@planet-fd.test', '{"full_name": "Test Owner"}'),
  ('e3100000-0000-0000-0000-000000000002', 'sched@planet-fd.test', '{"full_name": "Test Scheduler"}'),
  ('e3100000-0000-0000-0000-000000000003', 'lead@planet-fd.test', '{"full_name": "Test Crew Lead"}'),
  ('e3100000-0000-0000-0000-000000000004', 'ann@planet-fd.test', '{"full_name": "Test Ann"}'),
  ('e3100000-0000-0000-0000-000000000005', 'bo@planet-fd.test', '{"full_name": "Test Bo"}'),
  ('e3100000-0000-0000-0000-000000000006', 'cy@planet-fd.test', '{"full_name": "Test Cy (other crew)"}');
\set owner 'e3100000-0000-0000-0000-000000000001'
\set sched 'e3100000-0000-0000-0000-000000000002'
\set lead 'e3100000-0000-0000-0000-000000000003'
\set ann 'e3100000-0000-0000-0000-000000000004'
\set bo 'e3100000-0000-0000-0000-000000000005'
\set cy 'e3100000-0000-0000-0000-000000000006'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition FD', 'general') as co \gset
commit;
-- A scheduler: Schedule and Equipment, no Timesheets (no pay).
insert into public.company_roles (company_id, name, description, base_role, permissions) values (:'co', 'TEST Scheduler', 'Schedules; no payroll.', 'office', array['schedule', 'equipment']);
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', :'sched', 'office', (select id from public.company_roles where company_id = :'co' and name = 'TEST Scheduler'));
insert into public.memberships (company_id, user_id, role) values (:'co', :'lead', 'crew_lead'), (:'co', :'ann', 'field_crew'), (:'co', :'bo', 'field_crew'), (:'co', :'cy', 'field_crew');
insert into public.crews (company_id, name, lead_user_id) values (:'co', 'TEST Demo crew', :'lead') returning id as crew \gset
insert into public.crews (company_id, name) values (:'co', 'TEST Other crew') returning id as crew2 \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'crew', :'ann'), (:'co', :'crew', :'bo'), (:'co', :'crew2', :'cy');
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Field Customer') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Barn demolition') returning id as job \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Other job') returning id as job2 \gset
select private.company_today(:'co') as today \gset
insert into public.visits (company_id, job_id, title, crew_id, scheduled_on) values (:'co', :'job', 'Demo day 1', :'crew', :'today'::date) returning id as visit \gset
insert into public.visits (company_id, job_id, title, crew_id, scheduled_on) values (:'co', :'job2', 'Other crew day', :'crew2', :'today'::date) returning id as visit2 \gset
insert into public.equipment (company_id, name, kind) values (:'co', 'TEST Excavator 1', 'machine') returning id as ex \gset

-- ===== The employee sees only their assigned work ================================================
select tpo_fd.check((select count(*) from jsonb_array_elements(tpo_fd.as(:'ann', format('select public.my_field_day(%L)::text', :'co'))::jsonb -> 'visits')) = 1
                    and tpo_fd.as(:'ann', format('select count(*)::text from public.visits where id = %L', :'visit2')) = '0',
  'Ann (Demo crew) sees her crew''s visit today, not the other crew''s');
select tpo_fd.check(tpo_fd.as(:'sched', 'select count(*)::text from public.time_entries') = '0' and not tpo_fd.as(:'sched', format('select private.has_perm(%L, %L)::text', :'co', 'timesheets'))::boolean,
  'the scheduler has no Timesheets area (no pay)');

-- ===== Tailgate: assigned, attended, each signs their own ========================================
select tpo_fd.as(:'lead', format('select public.create_tailgate(%L, %L, %L, %L, %L::jsonb, %L)::text', :'co', 'a3100000-0000-0000-0000-0000000000a1', :'job', :'today',
  '{"title": "Day 1: roof removal", "topic": "Working at height", "hazards": "Falling debris; overhead line on the east side", "controls": "Exclusion zone; spotter for the excavator"}', :'crew')) as tg \gset
select tpo_fd.check(tpo_fd.as(:'lead', format('select public.create_tailgate(%L, %L, %L, %L, %L::jsonb, %L)::text', :'co', 'a3100000-0000-0000-0000-0000000000a1', :'job', :'today', '{}', :'crew')) = :'tg',
  'a retried create is the same meeting');
select tpo_fd.check((select count(*) from public.tailgate_attendees where meeting_id = :'tg') = 3, 'the crew lead and both crew members are assigned');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'cy', format('select public.create_tailgate(%L, gen_random_uuid(), %L, %L, %L::jsonb, %L)::text', :'co', :'job', :'today', '{"title": "x"}', :'crew')),
  'a crew member can''t assign tailgates', '%Schedule area%');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'cy', format('select public.sign_tailgate(%L, 1, %s, gen_random_uuid())::text', :'tg', tpo_fd.sig())), 'someone not on the meeting can''t sign it', '%aren''t on this tailgate%');
select tpo_fd.check(tpo_fd.as(:'cy', format('select count(*)::text from public.tailgate_meetings where id = %L', :'tg')) = '0', 'nor see it');
select tpo_fd.as(:'ann', format('select public.sign_tailgate(%L, 1, %s, %L)::text', :'tg', tpo_fd.sig(), 'a3100000-0000-0000-0000-0000000000b1'));
select tpo_fd.check((tpo_fd.as(:'ann', format('select public.sign_tailgate(%L, 1, %s, %L)::text', :'tg', tpo_fd.sig(), 'a3100000-0000-0000-0000-0000000000b1'))::jsonb ->> 'signed')::boolean
                    and (select count(*) from public.tailgate_signatures where meeting_id = :'tg') = 1, 'Ann signs her own (a retry is the same signature)');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'ann', format('select public.sign_tailgate(%L, 1, %L, gen_random_uuid())::text', :'tg', 'typed: Ann')), 'a typed name isn''t a signature', '%drawn signature%');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'lead', format('insert into public.tailgate_signatures (company_id, meeting_id, user_id, version, content_hash, signature, request_key) values (%L, %L, %L, 1, %L, %s, gen_random_uuid())', :'co', :'tg', :'bo', 'x', tpo_fd.sig())),
  'the lead can''t sign for Bo (no writing to signatures)', '%permission denied%');
select tpo_fd.expect_error(format('update public.tailgate_signatures set signed_at = now() where meeting_id = %L', :'tg'), 'a signature is frozen, even for the database owner', '%kept as they were%');
-- The lead changes the briefing after Ann signed: an amendment everyone signs.
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'lead', format('select public.amend_tailgate(%L, %L::jsonb)::text', :'tg', '{"hazards": "Falling debris; overhead line; asbestos found in the attic"}')),
  'amending a signed briefing needs a reason', '%say what changed%');
select tpo_fd.as(:'lead', format('select public.amend_tailgate(%L, %L::jsonb, %L)::text', :'tg', '{"hazards": "Falling debris; overhead line; asbestos found in the attic"}', 'Asbestos found'));
select public.tailgate_status(:'tg')::text as ts \gset
select tpo_fd.check((:'ts'::jsonb ->> 'version')::int = 2 and jsonb_array_length(:'ts'::jsonb -> 'versions') = 2
                    and (select bool_and((a ->> 'needs_signature')::boolean) from jsonb_array_elements(:'ts'::jsonb -> 'attendees') a)
                    and (select (a ->> 'signed_version')::int = 1 from jsonb_array_elements(:'ts'::jsonb -> 'attendees') a where a ->> 'user_id' = :'ann'),
  'version 2: everyone, Ann too, needs to sign it; her version-1 signature stays with version 1');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'bo', format('select public.sign_tailgate(%L, 1, %s, gen_random_uuid())::text', :'tg', tpo_fd.sig())), 'signing the version you opened before the amendment is refused', '%amended since you opened it%');
select tpo_fd.as(:'bo', format('select public.sign_tailgate(%L, 2, %s, gen_random_uuid())::text', :'tg', tpo_fd.sig()));
select tpo_fd.as(:'lead', format('select public.set_tailgate_attendance(%L, %L, %L)::text', :'tg', :'ann', 'absent'));
select tpo_fd.as(:'lead', format('select public.set_tailgate_attendance(%L, %L, %L)::text', :'tg', :'cy', 'attended'));
select public.tailgate_status(:'tg')::text as ts \gset
select tpo_fd.check((select (a ->> 'added_late')::boolean and (a ->> 'needs_signature')::boolean from jsonb_array_elements(:'ts'::jsonb -> 'attendees') a where a ->> 'user_id' = :'cy')
                    and (select not (a ->> 'needs_signature')::boolean from jsonb_array_elements(:'ts'::jsonb -> 'attendees') a where a ->> 'user_id' = :'ann')
                    and (select not (a ->> 'needs_signature')::boolean from jsonb_array_elements(:'ts'::jsonb -> 'attendees') a where a ->> 'user_id' = :'bo'),
  'Cy joins late and needs to sign; Ann is absent; Bo has signed version 2');
select tpo_fd.check((select destination = 'job_documents' from public.pdos_files where source_kind = 'tailgate' and source_id = :'tg'), 'the signed record is bound for the job''s Documents & Permits');

-- ===== Machines on the job, their checklist, daily checks ========================================
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'ann', format('select public.save_machine_checklist(%L, %L, %L::jsonb, p_kind => %L)::text', :'co', 'X', '[{"key": "a", "label": "A"}]', 'machine')),
  'crew don''t write checklists', '%manage equipment%');
select tpo_fd.as(:'sched', format('select public.save_machine_checklist(%L, %L, %L::jsonb, p_kind => %L)::text', :'co', 'TEST Excavator daily', '[{"key": "grease", "label": "Greased pins and bushings"}, {"key": "leaks", "label": "No hydraulic leaks", "critical": true}, {"key": "guards", "label": "Guards and cab glass intact", "critical": true}, {"key": "hours", "label": "Hour meter read", "meter": true}]', 'machine')) as cl1 \gset
select tpo_fd.as(:'sched', format('select public.assign_machine(%L, %L, %L, %L, %L, %L, %L)::text', :'co', 'a3100000-0000-0000-0000-0000000000c1', :'ex', :'job', :'ann', :'today', (:'today'::date + 2)::text)) as asg \gset
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'sched', format('select public.assign_machine(%L, gen_random_uuid(), %L, %L, %L, %L, %L)::text', :'co', :'ex', :'job2', :'cy', :'today', :'today')),
  'the same machine on another job the same day is flagged', '%already assigned on those days%');
select tpo_fd.check((select count(*) from jsonb_array_elements(public.machine_checks_due(:'co', :'today')) x where x ->> 'assignment_id' = :'asg' and not (x ->> 'daily_done')::boolean) = 1,
  'today''s check is missing (visible to the office)');
select tpo_fd.check((select count(*) from jsonb_array_elements(tpo_fd.as(:'ann', format('select public.my_field_day(%L)::text', :'co'))::jsonb -> 'machines')) = 1
                    and (select count(*) from jsonb_array_elements(tpo_fd.as(:'bo', format('select public.my_field_day(%L)::text', :'co'))::jsonb -> 'machines')) = 0,
  'Ann sees the excavator on her day; Bo (not responsible) doesn''t');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'bo', format('select public.record_machine_check(%L, gen_random_uuid(), %L, %L::jsonb, %s, 100)::text', :'asg', :'today', '[]', tpo_fd.sig())),
  'only the responsible operator records its check', '%responsible operator%');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'ann', format('select public.record_machine_check(%L, gen_random_uuid(), %L, %L::jsonb, %s, 100)::text', :'asg', :'today', '[{"key": "grease", "answer": "yes"}]', tpo_fd.sig())),
  'every item must be answered: nothing carries over', '%nothing is carried over%');
select tpo_fd.as(:'ann', format('select public.record_machine_check(%L, %L, %L, %L::jsonb, %s, 1250)::text', :'asg', 'a3100000-0000-0000-0000-0000000000d1', :'today',
  '[{"key": "grease", "answer": "yes"}, {"key": "leaks", "answer": "yes"}, {"key": "guards", "answer": "yes"}, {"key": "hours", "answer": "yes"}]', tpo_fd.sig()));
select tpo_fd.check((select checklist_version = 1 and meter_reading = 1250 from public.machine_checks where request_key = 'a3100000-0000-0000-0000-0000000000d1')
                    and (select (x ->> 'daily_done')::boolean from jsonb_array_elements(public.machine_checks_due(:'co', :'today')) x where x ->> 'assignment_id' = :'asg'),
  'Ann''s signed check today (checklist version 1, 1,250 h): no longer missing');
-- The checklist changes: tomorrow's check uses version 2; today's keeps version 1.
select tpo_fd.as(:'sched', format('select public.save_machine_checklist(%L, %L, %L::jsonb, p_kind => %L, p_family => (select family_id from public.machine_checklists where id = %L))::text', :'co', 'TEST Excavator daily',
  '[{"key": "grease", "label": "Greased pins and bushings"}, {"key": "leaks", "label": "No hydraulic leaks", "critical": true}, {"key": "guards", "label": "Guards and cab glass intact", "critical": true}, {"key": "tracks", "label": "Track tension checked"}]', 'machine', :'cl1'));
-- Tomorrow: a critical failure.
select tpo_fd.as(:'ann', format('select public.record_machine_check(%L, gen_random_uuid(), %L, %L::jsonb, %s)::text', :'asg', (:'today'::date + 1)::text,
  '[{"key": "grease", "answer": "yes"}, {"key": "leaks", "answer": "no", "note": "Weeping at the boom cylinder"}, {"key": "guards", "answer": "yes"}, {"key": "tracks", "answer": "na"}]', tpo_fd.sig())) as fail \gset
select tpo_fd.check((:'fail'::jsonb ->> 'critical_failure')::boolean and (select status = 'in_shop' from public.equipment where id = :'ex')
                    and (select count(*) = 1 from public.machine_defects where equipment_id = :'ex' and status = 'open' and critical)
                    and (select checklist_version = 2 from public.machine_checks where id = (:'fail'::jsonb ->> 'id')::uuid)
                    and (select checklist_version = 1 from public.machine_checks where request_key = 'a3100000-0000-0000-0000-0000000000d1'),
  'a critical "no" takes it out of service with an open defect; that check used version 2, today''s keeps version 1');
select tpo_fd.check(exists (select 1 from public.notifications where company_id = :'co' and user_id = :'sched' and title like 'TEST Excavator 1 is out of service%')
                    and not exists (select 1 from public.notifications where company_id = :'co' and user_id = :'ann' and title like '%out of service%'),
  'the people who manage equipment are told; the crew member isn''t');
-- Paid time is recorded regardless of the machine.
select tpo_fd.as(:'ann', format('insert into public.time_entries (company_id, visit_id, job_id, started_at) values (%L, %L, %L, now()) returning id::text', :'co', :'visit', :'job')) as te \gset
select tpo_fd.check(:'te' is not null, 'a failed or missing check never stops Ann recording her time');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'ann', format('select public.resolve_machine_defect((select id from public.machine_defects where equipment_id = %L), %L)::text', :'ex', 'tightened')),
  'the operator can''t release it', '%manage equipment%');
select tpo_fd.expect_error(format('select tpo_fd.as(%L, %L)', :'sched', format('select public.assign_machine(%L, gen_random_uuid(), %L, %L, %L, %L, %L)::text', :'co', :'ex', :'job2', :'cy', (:'today'::date + 5)::text, (:'today'::date + 5)::text)),
  'an out-of-service machine can''t be assigned', '%out of service%');
select tpo_fd.as(:'sched', format('select public.resolve_machine_defect((select id from public.machine_defects where equipment_id = %L), %L, %L::jsonb)::text', :'ex', 'Replaced the boom cylinder seal; ran 20 min, no leak', '[{"note": "TEST repair ticket R-1"}]'));
select tpo_fd.check((select status = 'active' from public.equipment where id = :'ex') and (select resolved_by = :'sched' and resolution like 'Replaced%' from public.machine_defects where equipment_id = :'ex'),
  'released by the scheduler (equipment area) with what was done: back in service');

-- ===== Operator change: a handover ===============================================================
select tpo_fd.as(:'sched', format('select public.hand_over_machine(%L, %L, %L, %L)::text', :'asg', :'bo', (:'today'::date + 2)::text, 'Ann off sick')) as asg2 \gset
select tpo_fd.check((select (x ->> 'handover_needed')::boolean and x ->> 'operator_id' = :'bo' from jsonb_array_elements(public.machine_checks_due(:'co', (:'today'::date + 2))) x where x ->> 'equipment_id' = :'ex')
                    and (select count(*) from jsonb_array_elements(public.machine_checks_due(:'co', (:'today'::date + 2))) x where x ->> 'equipment_id' = :'ex') = 1,
  'from the handover day, Bo is responsible and owes a handover check; Ann''s assignment is no longer due');
select tpo_fd.check((select count(*) from public.machine_checks where assignment_id = :'asg') = 2, 'Ann''s completed checks stay with her assignment');
select tpo_fd.as(:'bo', format('select public.record_machine_check(%L, gen_random_uuid(), %L, %L::jsonb, %s, p_kind => %L)::text', :'asg2', (:'today'::date + 2)::text,
  '[{"key": "grease", "answer": "yes"}, {"key": "leaks", "answer": "yes"}, {"key": "guards", "answer": "yes"}, {"key": "tracks", "answer": "yes"}]', tpo_fd.sig(), 'handover'));
select tpo_fd.check((select not (x ->> 'handover_needed')::boolean from jsonb_array_elements(public.machine_checks_due(:'co', (:'today'::date + 2))) x where x ->> 'equipment_id' = :'ex'),
  'Bo''s handover check clears it');

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops field tests passed.'
