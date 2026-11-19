-- Planet Ops Phase 1: a change order is finalized (added to its job) only with the customer's
-- signature on its exact current version: added charges, credits and $0 changes alike. No staff
-- status change, "manual" approval, conversion or direct insert gets around it
-- (20261120000100_planet_ops_change_order_signature.sql). Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_co;
grant usage on schema tpo_co to authenticated, service_role;
create function tpo_co.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_co.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema tpo_co to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0c00000-0000-0000-0000-000000000001', 'owner@planet.test', '{"full_name": "Test Owner"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Sample Customer') returning id as client \gset
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'House demolition') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 18000);
select public.convert_quote_to_job(:'quote') as job \gset

-- An added charge, sent to the customer.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: remove garage slab', :'job') returning id as add \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'add', 'Remove garage slab', 1, 'ea', 2500) returning id as add_line \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'add';

-- The office can't finalize it: not by status, not with a "manual" approval, not by converting it.
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'add'),
  'the office can''t mark an unsigned change order approved', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = ''{"name": "Test Owner", "method": "manual"}'' where id = %L', :'add'),
  'nor with a manual approval in its own name', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = jsonb_build_object(''name'', ''Test Owner'', ''method'', ''manual'', ''signed_at'', now(), ''total'', total) where id = %L', :'add'),
  'nor with a manual approval that has a date and the total', '%customer signs this exact version%');
select tpo_co.expect_error(format('select public.convert_quote_to_job(%L)', :'add'),
  'converting an unsigned change order is refused too', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''converted'', converted_at = now() where id = %L', :'add'),
  'and so is marking it added to the job', '%customer signs this exact version%');
select tpo_co.expect_error(format('insert into public.quotes (company_id, client_id, title, status, change_order_for) values (%L, %L, ''Sneaky'', ''converted'', %L)', :'co', :'client', :'job'),
  'a change order can''t be inserted already finalized without a signature', '%customer signs this exact version%');
select tpo_co.check((select status from public.quotes where id = :'add') = 'sent', 'it''s still waiting for the customer');
select tpo_co.check(not exists (select 1 from public.job_line_items where source_quote_id = :'add'), 'and nothing was added to the job');
commit;

-- A signature on a different version (another total) isn't this version's.
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = jsonb_build_object(''name'', ''Test Customer'', ''signed_at'', now(), ''total'', 2000) where id = %L', :'add'),
  'a signature for another price doesn''t finalize it', '%changed after the customer signed%');

-- The customer signs on their link: it's finalized and joins the job, exactly once.
select tpo_co.check(public.approve_hub_quote(:'co', :'add', '{}', '{"name": "Test Customer", "signed_at": "2026-11-20T15:00:00Z", "ip": "203.0.113.5"}'), 'the customer signs the change order on their link');
select tpo_co.check((select status from public.quotes where id = :'add') = 'converted', 'it''s finalized and added to the job');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add' and unit_price = 2500) = 1, 'its line is on the job once');
select tpo_co.check(not public.approve_hub_quote(:'co', :'add', '{}', '{"name": "Test Customer", "signed_at": "2026-11-20T15:01:00Z"}'), 'a repeated signature does nothing');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add') = 1, 'and adds nothing twice');

-- Once signed and finalized, its lines can't change.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quote_line_items set unit_price = 1 where id = %L', :'add_line'), 'a signed change order''s price can''t change');
select tpo_co.expect_error(format('insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (%L, %L, ''Extra'', 1, ''ea'', 10)', :'co', :'add'), 'nor can lines be added to it');
select tpo_co.expect_error(format('delete from public.quote_line_items where id = %L', :'add_line'), 'nor removed');

-- A credit and a $0 schedule change need the signature too.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: leave the shed', :'job') returning id as credit \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'credit', 'Leave the shed standing (credit)', 1, 'ea', -800);
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: start a week later', :'job') returning id as zero \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'zero', 'Start date moves one week later', 1, 'ea', 0);
update public.quotes set status = 'sent', sent_at = now() where id in (:'credit', :'zero');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'credit'), 'an unsigned credit isn''t finalized', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'zero'), 'nor an unsigned $0 change', '%customer signs this exact version%');
select tpo_co.check(not exists (select 1 from public.job_line_items where source_quote_id in (:'credit', :'zero')), 'neither touched the job');
commit;

select tpo_co.check(public.approve_hub_quote(:'co', :'credit', '{}', '{"name": "Test Customer", "signed_at": "2026-11-20T16:00:00Z"}'), 'the customer signs the credit');
select tpo_co.check(public.approve_hub_quote(:'co', :'zero', '{}', '{"name": "Test Customer", "signed_at": "2026-11-20T16:05:00Z"}'), 'and the $0 change');
select tpo_co.check((select coalesce(sum(round(quantity * unit_price, 2)), 0) from public.job_line_items where job_id = :'job') = 18000 + 2500 - 800,
  'the job is the original agreement plus the signed changes, credit included');
select tpo_co.check((select count(*) from public.quotes where change_order_for = :'job' and status = 'converted') = 3, 'all three signed change orders are finalized');

-- The rule as a function, for the record.
select tpo_co.check(not private.change_order_customer_signed(null, 0), 'no approval is no signature');
select tpo_co.check(not private.change_order_customer_signed('{"name": "A", "signed_at": "2026-01-01", "total": 0, "method": "manual"}', 0), 'a manual approval is no signature');
select tpo_co.check(not private.change_order_customer_signed('{"name": " ", "signed_at": "2026-01-01", "total": 0}', 0), 'a blank name is no signature');
select tpo_co.check(private.change_order_customer_signed('{"name": "A", "signed_at": "2026-01-01", "total": "10.00", "method": "in_person"}', 10), 'signed in person counts');

delete from public.companies where id = :'co';
\o
\echo 'All Planet Ops change-order signature tests passed.'
