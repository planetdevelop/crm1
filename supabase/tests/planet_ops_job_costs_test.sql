-- Planet Ops Phase 4: cost documents, review, the disposal register, the job's figures, and the PDOS
-- file record (20261127000100_planet_ops_job_costs.sql). Fictional records only.
-- Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_jc;
grant usage on schema tpo_jc to authenticated, service_role;
create function tpo_jc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_jc.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_jc.as(p_user uuid, p_sql text) returns text language plpgsql as $$
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
create function tpo_jc.sha(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'utf8')), 'hex') $$;
grant execute on all functions in schema tpo_jc to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e3000000-0000-0000-0000-000000000001', 'owner@planet-jc.test', '{"full_name": "Test Owner"}'),
  ('e3000000-0000-0000-0000-000000000002', 'office@planet-jc.test', '{"full_name": "Test Office"}'),
  ('e3000000-0000-0000-0000-000000000003', 'crew@planet-jc.test', '{"full_name": "Test Crew"}'),
  ('e3000000-0000-0000-0000-000000000004', 'crew2@planet-jc.test', '{"full_name": "Test Crew Two"}');
\set owner 'e3000000-0000-0000-0000-000000000001'
\set office 'e3000000-0000-0000-0000-000000000002'
\set crew 'e3000000-0000-0000-0000-000000000003'
\set crew2 'e3000000-0000-0000-0000-000000000004'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition JC', 'general') as co \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'office', 'office'), (:'co', :'crew', 'field_crew'), (:'co', :'crew2', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Costs Customer') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '12 Test Way', 'Testburg', 'CA', '95001') returning id as prop \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'prop', 'Garage demolition') returning id as req \gset

-- An estimate approved, a proposal from it signed and converted: the job.
select tpo_jc.as(:'owner', format('select public.create_estimate(%L, %L, %L, %L, p_project_type => %L)', :'co', 'a3000000-0000-0000-0000-0000000000e1', 'Garage demolition', :'req', 'Garage Demo')) as e1 \gset
select current_version_id as v1 from public.estimates where id = :'e1' \gset
select tpo_jc.check((select destination = 'jobs_bid' and status = 'pending' from public.pdos_files where source_kind = 'estimate_summary' and estimate_id = :'e1'),
  'a new estimate''s summary is queued for Jobs Bid: one standalone file, no folder');
select tpo_jc.as(:'owner', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v1',
  '{"pricing_method": "markup", "pricing_pct": 0.25, "owner_pay_method": "none", "lines": [{"key": "a", "section": "labor", "name": "Crew", "count": 2, "hours": 8, "days": 2, "unit": "hour", "unit_cost": 30, "customer_item": "Demolition"}, {"key": "b", "section": "disposal", "name": "Debris", "count": 4, "unit": "ton", "unit_cost": 90, "customer_item": "Haul-off"}, {"key": "c", "section": "contingency", "name": "Contingency", "count": 1, "unit": "lump", "unit_cost": 200, "customer_item": "Demolition"}]}'));
select tpo_jc.as(:'owner', format('select public.approve_estimate_version(%L, 1)::text', :'v1'));
select tpo_jc.as(:'owner', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'proposal', 'a3000000-0000-0000-0000-0000000000f1')) as q1 \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'q1';
select planet_test.sign(:'q1');
select tpo_jc.as(:'owner', format('select public.convert_quote_to_job(%L)::text', :'q1')) as job \gset
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'client', :'prop', 'Shed removal') returning id as job2 \gset
insert into public.visits (company_id, job_id, property_id, title, scheduled_on) values (:'co', :'job', :'prop', 'Demo day', private.company_today(:'co')) returning id as visit \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'visit', :'crew');

-- ===== Uploads: the original kept, the same file once =========================================
select tpo_jc.as(:'crew', format('select public.register_cost_document(%L, %L, %L, %L, %L, 1000, %L)::text', :'co', 'receipt', :'co' || '/receipts/fuel-1.jpg', tpo_jc.sha('fuel receipt 1'), 'fuel-1.jpg', :'job')) as r1 \gset
select (:'r1'::jsonb ->> 'id') as d1 \gset
select tpo_jc.check(not (:'r1'::jsonb ->> 'duplicate')::boolean, 'a crew member on the job uploads a fuel receipt from the field');
select tpo_jc.as(:'crew', format('select public.register_cost_document(%L, %L, %L, %L, %L, 1000, %L)::text', :'co', 'receipt', :'co' || '/receipts/fuel-1-again.jpg', tpo_jc.sha('fuel receipt 1'), 'fuel-1.jpg', :'job')) as r1b \gset
select tpo_jc.check((:'r1b'::jsonb ->> 'id') = :'d1' and (:'r1b'::jsonb ->> 'duplicate')::boolean and (select count(*) from public.cost_documents where company_id = :'co') = 1,
  'the same file again (a retry, a second phone) is the same document, not a second');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'crew', format('select public.register_cost_document(%L, %L, %L, %L, null, null, %L)::text', :'co', 'receipt', :'co' || '/receipts/x.jpg', tpo_jc.sha('x'), :'job2')),
  'nor onto a job they aren''t on', '%isn''t one you can add files to%');
select tpo_jc.check(tpo_jc.as(:'crew2', 'select count(*)::text from public.cost_documents') = '0', 'another crew member doesn''t see their receipt');
select tpo_jc.check(tpo_jc.as(:'crew', format('select count(*)::text from public.cost_documents where id = %L', :'d1')) = '1', 'the uploader sees their own');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'crew', format('select public.review_cost_document(%L, %L)::text', :'d1', 'rejected')), 'crew can''t review it', '%Not found%');
select tpo_jc.expect_error(format('update public.cost_documents set storage_path = %L where id = %L', 'elsewhere', :'d1'), 'the original file stays as uploaded (even for the database owner)', '%kept as it was uploaded%');
select tpo_jc.expect_error(format('delete from public.cost_documents where id = %L', :'d1'), 'and isn''t deleted', '%original is kept%');

-- ===== Suggestion vs review =====================================================================
select public.suggest_cost_document(:'d1', '{"vendor": "TEST Fuel Stop", "document_number": "A-100", "document_date": "2026-11-10", "total": 84.50, "category": "fuel", "confidence": 0.8}');
select tpo_jc.check((select review_status = 'pending' and category is null and suggested ->> 'category' = 'fuel' from public.cost_documents where id = :'d1'),
  'the reader''s suggestion waits for review: nothing counts yet');
select tpo_jc.check(not exists (select 1 from public.expenses where cost_document_id = :'d1'), 'no expense before review');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'office', format('select public.review_cost_document(%L, %L, %L, %L)::text', :'d1', 'approved', '{"category": "tools"}',
  jsonb_build_array(jsonb_build_object('job_id', :'job', 'amount', 60), jsonb_build_object('job_id', :'job2', 'amount', 30)))), 'allocations can''t add up to more than the receipt', '%more than the document''s total%');
select tpo_jc.as(:'office', format('select public.review_cost_document(%L, %L, %L, %L)::text', :'d1', 'approved', '{"category": "tools", "note": "Gas can and fuel"}',
  jsonb_build_array(jsonb_build_object('job_id', :'job', 'amount', 50), jsonb_build_object('job_id', :'job2', 'amount', 30)))) as rv \gset
select tpo_jc.check((:'rv'::jsonb ->> 'excluded')::numeric = 4.50 and (select count(*) = 2 and sum(amount) = 80 from public.expenses where cost_document_id = :'d1'),
  'the office corrects fuel → tools and splits it across two jobs; $4.50 stays unallocated');
select tpo_jc.as(:'office', format('select public.review_cost_document(%L, %L, %L, %L)::text', :'d1', 'approved', '{"category": "tools"}',
  jsonb_build_array(jsonb_build_object('job_id', :'job', 'amount', 50), jsonb_build_object('job_id', :'job2', 'amount', 30))));
select tpo_jc.check((select count(*) = 2 and sum(amount) = 80 from public.expenses where cost_document_id = :'d1'), 'approving again (a retry) replaces the shares, never adds them');
select tpo_jc.check((select suggested ->> 'category' = 'fuel' and category = 'tools' from public.cost_documents where id = :'d1')
                    and exists (select 1 from public.cost_document_events where document_id = :'d1' and kind = 'reviewed' and detail ->> 'suggested_category' = 'fuel' and detail -> 'to' ->> 'category' = 'tools'),
  'the suggestion and the correction are both kept, with who and when');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'office', format('update public.expenses set amount = 1 where cost_document_id = %L', :'d1')), 'a reviewed share isn''t edited by hand', '%reviewing the document again%');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'office', format('delete from public.expenses where cost_document_id = %L', :'d1')), 'nor deleted', '%reviewing the document again%');

-- ===== A likely duplicate (another photo of the same receipt) ==================================
select (tpo_jc.as(:'office', format('select public.register_cost_document(%L, %L, %L, %L, null, null, %L)::text', :'co', 'receipt', :'co' || '/receipts/fuel-1-photo2.jpg', tpo_jc.sha('another photo of receipt 1'), :'job'))::jsonb ->> 'id') as d2 \gset
select public.suggest_cost_document(:'d2', '{"vendor": "TEST Fuel Stop", "document_number": "A-100", "document_date": "2026-11-10", "total": 84.50, "category": "fuel"}');
select tpo_jc.check(exists (select 1 from public.cost_document_duplicates(:'d2') where id = :'d1'), 'it''s flagged as a likely duplicate of the first');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'office', format('select public.review_cost_document(%L, %L, %L, %L)::text', :'d2', 'approved', '{}', jsonb_build_array(jsonb_build_object('job_id', :'job', 'amount', 84.50)))),
  'approving it without saying why it isn''t a duplicate is refused', '%already entered%');
select tpo_jc.as(:'office', format('select public.review_cost_document(%L, %L, %L)::text', :'d2', 'duplicate', jsonb_build_object('duplicate_of', :'d1')));
select tpo_jc.check(not exists (select 1 from public.expenses where cost_document_id = :'d2') and (select sum(amount) = 50 from public.expenses where job_id = :'job'),
  'marked a duplicate: nothing added; the job''s receipt cost is still $50');

-- ===== Disposal register: a ticket's charge counts once ==========================================
select tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d1',
  '{"load_date": "2026-11-12", "hauler": "TEST Hauling", "facility": "TEST Transfer", "ticket_number": "T-501", "material_stream": "C&D", "gross_lb": 18400, "tare_lb": 12000, "container_capacity_cy": 20, "reported_loose_cy": 14, "tipping_fee": 288, "hauling_charge": 250}', 'new')) as t1 \gset
select tpo_jc.check((select short_tons = 3.2 and net_lb = 6400 and quantity_basis = 'weighed' and container_capacity_cy = 20 and reported_loose_cy = 14 and expense_id is not null from public.disposal_tickets where id = :'t1'),
  'a weighed ticket: 6,400 lb net = 3.2 tons; the 20 CY container and the 14 CY reported stay apart');
select tpo_jc.check(tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d1', '{"load_date": "2026-11-12", "tipping_fee": 288}', 'new')) = :'t1'
                    and tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d2', '{"facility": "TEST Transfer", "ticket_number": "t-501"}', 'new')) = :'t1'
                    and (select count(*) = 1 from public.expenses where job_id = :'job' and category = 'disposal'),
  'a retry, or the same ticket number entered again, is the same ticket: one disposal cost ($538)');
-- A metal load (not weighed), and a ticket whose receipt was entered as an expense already: linked, not added.
select tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d3', '{"load_date": "2026-11-13", "facility": "TEST Metals", "ticket_number": "M-9", "is_metal": true, "container_capacity_cy": 30, "reported_loose_cy": 10, "credit_amount": 40}'));
insert into public.expenses (company_id, job_id, vendor, category, amount, incurred_on) values (:'co', :'job', 'TEST Transfer', 'disposal', 180, '2026-11-14') returning id as exp3 \gset
select tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d4', '{"load_date": "2026-11-14", "facility": "TEST Transfer", "ticket_number": "T-502", "net_lb": 4000, "tipping_fee": 180}', 'link', :'exp3')) as t3 \gset
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'office', format('select public.record_disposal_ticket(%L, %L, %L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d5', '{"facility": "TEST Transfer", "ticket_number": "T-503", "tipping_fee": 180}', 'link', :'exp3')),
  'one expense can''t be two tickets'' cost', '%already another ticket%');
-- Delivered fill.
select tpo_jc.as(:'office', format('select public.record_disposal_ticket(%L, %L, %L)::text', :'job', 'a3000000-0000-0000-0000-0000000000d6', '{"direction": "delivered_fill", "load_date": "2026-11-15", "short_tons": 10}'));
select public.job_disposal_totals(:'job')::text as dt \gset
select tpo_jc.check((:'dt'::jsonb ->> 'loads')::int = 3 and (:'dt'::jsonb ->> 'weighed_tons')::numeric = 5.2 and (:'dt'::jsonb ->> 'unweighed_loads')::int = 1 and (:'dt'::jsonb ->> 'metal_loads_unweighed')::int = 1
                    and (:'dt'::jsonb ->> 'nominal_container_capacity_cy')::numeric = 50 and (:'dt'::jsonb ->> 'nonmetal_reported_loose_cy')::numeric = 14 and (:'dt'::jsonb ->> 'metal_reported_loose_cy')::numeric = 10
                    and (:'dt'::jsonb ->> 'delivered_fill_tons')::numeric = 10 and (:'dt'::jsonb ->> 'disposal_rate_per_ton')::numeric = 90,
  'totals: 3 outgoing loads, 5.2 weighed tons (the metal load unweighed, not 0), 50 CY of nominal capacity apart from 14 + 10 CY reported, fill apart; $468 ÷ 5.2 t = $90.00/t');
select tpo_jc.check((select count(*) = 2 and sum(amount) = 718 from public.expenses where job_id = :'job' and category = 'disposal'), 'disposal costs: $538 + $180, each once');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'crew', format('select public.record_disposal_ticket(%L, %L, %L, %L)::text', :'job', gen_random_uuid(), '{"tipping_fee": 1}', 'new')),
  'crew can record a ticket''s quantities, not its cost', '%entered by the office%');

-- ===== The job's figures, apart ==================================================================
select public.job_financials(:'job2')::text as f2 \gset
select tpo_jc.check((:'f2'::jsonb -> 'original_estimate') = 'null'::jsonb and (:'f2'::jsonb -> 'job_estimate') = 'null'::jsonb,
  'a job made directly has no estimate figures (missing, not $0)');
select tpo_jc.as(:'office', format('select public.job_financials(%L)::text', :'job')) as f1 \gset
select tpo_jc.check((:'f1'::jsonb -> 'original_estimate' ->> 'base_cost')::numeric = 1520 and (:'f1'::jsonb -> 'job_estimate' ->> 'version')::int = 1
                    and (:'f1'::jsonb -> 'actual_costs' ->> 'approved')::numeric = 230 and (:'f1'::jsonb -> 'actual_costs' ->> 'provisional')::numeric = 538
                    and (:'f1'::jsonb ->> 'contract_value')::numeric = 1900,
  'the job: original estimate $1,520 cost; actuals $230 approved and $538 provisional, kept apart; contract $1,900');
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'crew', format('select public.job_financials(%L)::text', :'job')), 'crew don''t get the job''s figures', '%Not found%');

-- ===== PDOS file record ==========================================================================
select tpo_jc.check((select destination = 'job_documents' and job_id = :'job' and version > 1 from public.pdos_files where source_kind = 'estimate_summary' and estimate_id = :'e1'),
  'once the job exists, the summary belongs in its Documents & Permits (the same file, a new version)');
select tpo_jc.check((select destination = 'job_receipts' from public.pdos_files where source_kind = 'cost_document' and source_id = :'d1'), 'the receipt belongs in the job''s Reciepts');
select (tpo_jc.as(:'office', format('select public.register_cost_document(%L, %L, %L, %L)::text', :'co', 'dump_ticket', :'co' || '/receipts/inbox-1.jpg', tpo_jc.sha('inbox ticket')))::jsonb ->> 'id') as d3 \gset
select tpo_jc.check((select destination = 'held' from public.pdos_files where source_id = :'d3'), 'a ticket with no job yet is held: no folder is made for it');
-- A lost bid: its summary stays for Jobs Bid.
select tpo_jc.as(:'owner', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a3000000-0000-0000-0000-0000000000e2', 'Barn (lost)', :'req')) as e2 \gset
select tpo_jc.expect_error(format('select tpo_jc.as(%L, %L)', :'owner', 'select public.pdos_claim()::text'), 'only the server claims backup work', '%permission denied%');
select public.pdos_claim(50)::text as claim \gset
select tpo_jc.check((select count(*) from jsonb_array_elements(:'claim'::jsonb -> 'folders') f where f ->> 'job_id' = :'job' and f ->> 'folder_name' = '12 Test Way - Garage Demo - ' || extract(year from now())::int) = 1,
  'the job''s folder is claimed with its name: {Project address} - {Project type} - {Year}');
select tpo_jc.check(not exists (select 1 from jsonb_array_elements(:'claim'::jsonb -> 'files') f where f ->> 'job_id' = :'job')
                    and exists (select 1 from jsonb_array_elements(:'claim'::jsonb -> 'files') f where f ->> 'source_id' = (select id::text from public.estimate_summaries where estimate_id = :'e2')),
  'the job''s files wait for its folders; the lost bid''s summary goes to Jobs Bid now');
select tpo_jc.check(not exists (select 1 from jsonb_array_elements(:'claim'::jsonb -> 'files') f where f ->> 'source_id' = :'d3'), 'the held ticket isn''t sent anywhere');
select tpo_jc.check((public.pdos_claim(50) -> 'folders') = '[]'::jsonb, 'claimed work isn''t claimed twice (a second worker gets nothing)');
-- The folder is made, then Drive fails on a subfolder: what was made is kept, and it's retried later.
select public.pdos_folder_progress(:'job', '{"folder": "drv-folder-1", "documents": "drv-docs-1"}', false, 'Drive: 503 backend error');
select tpo_jc.check((select status = 'failed' and steps ->> 'folder' = 'drv-folder-1' and steps ->> 'documents' = 'drv-docs-1' and next_attempt_at > now() and last_error like '%503%' from public.job_folder_provisioning where job_id = :'job'),
  'a partial failure keeps the folder already made and waits to retry');
select tpo_jc.check((public.pdos_claim(50) -> 'folders') = '[]'::jsonb, 'not before its retry time');
select tpo_jc.check(tpo_jc.as(:'owner', format('select public.pdos_retry(%L)::text', :'co'))::int >= 1, 'an owner can retry now');
select public.pdos_claim(50)::text as claim2 \gset
select tpo_jc.check((select f -> 'steps' ->> 'folder' = 'drv-folder-1' from jsonb_array_elements(:'claim2'::jsonb -> 'folders') f where f ->> 'job_id' = :'job'), 'the retry resumes with the same folder');
select public.pdos_folder_progress(:'job', '{"receipts": "drv-rcpt-1", "dump_tickets": "drv-dump-1", "media": "drv-media-1"}', true);
select tpo_jc.check((select status = 'done' and folder_id = 'drv-folder-1' and media_folder_id = 'drv-media-1' and attempts = 2 from public.job_folder_provisioning where job_id = :'job'), 'done: one folder set, made once');
select public.pdos_claim(50)::text as claim3 \gset
select tpo_jc.check((select count(*) from jsonb_array_elements(:'claim3'::jsonb -> 'files') f where f ->> 'job_id' = :'job') >= 2, 'now the job''s summary and receipt can go');
select id as sum_file, version as sum_ver from public.pdos_files where source_kind = 'estimate_summary' and estimate_id = :'e1' \gset
-- The summary changes while it's being copied: the newer version stays pending after this copy.
update public.estimate_summaries set title = title || ' (rev)' where estimate_id = :'e1';
select public.pdos_file_result(:'sum_file', :'sum_ver', 'drv-file-sum', 'drv-docs-1');
select tpo_jc.check((select status = 'pending' and drive_file_id = 'drv-file-sum' and backed_up_version = :'sum_ver'::int from public.pdos_files where id = :'sum_file'),
  'a newer version queued during a copy stays pending (and keeps the same Drive file)');
select tpo_jc.check((select status from public.pdos_files where source_id = (select id from public.estimate_summaries where estimate_id = :'e2')) = 'in_progress', 'the lost bid''s summary is out for copying');
select public.pdos_file_result(id, version, null, null, 'Drive: quota exceeded') from public.pdos_files where source_id = (select id from public.estimate_summaries where estimate_id = :'e2');
select tpo_jc.check((select status = 'failed' and last_error like '%quota%' from public.pdos_files where source_id = (select id from public.estimate_summaries where estimate_id = :'e2'))
                    and (tpo_jc.as(:'office', format('select public.pdos_status(%L)::text', :'co'))::jsonb -> 'failures') @> '[{"kind": "file"}]',
  'a failed copy shows on the status screen with its error');
select tpo_jc.check(not exists (select 1 from public.job_folder_provisioning where job_id = :'job2' and folder_id is not null) and (select count(*) from public.job_folder_provisioning where company_id = :'co') = 2,
  'one provisioning record per job; none for estimates, quotes or tickets');

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops job cost tests passed.'
