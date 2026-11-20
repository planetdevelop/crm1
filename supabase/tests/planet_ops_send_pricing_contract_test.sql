-- Planet Ops Phase 1d: preparing pricing apart from sending it (send_pricing), the deposit's own
-- status, and the job's contract summary (20261121000200_planet_ops_send_pricing_and_contract.sql).
-- Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_sp;
grant usage on schema tpo_sp to authenticated, service_role;
create function tpo_sp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_sp.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema tpo_sp to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0f00000-0000-0000-0000-000000000001', 'owner@planet-sp.test', '{"full_name": "Test Owner"}'),
  ('a0f00000-0000-0000-0000-000000000002', 'drafter@planet-sp.test', '{"full_name": "Test Drafter"}'),
  ('a0f00000-0000-0000-0000-000000000003', 'estimator@planet-sp.test', '{"full_name": "Test Estimator"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition SP', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Pricing Customer') returning id as client \gset
commit;

-- ===== send_pricing ============================================================================
select tpo_sp.check('send_pricing' = any (private.level_permissions('estimator')) and 'send_pricing' = any (private.level_permissions('office'))
                    and not ('send_pricing' = any (private.level_permissions('crew_lead'))),
  'owners, admins, office and estimators can be given send_pricing; crew leads and field crews can''t');
select tpo_sp.check((select bool_and('send_pricing' = any (permissions)) from public.company_roles where company_id = :'co' and 'sales' = any (permissions)),
  'a new business''s roles that sell send too');
-- A role that prepares pricing without sending it, and an estimator on the built-in level.
insert into public.company_roles (company_id, name, description, base_role, permissions) values
  (:'co', 'Estimator (prepares pricing)', 'Builds quotes; someone else sends them.', 'estimator', array['sales', 'schedule']) returning id as drafter_role \gset
insert into public.memberships (company_id, user_id, role, role_id, active) values
  (:'co', 'a0f00000-0000-0000-0000-000000000002', 'estimator', :'drafter_role', true),
  (:'co', 'a0f00000-0000-0000-0000-000000000003', 'estimator', null, true);

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select tpo_sp.check(not public.can_send_pricing(:'co'), 'the drafter can''t send pricing');
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Drafted quote') returning id as drafted \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'drafted', 'Demolish shed', 1, 'ea', 3000);
update public.quotes set message = 'TEST message', deposit_amount = 500 where id = :'drafted';
select tpo_sp.check((select total = 3000 and message = 'TEST message' from public.quotes where id = :'drafted'), 'the drafter prepares a draft: lines, price, message, deposit');
select tpo_sp.expect_error(format('update public.quotes set status = %L, sent_at = now() where id = %L', 'sent', :'drafted'),
  'but can''t mark it sent', '%Send pricing to customers%');
select tpo_sp.expect_error(format('insert into public.quotes (company_id, client_id, title, status) values (%L, %L, %L, %L)', :'co', :'client', 'Sneaky', 'sent'),
  'nor add one already sent', '%Send pricing to customers%');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select tpo_sp.check(public.can_send_pricing(:'co'), 'an estimator on the built-in level still sends');
update public.quotes set status = 'sent', sent_at = now() where id = :'drafted';
commit;
select tpo_sp.check((select status from public.quotes where id = :'drafted') = 'sent' and exists (select 1 from public.quote_versions where quote_id = :'drafted'),
  'so the estimator sends what the drafter prepared');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
update public.quote_line_items set unit_price = 3200 where quote_id = :'drafted';
select tpo_sp.check((select total from public.quotes where id = :'drafted') = 3200, 'the drafter can still revise it (a draft revision)');
select tpo_sp.expect_error(format('select public.issue_quote_version(%L)', :'drafted'), 'but not send the revision', '%Send pricing to customers%');
select tpo_sp.expect_error(format('update public.quotes set sent_at = now() where id = %L', :'drafted'), 'nor resend it by its date', '%Send pricing to customers%');
select tpo_sp.expect_error(format('update public.quotes set exact_sent_at = now() where id = %L', :'drafted'), 'nor send its exact price', '%Send pricing to customers%');
commit;
select tpo_sp.check((select count(*) from public.quote_versions where quote_id = :'drafted') = 1, 'nothing more went out');
-- Taking the area off a role stops its sending.
update public.company_roles set permissions = array['sales', 'schedule'] where company_id = :'co' and name = 'Office manager';
select tpo_sp.check((select not ('send_pricing' = any (permissions)) from public.company_roles where company_id = :'co' and name = 'Office manager'), 'a role can be set to prepare only');

-- ===== The deposit's own status =================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_sp.check((public.quote_deposit_status(:'drafted') ->> 'asked')::numeric = 500 and public.quote_deposit_status(:'drafted') ->> 'paid' is null,
  'a deposit asked for and not paid: asked 500, nothing paid');
commit;
select planet_test.sign(:'drafted');
select tpo_sp.check((select status from public.quotes where id = :'drafted') = 'approved'
                    and (public.quote_deposit_status(:'drafted') ->> 'paid') is distinct from '500.00',
  'signing it isn''t paying the deposit');

-- ===== The job's contract summary ===============================================================
select public.convert_quote_to_job(:'drafted') as job \gset
-- Change orders in every state: a charge, a credit and a $0 change finalized; one awaiting the
-- customer, one with changes requested, a draft, one declined and one cancelled.
create function tpo_sp.co(p_company uuid, p_client uuid, p_job uuid, p_title text, p_price numeric) returns uuid language plpgsql as $fn$
declare v uuid;
begin
  insert into public.quotes (company_id, client_id, title, change_order_for) values (p_company, p_client, p_title, p_job) returning id into v;
  insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (p_company, v, p_title, 1, 'ea', p_price);
  return v;
end $fn$;
select tpo_sp.co(:'co', :'client', :'job', 'CO charge', 2500) as co_charge \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO credit', -800) as co_credit \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO zero', 0) as co_zero \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO waiting', 1000) as co_waiting \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO asked', 600) as co_asked \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO draft', 300) as co_draft \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO declined', 400) as co_declined \gset
select tpo_sp.co(:'co', :'client', :'job', 'CO cancelled', 700) as co_cancelled \gset
update public.quotes set status = 'sent', sent_at = now() where id in (:'co_charge', :'co_credit', :'co_zero', :'co_waiting', :'co_asked', :'co_declined', :'co_cancelled');
select planet_test.sign(:'co_charge');
select planet_test.sign(:'co_credit');
select planet_test.sign(:'co_zero');
-- A retried signature applies nothing twice.
select planet_test.sign(:'co_charge');
select public.request_quote_changes(:'co', :'co_asked', 'TEST please change', 'c0000000-0000-4000-8000-000000000001', null) is not null as asked \gset
update public.quotes set status = 'lost' where id = :'co_declined';
update public.quotes set status = 'archived' where id = :'co_cancelled';

-- An invoice for part of it, partly paid.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.invoices (company_id, client_id, job_id, subject, due_on) values (:'co', :'client', :'job', 'Progress 1', current_date + 30) returning id as inv \gset
insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit_price, taxable, sort) values (:'co', :'inv', 'Progress', 1, 2000, false, 0);
update public.invoices set status = 'sent' where id = :'inv';
insert into public.payments (company_id, client_id, invoice_id, amount, method) values (:'co', :'client', :'inv', 1500, 'check');
insert into public.invoices (company_id, client_id, job_id, subject, due_on) values (:'co', :'client', :'job', 'Still a draft', current_date + 30) returning id as draft_inv \gset
insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit_price, taxable, sort) values (:'co', :'draft_inv', 'Not sent', 1, 999, false, 0);
select public.job_contract_summary(:'job') as summary \gset
commit;
select tpo_sp.check((:'summary'::jsonb ->> 'original_amount')::numeric = 3200, 'the original signed agreement: $3,200, as signed');
select tpo_sp.check((:'summary'::jsonb ->> 'finalized_changes')::numeric = 1700, 'finalized changes: +$2,500, −$800 and $0, each once ($1,700)');
select tpo_sp.check((:'summary'::jsonb ->> 'revised_total')::numeric = 4900, 'the revised contract total: $4,900');
select tpo_sp.check((select string_agg((o ->> 'title') || '=' || (o ->> 'state'), ',' order by o ->> 'title') from jsonb_array_elements(:'summary'::jsonb -> 'change_orders') o)
                    = 'CO asked=changes_requested,CO cancelled=cancelled,CO charge=finalized,CO credit=finalized,CO declined=declined,CO draft=draft,CO waiting=awaiting_signature,CO zero=finalized',
  'each change order is listed with its state; unsigned, declined, cancelled and changes-requested ones count for nothing');
select tpo_sp.check((:'summary'::jsonb ->> 'invoiced')::numeric = 2000 and (:'summary'::jsonb ->> 'paid')::numeric = 1500
                    and (:'summary'::jsonb ->> 'outstanding')::numeric = 500 and (:'summary'::jsonb ->> 'not_yet_invoiced')::numeric = 2900,
  'invoiced $2,000 (not the draft), paid $1,500, $500 outstanding, $2,900 not yet invoiced');
select tpo_sp.check((select count(*) from public.invoices where job_id = :'job') = 2 and (select count(*) from public.payments where invoice_id = :'inv') = 1,
  'the revised total made no invoice or payment of its own');
select tpo_sp.check((select count(*) from public.job_line_items where job_id = :'job' and source_quote_id in (:'co_charge', :'co_credit', :'co_zero')) = 3,
  'each finalized change joined the job once');
-- Someone without the invoices area sees the contract, not the invoices.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0f00000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select tpo_sp.check((public.job_contract_summary(:'job') ->> 'invoices_visible')::boolean = false and public.job_contract_summary(:'job') ->> 'invoiced' is null
                    and (public.job_contract_summary(:'job') ->> 'revised_total')::numeric = 4900,
  'an estimator sees the contract summary without invoice figures');
commit;

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops send pricing and contract tests passed.'
