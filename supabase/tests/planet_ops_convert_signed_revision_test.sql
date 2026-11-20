-- Planet Ops Phase 1e: a job made from the exact signed revision, once; the job-created folder
-- handoff (20261121000300_planet_ops_convert_signed_revision.sql). Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_cv;
grant usage on schema tpo_cv to authenticated, service_role;
create function tpo_cv.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_cv.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema tpo_cv to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values ('a1000000-0000-0000-0000-000000000001', 'owner@planet-cv.test', '{"full_name": "Test Owner"}');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a1000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition CV', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Convert Customer') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '12 Test Lane', 'Roanoke', 'VA', '24011') returning id as property \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'TEST demolition request') returning id as request \gset
insert into public.quotes (company_id, client_id, property_id, request_id, title) values (:'co', :'client', :'property', :'request', 'House demolition') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 18000);
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
commit;

select tpo_cv.check(not exists (select 1 from public.job_folder_provisioning where company_id = :'co'), 'a request and a sent quote make no folder handoff');
-- Revised and sent again (version 2), then signed: version 2 is the agreement.
update public.quote_line_items set unit_price = 17500 where quote_id = :'quote';
select public.issue_quote_version(:'quote') as v2 \gset
select planet_test.sign(:'quote');
select tpo_cv.check((select status = 'approved' and approval ->> 'version_id' = :'v2' from public.quotes where id = :'quote'), 'the customer signs version 2');
select tpo_cv.check(not exists (select 1 from public.job_folder_provisioning where company_id = :'co'), 'signing makes no folder handoff either');
select tpo_cv.check(not exists (select 1 from public.jobs where quote_id = :'quote'), 'nor a job');

-- ===== Converting links the job to the request and the exact signed version ===================
select public.convert_quote_to_job(:'quote') as job \gset
select tpo_cv.check((select client_id = :'client' and property_id = :'property' and request_id = :'request' and quote_id = :'quote' and quote_version_id = :'v2' from public.jobs where id = :'job'),
  'the job links its customer, property, request and the exact signed version (2)');
select tpo_cv.check((select number from public.quote_versions where id = (select quote_version_id from public.jobs where id = :'job')) = 2
                    and (select signed_at is not null from public.quote_versions where id = :'v2'),
  'the signed version, not a later edit');
select tpo_cv.check((select count(*) = 1 and bool_and(source = 'converted' and status = 'pending') from public.job_folder_provisioning where job_id = :'job'),
  'one folder handoff for the new job, pending, from the conversion');

-- ===== Converting again opens the job it made =================================================
select tpo_cv.check(public.convert_quote_to_job(:'quote') = :'job', 'converting again returns the same job');
select tpo_cv.check(public.convert_quote_to_job(:'quote') = :'job', 'and again');
select tpo_cv.check((select count(*) from public.jobs where quote_id = :'quote') = 1
                    and (select count(*) from public.job_line_items where job_id = :'job') = 1
                    and (select count(*) from public.job_folder_provisioning where job_id = :'job') = 1,
  'one job, its lines once, one folder handoff');
select tpo_cv.expect_error(format('insert into public.jobs (company_id, client_id, title, quote_id) values (%L, %L, %L, %L)', :'co', :'client', 'A second job', :'quote'),
  'a second job can''t claim the same quote', '%jobs_one_per_quote%');

-- Two conversions at once: the second waits for the first, then finds its job.
select exists (select 1 from pg_available_extensions where name = 'dblink') as has_dblink \gset
\if :has_dblink
create extension if not exists dblink;
insert into public.quotes (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Garage demolition') returning id as race \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'race', 'Demolish garage', 1, 'ea', 6000);
update public.quotes set status = 'sent', sent_at = now() where id = :'race';
select planet_test.sign(:'race');
select dblink_connect('first', 'dbname=' || current_database()) is not null as a1 \gset
select dblink_connect('second', 'dbname=' || current_database()) is not null as a2 \gset
select dblink_exec('first', 'begin') is not null as b1 \gset
select (select j from dblink('first', format('select public.convert_quote_to_job(%L)::text', :'race')) as t(j text)) as first_job \gset
-- The second starts while the first holds the quote, and waits.
select dblink_send_query('second', format('select public.convert_quote_to_job(%L)::text', :'race')) = 1 as sent \gset
select dblink_exec('first', 'commit') is not null as c1 \gset
select (select j from dblink_get_result('second') as t(j text)) as second_job \gset
select dblink_disconnect('first') is not null as d1 \gset
select dblink_disconnect('second') is not null as d2 \gset
select tpo_cv.check(:'first_job' = :'second_job' and (select count(*) from public.jobs where quote_id = :'race') = 1,
  'two conversions at once make one job: the second gets the first''s');
\endif

-- ===== Change orders: finalized once, converting again returns the job ========================
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'CO: slab', :'job') returning id as co1 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co1', 'Remove slab', 1, 'ea', 2500);
update public.quotes set status = 'sent', sent_at = now() where id = :'co1';
select planet_test.sign(:'co1');
select tpo_cv.check(public.convert_quote_to_job(:'co1') = :'job' and public.convert_quote_to_job(:'co1') = :'job'
                    and (select count(*) from public.job_line_items where source_quote_id = :'co1') = 1,
  'a change order converted again returns its job, its lines added once');
select tpo_cv.check((select count(*) from public.job_folder_provisioning where company_id = :'co') = (select count(*) from public.jobs where company_id = :'co'),
  'a change order makes no folder handoff of its own');

-- ===== Create Job: the same handoff, never a signature ===========================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a1000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Direct job') returning id as direct \gset
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Unsigned') returning id as unsigned \gset
select tpo_cv.expect_error(format('insert into public.jobs (company_id, client_id, title, quote_id) values (%L, %L, %L, %L)', :'co', :'client', 'Claims a quote', :'unsigned'),
  'Create Job can''t claim an unsigned quote', '%customer signs%');
commit;
select tpo_cv.check((select count(*) = 1 and bool_and(source = 'direct' and status = 'pending') from public.job_folder_provisioning where job_id = :'direct'),
  'Create Job makes the same pending folder handoff');
select tpo_cv.check((select status from public.quotes where id = :'unsigned') = 'draft' and (select approval is null from public.quotes where id = :'unsigned'),
  'and claims nothing was accepted');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a1000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_cv.check((select count(*) from public.job_folder_provisioning where company_id = :'co') >= 2, 'the office reads the handoffs');
select tpo_cv.expect_error(format('insert into public.job_folder_provisioning (job_id, company_id, source) values (%L, %L, %L)', :'direct', :'co', 'direct'), 'but doesn''t write them');
commit;

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops convert signed revision tests passed.'
