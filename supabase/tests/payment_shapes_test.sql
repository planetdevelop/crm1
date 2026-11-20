-- Database tests for 20261113001600_scheduled_payments_bill_what_was_signed.sql: whatever the shape
-- of a quote's payment schedule, the invoices its job makes are the payments the client signed. One
-- invoice per payment, each for its amount to the cent, in order; together they come to the quote's
-- total and carry the quote's tax; nothing else is made (no final invoice after the last payment),
-- and the finished job closes instead of asking for another invoice.
--
-- It runs a grid: sixteen shapes of two to five payments (with and without a payment at approval,
-- with and without one for when the work is done, percents and dollar amounts, amounts that don't
-- divide evenly, a last payment smaller than the tax) against five prices (untaxed, taxed, partly
-- taxed, awkward rates), the payment at approval made by the Client Hub or by the office's Deposit
-- button. Then jobs that were part-way through a schedule before this migration.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpg;
grant usage on schema tpg to authenticated, service_role;
create function tpg.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpg.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tpg.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- A job's payments as "position:amount:invoice kind/total" (or "-"), in order.
create function tpg.rows(p_job uuid) returns text language sql stable as $$
  select string_agg(s.position || ':' || s.amount || ':' || coalesce(i.kind || '/' || i.total || case when i.status = 'void' then '/void' else '' end, '-'), ', ' order by s.position)
  from public.job_installments s left join public.invoices i on i.id = s.invoice_id
  where s.job_id = p_job
$$;

/**
 * One job through its whole schedule, as the office, the crew and the hourly run would take it: the
 * quote is sent and approved (in the Client Hub, which makes the deposit invoice, or by the office,
 * who then presses Deposit), made a job with two visits, and each payment's moment comes in order:
 * its date (the hourly run), the first visit started, Invoice now, and the job's Invoice button once
 * the visits are finished. Returns what's wrong with what was billed, or null.
 */
create function tpg.run(p_company uuid, p_client uuid, p_office uuid, p_taxed numeric, p_untaxed numeric, p_rate numeric, p_shape jsonb, p_hub boolean)
returns text language plpgsql as $$
declare
  v_quote uuid;
  v_job uuid;
  v_v1 uuid;
  v_v2 uuid;
  v_today date := private.company_today(p_company);
  v_rows jsonb;
  q public.quotes;
  r record;
  v_finished boolean := false;
  v_wrong text[] := '{}';
  v_previous bigint := 0;
begin
  perform tpg.as_user(p_office);
  insert into public.quotes (company_id, client_id, title, tax_rate) values (p_company, p_client, 'Shape', p_rate) returning id into v_quote;
  insert into public.quote_line_items (company_id, quote_id, name, unit_price, taxable)
  select p_company, v_quote, x.name, x.price, x.taxable
    from (values ('Taxed work', p_taxed, p_rate > 0), ('Untaxed work', p_untaxed, false)) x (name, price, taxable) where x.price > 0;
  select coalesce(jsonb_agg(case when e.value ->> 'due' = 'date' then e.value || jsonb_build_object('on', (v_today + 3)::text) else e.value end order by e.i), '[]')
    into v_rows from jsonb_array_elements(p_shape) with ordinality e (value, i);
  update public.quotes set payment_schedule = v_rows, status = 'sent', sent_at = now() where id = v_quote;
  if p_hub then
    -- The client hub's server calls these as itself, never as someone signed in.
    perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
    perform public.approve_hub_quote(p_company, v_quote, null, planet_test.approval(v_quote, '{"name": "Erin Estes"}'));
    perform public.hub_deposit_invoice(p_company, v_quote);
    perform tpg.as_user(p_office);
  else
    perform planet_test.sign(v_quote);
  end if;
  v_job := public.convert_quote_to_job(planet_test.sign(v_quote));
  select * into q from public.quotes where id = v_quote;
  insert into public.visits (company_id, job_id, title, scheduled_on) values (p_company, v_job, 'First day', v_today) returning id into v_v1;
  insert into public.visits (company_id, job_id, title, scheduled_on) values (p_company, v_job, 'Second day', v_today + 1) returning id into v_v2;

  for r in select s.* from public.job_installments s where s.job_id = v_job order by s.position loop
    if r.due = 'approval' then
      if not p_hub then
        perform public.create_invoice_for_job(v_job, 'deposit');
      end if;
    elsif r.due = 'date' then
      update public.job_installments set due_on = v_today where id = r.id;
      perform public.make_due_installments();
    elsif r.due = 'work_starts' then
      update public.visits set status = 'in_progress' where id = v_v1 and status = 'scheduled';
    elsif r.due = 'by_hand' then
      perform public.invoice_installment(r.id);
    else
      update public.visits set status = 'completed' where id in (v_v1, v_v2);
      v_finished := true;
      -- The job's Invoice button.
      perform public.create_invoice_for_job(v_job);
    end if;
  end loop;
  if not v_finished then
    update public.visits set status = 'completed' where id in (v_v1, v_v2);
  end if;

  if (select count(*) from public.job_installments where job_id = v_job) <> jsonb_array_length(p_shape) then
    v_wrong := v_wrong || 'the job doesn''t have a row for each payment'::text;
  end if;
  if (select sum((e.value ->> 'amount')::numeric) from jsonb_array_elements(q.approval -> 'payment_schedule') e) <> q.total then
    v_wrong := v_wrong || format('the signed payments come to %s, not the quote''s %s',
      (select sum((e.value ->> 'amount')::numeric) from jsonb_array_elements(q.approval -> 'payment_schedule') e), q.total);
  end if;
  for r in
    select s.position, s.amount, i.id as invoice_id, i.number, i.total, i.status
      from public.job_installments s left join public.invoices i on i.id = s.invoice_id and i.status <> 'void'
     where s.job_id = v_job order by s.position
  loop
    if r.invoice_id is null then
      v_wrong := v_wrong || format('payment %s has no invoice', r.position);
    elsif r.total <> r.amount then
      v_wrong := v_wrong || format('payment %s was signed at %s and invoiced at %s', r.position, r.amount, r.total);
    elsif r.number <= v_previous then
      v_wrong := v_wrong || format('payment %s''s invoice isn''t after the one before it', r.position);
    end if;
    v_previous := coalesce(r.number, v_previous);
  end loop;
  if (select count(*) from public.invoices where job_id = v_job and status <> 'void') <> jsonb_array_length(p_shape) then
    v_wrong := v_wrong || format('%s invoices for %s payments', (select count(*) from public.invoices where job_id = v_job and status <> 'void'), jsonb_array_length(p_shape));
  end if;
  if (select count(distinct invoice_id) from public.job_installments where job_id = v_job) <> jsonb_array_length(p_shape) then
    v_wrong := v_wrong || 'two payments share an invoice'::text;
  end if;
  if (select coalesce(sum(total), 0) from public.invoices where job_id = v_job and status <> 'void') <> q.total then
    v_wrong := v_wrong || format('the invoices come to %s, the quote to %s', (select sum(total) from public.invoices where job_id = v_job and status <> 'void'), q.total);
  end if;
  if (select coalesce(sum(tax_amount), 0) from public.invoices where job_id = v_job and status <> 'void') <> q.tax_amount then
    v_wrong := v_wrong || format('the invoices'' tax is %s, the quote''s %s', (select sum(tax_amount) from public.invoices where job_id = v_job and status <> 'void'), q.tax_amount);
  end if;
  if (select status from public.jobs where id = v_job) <> 'completed' then
    v_wrong := v_wrong || format('the finished, fully invoiced job is %s', (select status from public.jobs where id = v_job));
  end if;
  -- With no payment waiting for the work to be done, everything was invoiced before the last visit
  -- was finished, so nobody was asked for an invoice.
  if not p_shape @> '[{"due": "work_done"}]'
     and exists (select 1 from public.notifications n where n.link = '/jobs/' || v_job and n.title like '%ready to invoice') then
    v_wrong := v_wrong || 'the office was asked to invoice a job that was fully invoiced'::text;
  end if;
  return case when cardinality(v_wrong) > 0 then array_to_string(v_wrong, '; ') || ' [' || coalesce(tpg.rows(v_job), 'no rows') || ']' end;
exception when others then
  return 'it stopped with ' || sqlstate || ': ' || sqlerrm;
end $$;
grant execute on all functions in schema tpg to authenticated, service_role;

\set pat 'a6c00000-0000-0000-0000-000000000001'
\set olly 'a6c00000-0000-0000-0000-000000000002'

begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@grid-patios.test', '{"full_name": "Pat Grid"}'),
  (:'olly', 'olly@grid-patios.test', '{"full_name": "Olly Grid"}');
set local role authenticated;
select tpg.as_user(:'pat');
select public.create_company('Grid Patios', 'general', 'America/Chicago') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olly', 'office');
insert into public.clients (company_id, display_name, email) values (:'co', 'Erin Estes', 'erin@example.test') returning id as erin \gset
commit;

-- ===== The grid ==================================================================================
create table tpg.shapes (name text primary key, shape jsonb not null);
insert into tpg.shapes values
  ('half at approval, the rest as the work starts',
   '[{"kind": "percent", "value": 50, "due": "approval"}, {"kind": "rest", "due": "work_starts"}]'),
  ('half at approval, the rest when the work is done',
   '[{"kind": "percent", "value": 50, "due": "approval"}, {"kind": "rest", "due": "work_done"}]'),
  ('half as the work starts, half when it''s done',
   '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "percent", "value": 50, "due": "work_done"}]'),
  ('two dated halves',
   '[{"kind": "percent", "value": 50, "due": "date"}, {"kind": "percent", "value": 50, "due": "date"}]'),
  ('a cent at approval, the rest when the work is done',
   '[{"kind": "amount", "value": 0.01, "due": "approval"}, {"kind": "rest", "due": "work_done"}]'),
  ('95% at approval, the rest (less than the tax) as the work starts',
   '[{"kind": "percent", "value": 95, "due": "approval"}, {"kind": "rest", "due": "work_starts"}]'),
  ('three thirds: approval, work starts, a date',
   '[{"kind": "percent", "value": 33.33, "due": "approval"}, {"kind": "percent", "value": 33.33, "due": "work_starts"}, {"kind": "rest", "due": "date"}]'),
  ('30% at approval, 30% as the work starts, 40% when it''s done',
   '[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "percent", "value": 30, "due": "work_starts"}, {"kind": "percent", "value": 40, "due": "work_done"}]'),
  ('$250 at approval, $333.33 on a date, the rest when the work is done',
   '[{"kind": "amount", "value": 250, "due": "approval"}, {"kind": "amount", "value": 333.33, "due": "date"}, {"kind": "rest", "due": "work_done"}]'),
  ('three thirds with nothing at approval and nothing at the end',
   '[{"kind": "percent", "value": 33.33, "due": "work_starts"}, {"kind": "percent", "value": 33.33, "due": "date"}, {"kind": "percent", "value": 33.34, "due": "by_hand"}]'),
  ('three by hand, in dollars',
   '[{"kind": "amount", "value": 100.10, "due": "by_hand"}, {"kind": "amount", "value": 200.20, "due": "by_hand"}, {"kind": "rest", "due": "by_hand"}]'),
  ('30% at approval, 60% when the work is done, the rest held back to a date',
   '[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "percent", "value": 60, "due": "work_done"}, {"kind": "rest", "due": "date"}]'),
  ('four quarters ending when the work is done',
   '[{"kind": "percent", "value": 25, "due": "date"}, {"kind": "percent", "value": 25, "due": "work_starts"}, {"kind": "percent", "value": 25, "due": "by_hand"}, {"kind": "rest", "due": "work_done"}]'),
  ('four with the work-done payment third',
   '[{"kind": "percent", "value": 40, "due": "work_starts"}, {"kind": "percent", "value": 12.5, "due": "by_hand"}, {"kind": "percent", "value": 35, "due": "work_done"}, {"kind": "rest", "due": "date"}]'),
  ('five, percents and dollars, ending when the work is done',
   '[{"kind": "percent", "value": 20, "due": "approval"}, {"kind": "amount", "value": 200, "due": "date"}, {"kind": "percent", "value": 20, "due": "work_starts"}, {"kind": "amount", "value": 200, "due": "by_hand"}, {"kind": "rest", "due": "work_done"}]'),
  ('five with no payment for when the work is done',
   '[{"kind": "percent", "value": 10, "due": "approval"}, {"kind": "percent", "value": 15, "due": "work_starts"}, {"kind": "percent", "value": 20, "due": "date"}, {"kind": "percent", "value": 25, "due": "by_hand"}, {"kind": "rest", "due": "date"}]');

create table tpg.prices (name text primary key, taxed numeric not null, untaxed numeric not null, rate numeric not null);
insert into tpg.prices values
  ('$1,000 untaxed', 0, 1000, 0),
  ('$1,000 taxed at 10%', 1000, 0, 0.10),
  ('$999.99 taxed at 8.25%', 999.99, 0, 0.0825),
  ('$700.01 taxed at 7% with $300 untaxed', 700.01, 300, 0.07),
  ('$1,234.57 taxed at 6.625%', 1234.57, 0, 0.06625);

create table tpg.results as
select s.name as shape, p.name as price, h.hub,
       tpg.run(:'co', :'erin', :'olly', p.taxed, p.untaxed, p.rate, s.shape, h.hub) as wrong
  from tpg.shapes s cross join tpg.prices p cross join (values (true), (false)) h (hub)
 -- With nothing due at approval the two ways of approving bill the same, so once is enough.
 where h.hub or s.shape @> '[{"due": "approval"}]';

select tpg.check((select count(*) = 130 from tpg.results), 'the grid ran 16 shapes at 5 prices, those with a payment at approval both ways: 130 jobs');
select tpg.check(not exists (select 1 from tpg.results where wrong is not null),
  'every job''s invoices are the signed payments, one each, in order, to the quote''s total and tax, and the job closes'
  || coalesce((select E'\n' || string_agg(format('  %s, %s, %s: %s', shape, price, case when hub then 'approved in the Hub' else 'approved by the office' end, wrong), E'\n' order by shape, price, hub)
                 from (select * from tpg.results where wrong is not null order by shape, price, hub limit 12) x), ''));

-- ===== Jobs that were part-way through a schedule before this ====================================
-- Before, a payment after the deposit was a progress invoice for its amount before tax, held to
-- what was left of the contract before tax. Those invoices are made here as that release made them.
create function tpg.old_job(p_company uuid, p_client uuid, p_office uuid, p_price numeric, p_rate numeric, p_shape jsonb) returns uuid language plpgsql as $$
declare
  v_quote uuid;
  v_job uuid;
begin
  perform tpg.as_user(p_office);
  insert into public.quotes (company_id, client_id, title, tax_rate) values (p_company, p_client, 'Before', p_rate) returning id into v_quote;
  insert into public.quote_line_items (company_id, quote_id, name, unit_price, taxable) values (p_company, v_quote, 'Work', p_price, p_rate > 0);
  update public.quotes set payment_schedule = p_shape where id = v_quote;
  perform planet_test.sign(v_quote);
  v_job := public.convert_quote_to_job(planet_test.sign(v_quote));
  insert into public.visits (company_id, job_id, title, scheduled_on) values (p_company, v_job, 'The day', private.company_today(p_company));
  return v_job;
end $$;
-- A progress invoice as the release before made a payment's: for p_amount before tax, taxed.
create function tpg.old_payment(p_job uuid, p_position integer, p_amount numeric) returns void language plpgsql as $$
declare
  v_invoice uuid := public.create_invoice_for_job(p_job, 'progress', p_amount);
begin
  update public.job_installments set invoice_id = v_invoice, made_at = now() where job_id = p_job and position = p_position;
end $$;

-- The reviewer's job, caught after its deposit: the second and last payment is the final invoice.
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0.10, '[{"kind": "percent", "value": 50, "due": "approval"}, {"kind": "rest", "due": "work_starts"}]') as caught \gset
select public.create_invoice_for_job(:'caught', 'deposit') as caught_deposit \gset
update public.visits set status = 'completed' where job_id = :'caught';
select tpg.check(tpg.rows(:'caught') = '1:550.00:deposit/550.00, 2:550.00:standard/550.00'
  and (select sum(total) = 1100 and sum(tax_amount) = 100 and count(*) = 2 from public.invoices where job_id = :'caught')
  and (select status = 'completed' from public.jobs where id = :'caught'),
  'a job caught after its $550 deposit bills the other $550 as its final invoice, $1,100 and $100 of tax in two invoices, and closes');

-- The same job caught after its second payment was made $55 short: nothing can make that invoice
-- the $550 signed, but the job still asks for its invoice, which bills the $55 of tax still owed.
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0.10, '[{"kind": "percent", "value": 50, "due": "approval"}, {"kind": "rest", "due": "work_starts"}]') as short \gset
select public.create_invoice_for_job(:'short', 'deposit') as short_deposit \gset
select tpg.old_payment(:'short', 2, 450);
update public.visits set status = 'completed' where job_id = :'short';
select tpg.check(tpg.rows(:'short') = '1:550.00:deposit/550.00, 2:550.00:progress/495.00'
  and (select status = 'requires_invoicing' from public.jobs where id = :'short'),
  'a job whose last payment was already made $55 short still asks for its invoice');
select public.create_invoice_for_job(:'short') as short_final \gset
select tpg.check((select total = 55 from public.invoices where id = :'short_final')
  and (select sum(total) = 1100 and sum(tax_amount) = 100 from public.invoices where job_id = :'short')
  and (select status = 'completed' from public.jobs where id = :'short'),
  'and that invoice bills the $55 left, so the job comes to $1,100 with $100 of tax');

-- A job whose payments were all made, as progress invoices, and that has nothing left to bill:
-- before, it asked for a final invoice of $0. It closes.
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0, '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "percent", "value": 50, "due": "by_hand"}]') as billed \gset
select tpg.old_payment(:'billed', 1, 500);
select tpg.old_payment(:'billed', 2, 500);
update public.visits set status = 'completed' where job_id = :'billed';
select tpg.check((select status = 'completed' from public.jobs where id = :'billed')
  and (select count(*) = 2 and sum(total) = 1000 from public.invoices where job_id = :'billed')
  and not exists (select 1 from public.notifications n where n.link = '/jobs/' || :'billed' and n.title like '%ready to invoice'),
  'a job whose two progress invoices already billed all of it closes without asking for a $0 invoice');

-- One with a payment made the old way and one still to come: the one to come is the final invoice,
-- which takes the old one off as it was billed, so the job comes to its total.
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0.10, '[{"kind": "percent", "value": 40, "due": "work_starts"}, {"kind": "rest", "due": "by_hand"}]') as mixed \gset
select tpg.old_payment(:'mixed', 1, 400);
begin;
select tpg.as_user(:'olly');
select public.invoice_installment((select id from public.job_installments where job_id = :'mixed' and position = 2)) as mixed_final \gset
commit;
select tpg.check(tpg.rows(:'mixed') = '1:440.00:progress/440.00, 2:660.00:standard/660.00'
  and (select sum(total) = 1100 and sum(tax_amount) = 100 from public.invoices where job_id = :'mixed'),
  'a job with a taxed progress payment from before and one to come bills the rest as its final invoice: $440 and $660, $100 of tax');

-- ===== The job's own buttons =====================================================================
-- Invoice on a finished job whose earlier payment was never invoiced bills everything left in one
-- final invoice, and both payments read as on it.
select tpg.old_job(:'co', :'erin', :'olly', 800, 0, '[{"kind": "percent", "value": 25, "due": "by_hand"}, {"kind": "rest", "due": "work_done"}]') as skipped \gset
update public.visits set status = 'completed' where job_id = :'skipped';
select public.create_invoice_for_job(:'skipped') as skipped_final \gset
select tpg.check(tpg.rows(:'skipped') = '1:200.00:standard/800.00, 2:600.00:standard/800.00'
  and (select count(*) = 1 from public.invoices where job_id = :'skipped'),
  'the Invoice button with an earlier payment never invoiced bills all that''s left in one final invoice, and both payments are on it');
-- The work is done and its payment invoiced; all that's left is a payment held back to a date. The
-- Invoice button doesn't bill it early (20261113001690_dated_payments_wait_for_their_day.sql).
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0.10, jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 30, 'due', 'by_hand'), jsonb_build_object('kind', 'percent', 'value', 60, 'due', 'work_done'),
    jsonb_build_object('kind', 'rest', 'due', 'date', 'on', (private.company_today(:'co') + 30)::text))) as held \gset
begin;
select tpg.as_user(:'olly');
select public.invoice_installment((select id from public.job_installments where job_id = :'held' and position = 1));
update public.visits set status = 'completed' where job_id = :'held';
select public.create_invoice_for_job(:'held') as held_done \gset
select tpg.check(tpg.rows(:'held') = '1:330.00:progress/330.00, 2:660.00:progress/660.00, 3:110.00:-' and (select status = 'requires_invoicing' from public.jobs where id = :'held'),
  'the Invoice button on a finished job bills the payment for when the work is done, and the job waits for the one held back');
select tpg.check(tpg.error_of(format('select public.create_invoice_for_job(%L)', :'held'))
    = format('22023: Payment 3 of 3 ($110.00) is due on %s and is invoiced by itself that day. To bill it sooner, use Invoice now on the job''s payment schedule', to_char(private.company_today(:'co') + 30, 'Mon FMDD, YYYY')),
  'pressed again, it doesn''t bill the held-back payment before its day, and says when that is');
commit;
update public.job_installments set due_on = private.company_today(:'co') where job_id = :'held' and position = 3;
select public.make_due_installments();
select tpg.check(tpg.rows(:'held') = '1:330.00:progress/330.00, 2:660.00:progress/660.00, 3:110.00:standard/110.00'
  and (select sum(total) = 1100 and sum(tax_amount) = 100 from public.invoices where job_id = :'held') and (select status = 'completed' from public.jobs where id = :'held'),
  'on its day it''s invoiced by itself as the final invoice, $110 with the job''s $100 of tax, and the job closes');
-- The office can still choose to bill a dated payment early, on the payment itself.
select tpg.old_job(:'co', :'erin', :'olly', 500, 0, jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 50, 'due', 'date', 'on', (private.company_today(:'co') + 10)::text),
    jsonb_build_object('kind', 'rest', 'due', 'date', 'on', (private.company_today(:'co') + 40)::text))) as early \gset
begin;
select tpg.as_user(:'olly');
select tpg.check(tpg.error_of(format('select public.create_invoice_for_job(%L)', :'early')) like '22023: Payment 1 of 2 ($250.00) is due on %',
  'a job whose payments are all dated and still to come isn''t invoiced by the button either: the first to come is named');
select public.invoice_installment((select id from public.job_installments where job_id = :'early' and position = 1));
select public.invoice_installment((select id from public.job_installments where job_id = :'early' and position = 2));
commit;
select tpg.check(tpg.rows(:'early') = '1:250.00:progress/250.00, 2:250.00:standard/250.00', 'Invoice now on each bills them early when the office chooses to');

-- A payment that comes to more than the job does (its lines were cut after it was signed) isn't made.
select tpg.old_job(:'co', :'erin', :'olly', 1000, 0.10, '[{"kind": "percent", "value": 60, "due": "by_hand"}, {"kind": "percent", "value": 30, "due": "by_hand"}, {"kind": "rest", "due": "work_done"}]') as cut \gset
update public.job_line_items set unit_price = 500 where job_id = :'cut';
begin;
select tpg.as_user(:'olly');
select tpg.check(tpg.error_of(format('select public.invoice_installment(%L)', (select id from public.job_installments where job_id = :'cut' and position = 1)))
    = '22023: That''s more than what''s left to bill on this job ($550.00)',
  'a payment is held to what the job comes to with its tax ($550 once its work was cut to $500), not to the contract before tax');
commit;

\echo 'All payment schedule shape tests passed.'
