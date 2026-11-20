-- Database tests for 20261113001100_payment_schedules.sql: a quote's payment schedule is checked as
-- it's saved, its deposit follows it, copies and templates carry it, approving keeps each payment's
-- amount, and the job made from it makes each payment's invoice once when its moment comes (a
-- trigger as the work starts, the hourly run for dates), as a draft the office is told about or sent
-- by itself, never twice, made again by hand after a void, each for the amount signed with the last
-- of them the job's final invoice, which takes the others off and carries the tax
-- (20261113001600_scheduled_payments_bill_what_was_signed.sql; payment_shapes_test.sql runs every
-- shape). Autopay charges none of them, and the server before this one approving a quote with a
-- schedule gets the deposit it always got.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tps;
grant usage on schema tps to authenticated, service_role;
create function tps.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tps.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tps.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tps.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- A draft quote for a client with one line of p_price (taxed at p_tax).
create function tps.quote(p_company uuid, p_client uuid, p_title text, p_price numeric, p_tax numeric default 0) returns uuid language plpgsql as $$
declare v_quote uuid;
begin
  insert into public.quotes (company_id, client_id, title, tax_rate) values (p_company, p_client, p_title, p_tax) returning id into v_quote;
  insert into public.quote_line_items (company_id, quote_id, name, unit_price, taxable) values (p_company, v_quote, p_title, p_price, p_tax > 0);
  return v_quote;
end $$;
-- A schedule's payments as "amount due" lines, from the approval kept with a quote.
create function tps.kept(p_quote uuid) returns text language sql stable as $$
  select string_agg((e.value ->> 'amount') || ' ' || (e.value ->> 'due'), ', ' order by e.i)
  from public.quotes q cross join lateral jsonb_array_elements(q.approval -> 'payment_schedule') with ordinality e (value, i)
  where q.id = p_quote
$$;
-- A job's payments as "position:amount:due:invoice kind/total/status" (or "-"), in order.
create function tps.rows(p_job uuid) returns text language sql stable as $$
  select string_agg(s.position || ':' || s.amount || ':' || s.due || ':' || coalesce(i.kind || '/' || i.total || '/' || i.status, '-'), ', ' order by s.position)
  from public.job_installments s left join public.invoices i on i.id = s.invoice_id
  where s.job_id = p_job
$$;
create function tps.row_id(p_job uuid, p_position integer) returns uuid language sql stable as $$
  select id from public.job_installments where job_id = p_job and position = p_position
$$;
-- The bell notifications about invoices, as "who: title | body" lines.
create function tps.told(p_like text) returns text language sql stable as $$
  select string_agg(u.email || ': ' || n.title || ' | ' || coalesce(n.body, ''), E'\n' order by u.email, n.created_at)
  from public.notifications n join auth.users u on u.id = n.user_id
  where n.title like p_like
$$;
grant execute on all functions in schema tps to authenticated, service_role;

\set pat 'a5c00000-0000-0000-0000-000000000001'
\set olly 'a5c00000-0000-0000-0000-000000000002'
\set cruz 'a5c00000-0000-0000-0000-000000000003'

-- ===== The sums ==================================================================================
select tps.check(private.schedule_amounts('[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "percent", "value": 30, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]', 1000)
    = '[{"due": "approval", "kind": "percent", "value": 30, "amount": 300.00}, {"due": "work_starts", "kind": "percent", "value": 30, "amount": 300.00}, {"due": "work_done", "kind": "rest", "amount": 400.00}]',
  'percents are of the total, and the rest is what''s left');
select tps.check((select string_agg(e ->> 'amount', ' ') from jsonb_array_elements(private.schedule_amounts(
    '[{"kind": "percent", "value": 33.33, "due": "approval"}, {"kind": "percent", "value": 33.33, "due": "by_hand"}, {"kind": "percent", "value": 33.34, "due": "work_done"}]', 100.01)) e)
    = '33.33 33.33 33.35'
  and private.schedule_problem('[{"kind": "percent", "value": 33.33, "due": "approval"}, {"kind": "percent", "value": 33.33, "due": "by_hand"}, {"kind": "percent", "value": 33.34, "due": "work_done"}]', 100.01) is null,
  'percents that make 100 fit, and the last payment takes the cent of rounding');
select tps.check((select string_agg(e ->> 'amount', ' ') from jsonb_array_elements(private.schedule_amounts(
    '[{"kind": "amount", "value": 800, "due": "approval"}, {"kind": "amount", "value": 500, "due": "by_hand"}, {"kind": "amount", "value": 100, "due": "work_done"}]', 1000)) e) = '800.00 200.00 0.00',
  'amounts that no longer fit are never more than what''s left, and still come to the total');
select tps.check(private.schedule_problem('[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "amount", "value": 600, "due": "work_done"}]', 1000) = 'The payments come to $100.00 less than the total.'
  and private.schedule_problem('[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "amount", "value": 800, "due": "work_done"}]', 1000) = 'The payments come to $100.00 more than the total.'
  and private.schedule_problem('[{"kind": "amount", "value": 1000, "due": "approval"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'The payments before the last come to the whole total, so nothing is left for the rest.'
  and private.schedule_problem('[{"kind": "rest", "due": "approval"}, {"kind": "amount", "value": 5, "due": "work_done"}]', 1000) = 'Only the last payment can be the rest.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "approval"}, {"kind": "percent", "value": 50, "due": "approval"}]', 1000) = 'Only one payment can be due when the quote is approved.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "work_done"}, {"kind": "percent", "value": 50, "due": "work_done"}]', 1000) = 'Only one payment can be due when the work is done.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date"}, {"kind": "rest", "due": "work_done"}]', 1000) is null
  and private.schedule_date_problem('[{"kind": "percent", "value": 50, "due": "date"}, {"kind": "rest", "due": "work_done"}]', null) = 'Payment 1 needs its date.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "on": "2026-02-30"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs its date.'
  and private.schedule_problem('[{"kind": "percent", "value": 0, "due": "approval"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs a percent above 0, up to 100.'
  and private.schedule_problem('[{"kind": "amount", "value": "100", "due": "approval"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs an amount.'
  and private.schedule_problem('[{"kind": "amount", "value": 100, "due": "soon"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs to say when it''s due.'
  and private.schedule_problem((select jsonb_agg(jsonb_build_object('kind', 'amount', 'value', 1, 'due', 'by_hand')) from generate_series(1, 13)), 13) = 'A payment schedule has 12 payments at most.'
  and private.schedule_problem('[{"kind": "percent", "value": 25, "due": "approval"}, {"kind": "amount", "value": 750, "due": "date", "on": "2027-01-04"}]', 1000) is null,
  'what''s wrong is said in the editor''s words (core scheduleProblem says the same)');

-- ===== Saving one on a quote =====================================================================
begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@pine-patios.test', '{"full_name": "Pat Pine"}'),
  (:'olly', 'olly@pine-patios.test', '{"full_name": "Olly Office"}'),
  (:'cruz', 'cruz@pine-patios.test', '{"full_name": "Cruz Crew"}');
set local role authenticated;
select tps.as_user(:'pat');
select public.create_company('Pine Patios', 'general', 'America/Chicago') as co \gset
reset role;
select tps.as_nobody();
insert into public.memberships (company_id, user_id, role) values (:'co', :'olly', 'office'), (:'co', :'cruz', 'field_crew');
insert into public.clients (company_id, display_name, email) values (:'co', 'Erin Estes', 'erin@example.test') returning id as erin \gset

set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Patio', 1000) as patio \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "amount", "value": 300, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'patio';
select tps.check((select deposit_amount = 300 and deposit_percent = 30 from public.quotes where id = :'patio'),
  'the payment due at approval is the deposit, as a percent when it''s one, so older apps and servers see it');
select tps.check(tps.error_of(format($q$update public.quotes set payment_schedule = '[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "amount", "value": 600, "due": "work_done"}]' where id = %L$q$, :'patio'))
    = '22023: The payments come to $100.00 less than the total.',
  'a schedule that doesn''t come to the total isn''t saved, and says by how much');
update public.quote_line_items set unit_price = 1200 where quote_id = :'patio';
select tps.check((select total = 1200 and deposit_amount = 360 and payment_schedule -> 1 ->> 'value' = '300' from public.quotes where id = :'patio'),
  'a new total moves a percent and leaves the amounts as they were (the editor flags any that no longer fit)');
update public.quotes set payment_schedule = '[{"kind": "amount", "value": 250, "due": "approval"}, {"kind": "rest", "due": "work_done"}]' where id = :'patio';
select tps.check((select deposit_amount = 250 and deposit_percent is null from public.quotes where id = :'patio'), 'an amount due at approval is the deposit as an amount');
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'patio';
select tps.check((select deposit_amount = 0 and deposit_percent is null from public.quotes where id = :'patio'), 'with nothing due at approval there''s no deposit');
update public.quotes set deposit_amount = 500 where id = :'patio';
select tps.check((select deposit_amount = 0 from public.quotes where id = :'patio'), 'and an older app setting a deposit doesn''t take it from the schedule');
update public.quotes set payment_schedule = '[]' where id = :'patio';
select tps.check((select payment_schedule is null from public.quotes where id = :'patio'), 'an empty schedule is no schedule');
select tps.check(tps.error_of(format($q$update public.quotes set recurrence_rule = 'FREQ=WEEKLY', payment_schedule = '[{"kind": "rest", "due": "work_done"}]' where id = %L$q$, :'patio'))
    = '22023: Repeating work is billed by the visit or the month, so it has no payment schedule.',
  'repeating work has no schedule');

-- Copies and templates carry it, but never a day: each dated payment's day is to set again, while
-- "so many days after they approve" carries as it is (20261113001640_schedule_dates.sql).
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 20, "due": "approval"}, {"kind": "percent", "value": 30, "due": "date", "on": "2027-03-01"}, {"kind": "percent", "value": 10, "due": "date", "after": 30}, {"kind": "rest", "due": "work_done"}]' where id = :'patio';
select public.duplicate_quote(:'patio') as copy \gset
select public.duplicate_quote(:'patio', 'Patio template') as template \gset
select public.duplicate_quote(:'template', null, :'erin') as from_template \gset
select tps.check((select count(*) = 3 and bool_and(deposit_amount = 240) and bool_and(payment_schedule =
      '[{"kind": "percent", "value": 20, "due": "approval"}, {"kind": "percent", "value": 30, "due": "date"}, {"kind": "percent", "value": 10, "due": "date", "after": 30}, {"kind": "rest", "due": "work_done"}]')
                    from public.quotes where id in (:'copy', :'template', :'from_template')),
  'a copy, a template and a quote made from the template carry the schedule and its deposit, with the dated payment''s day to set again');
select tps.check((select payment_schedule -> 1 ->> 'on' = '2027-03-01' from public.quotes where id = :'patio'), 'the quote copied keeps its own day');
select tps.check(public.quote_send_problem(:'copy') = 'Payment 2 needs its date.' and public.quote_send_problem(:'patio') is null,
  'the server is told a copy can''t be sent until that day is set');
select tps.check(tps.error_of(format($q$update public.quotes set status = 'sent', sent_at = now() where id = %L$q$, :'copy')) = '22023: Payment 2 needs its date.'
  and tps.error_of(format($q$update public.quotes set status = 'approved', approved_at = now() where id = %L$q$, :'copy')) like '22023:%customer signs this exact version%',
  'and the copy can''t be marked sent without it (nor approved by the office at all: only the customer''s signature accepts it)');
-- A day already gone can't be sent; set to one still to come, it can.
update public.quotes set payment_schedule = jsonb_set(payment_schedule, '{1,on}', to_jsonb((private.company_today(:'co') - 1)::text)) where id = :'copy';
select tps.check(tps.error_of(format($q$update public.quotes set status = 'sent', sent_at = now() where id = %L$q$, :'copy'))
    = format('22023: Payment 2 is due on %s, which has already passed. Give it a new date.', to_char(private.company_today(:'co') - 1, 'Mon FMDD, YYYY'))
  and public.quote_send_problem(:'copy') = format('Payment 2 is due on %s, which has already passed. Give it a new date.', to_char(private.company_today(:'co') - 1, 'Mon FMDD, YYYY')),
  'a quote whose dated payment''s day has passed can''t be sent, and says which');
select tps.check(private.schedule_date_problem(jsonb_build_array(jsonb_build_object('kind', 'rest', 'due', 'date', 'on', private.company_today(:'co')::text)), private.company_today(:'co')) is null,
  'a day that is today hasn''t passed');
update public.quotes set payment_schedule = jsonb_set(payment_schedule, '{1,on}', to_jsonb((private.company_today(:'co') + 5)::text)), status = 'sent', sent_at = now() where id = :'copy';
select tps.check((select status = 'sent' from public.quotes where id = :'copy'), 'with a day still to come, it''s sent');
select tps.check(tps.error_of(format($q$update public.quotes set payment_schedule = jsonb_set(payment_schedule, '{1,on}', '"2020-01-01"') where id = %L$q$, :'copy')) like '22023: Payment 2 is due on Jan 1, 2020, which has already passed.%',
  'and a quote that''s with the client can''t be given a day already gone');
-- Approving gives "30 days after they approve" its day, from today where the company is.
select planet_test.sign(:'copy');
select tps.check((select approval -> 'payment_schedule' -> 2 ->> 'on' = (private.company_today(:'co') + 30)::text and approval -> 'payment_schedule' -> 2 ->> 'after' = '30'
                    and approval -> 'payment_schedule' -> 1 ->> 'on' = (private.company_today(:'co') + 5)::text
                    from public.quotes where id = :'copy'),
  'approving works out the day of a payment due 30 days after, and keeps it with the approval');
select public.convert_quote_to_job(planet_test.sign(:'copy')) as copy_job \gset
select tps.check((select due = 'date' and due_on = private.company_today(:'co') + 30 from public.job_installments where job_id = :'copy_job' and position = 3),
  'so the job''s payment has its date');
select tps.check(private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "after": 0}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs a number of days, 1 to 365.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "after": 366}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs a number of days, 1 to 365.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "after": 2.5}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs a number of days, 1 to 365.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "after": "30"}, {"kind": "rest", "due": "work_done"}]', 1000) = 'Payment 1 needs a number of days, 1 to 365.'
  and private.schedule_problem('[{"kind": "percent", "value": 50, "due": "date", "after": 365}, {"kind": "rest", "due": "work_done"}]', 1000) is null,
  'days after approval are a whole number from 1 to 365');
commit;

-- ===== Approved by the server before this one, and made a job ===================================
-- Five payments of $200 on a $1,000 patio: at approval, on a date, as the work starts, by hand, and the rest when it's done.
begin;
set local role authenticated;
select tps.as_user(:'olly');
select id as co from public.companies where name = 'Pine Patios' \gset
select id as erin from public.clients where display_name = 'Erin Estes' \gset
select tps.quote(:'co', :'erin', 'Back patio', 1000) as back \gset
update public.quotes set payment_schedule = jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 20, 'due', 'approval'),
    jsonb_build_object('kind', 'amount', 'value', 200, 'due', 'date', 'on', (private.company_today(:'co') + 3)::text),
    jsonb_build_object('kind', 'percent', 'value', 20, 'due', 'work_starts'),
    jsonb_build_object('kind', 'amount', 'value', 200, 'due', 'by_hand'),
    jsonb_build_object('kind', 'rest', 'due', 'work_done')),
  status = 'sent', sent_at = now()
 where id = :'back';
commit;

set role service_role;
-- What the release before this one does: approve_hub_quote, then hub_deposit_invoice with two arguments.
select tps.check(public.approve_hub_quote(:'co', :'back', null, planet_test.approval(:'back', '{"name": "Erin Estes"}')), 'Erin approves it in the Client Hub');
select public.hub_deposit_invoice(:'co', :'back') as back_deposit \gset
reset role;
select tps.check(tps.kept(:'back') = '200.00 approval, 200.00 date, 200.00 work_starts, 200.00 by_hand, 200.00 work_done',
  'approving keeps each payment''s amount with the approval');
select tps.check((select kind = 'deposit' and total = 200 and status = 'sent' from public.invoices where id = :'back_deposit'),
  'the older server''s deposit invoice is the payment due at approval');
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.check(tps.error_of(format($q$update public.quotes set payment_schedule = '[{"kind": "rest", "due": "work_done"}]' where id = %L$q$, :'back'))
    = '22023: This quote was approved, so its payment schedule stays as it was signed.', 'a signed schedule stays as it was signed');
select public.convert_quote_to_job(planet_test.sign(:'back')) as job \gset
commit;
select tps.check(tps.rows(:'job') = '1:200.00:approval:deposit/200.00/sent, 2:200.00:date:-, 3:200.00:work_starts:-, 4:200.00:by_hand:-, 5:200.00:work_done:-',
  'the job gets the payments, the deposit invoice the first of them');
select tps.check((select job_id = :'job' from public.invoices where id = :'back_deposit'), 'and the deposit invoice joins the job as it always did');

-- The work starts: Cruz taps Start on the first visit.
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Dig out', private.company_today(:'co')) returning id as v1 \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Pour', private.company_today(:'co') + 1) returning id as v2 \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'v1', :'cruz'), (:'co', :'v2', :'cruz');
begin;
set local role authenticated;
select tps.as_user(:'cruz');
update public.visits set status = 'in_progress' where id = :'v1';
commit;
select tps.check(tps.rows(:'job') like '1:200.00:approval:deposit/200.00/sent, 2:200.00:date:-, 3:200.00:work_starts:progress/200.00/draft, 4:%',
  'as the first visit goes in progress, the payment due then is a draft progress invoice');
select id as starts_invoice, number as starts_number from public.invoices where id = (select invoice_id from public.job_installments where id = tps.row_id(:'job', 3)) \gset
select tps.check((select subject = 'Payment 3 of 5: Back patio' from public.invoices where id = :'starts_invoice'), 'named for the payment it is');
select tps.check(tps.told('Payment 3 of 5 for job #%') = (select format(
    E'olly@pine-patios.test: Payment 3 of 5 for job #%1$s is ready to send | Invoice #%2$s for $200.00 to Erin Estes is in Drafts.\n'
    'pat@pine-patios.test: Payment 3 of 5 for job #%1$s is ready to send | Invoice #%2$s for $200.00 to Erin Estes is in Drafts.',
    (select number from public.jobs where id = :'job'), :'starts_number')),
  'the owner and the office are told it''s ready to send; the crew isn''t');
begin;
set local role authenticated;
select tps.as_user(:'cruz');
update public.visits set status = 'in_progress' where id = :'v2';
commit;
select tps.check((select count(*) = 1 from public.invoices where job_id = :'job' and kind = 'progress'), 'another visit starting makes nothing more');

-- The date: not yet, then the hourly run on the day.
set role service_role;
select tps.check(public.make_due_installments() = 0, 'before its date, the hourly run makes nothing');
reset role;
update public.job_installments set due_on = private.company_today(:'co') where id = tps.row_id(:'job', 2);
set role service_role;
select tps.check(public.make_due_installments() = 1, 'on its date (where the company is) it''s made');
select tps.check(public.make_due_installments() = 0, 'and only once');
reset role;
select invoice_id as date_invoice from public.job_installments where id = tps.row_id(:'job', 2) \gset
select tps.check((select kind = 'progress' and total = 200 and status = 'draft' from public.invoices where id = :'date_invoice'), 'a draft progress invoice for its amount');

-- Voided: never made again by itself; Invoice now makes it again.
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.invoices set status = 'void' where id = :'date_invoice';
commit;
set role service_role;
select tps.check(public.make_due_installments() = 0, 'a payment whose invoice was voided isn''t made again by itself');
reset role;
begin;
set local role authenticated;
select tps.as_user(:'cruz');
select tps.check(tps.error_of(format('select public.invoice_installment(%L)', tps.row_id(:'job', 2))) = 'P0002: Payment not found'
  and (select count(*) = 0 from public.job_installments where job_id = :'job'), 'the crew neither sees the payments nor invoices one');
select tps.as_user(:'olly');
select public.invoice_installment(tps.row_id(:'job', 2)) as date_again \gset
select tps.check(:'date_again' <> :'date_invoice' and (select total = 200 and status = 'draft' from public.invoices where id = :'date_again'),
  'the office makes it again by hand');
select tps.check(tps.error_of(format('select public.invoice_installment(%L)', tps.row_id(:'job', 2))) = (select format('22023: Payment 2 of 5 is on invoice #%s already', number) from public.invoices where id = :'date_again'),
  'but never twice');
select public.invoice_installment(tps.row_id(:'job', 4)) as by_hand \gset
select tps.check((select kind = 'progress' and total = 200 and tax_amount = 0 and subject = 'Payment 4 of 5: Back patio' from public.invoices where id = :'by_hand')
  and (select name = 'Payment 4 of 5 for Back patio' and description = 'Part of the $1,000.00 total' and not taxable from public.invoice_line_items where invoice_id = :'by_hand'),
  'a payment before the last is an invoice on account for its amount, named for it');
-- The last payment without an invoice is the job's final invoice: it takes each of the others off.
select public.create_invoice_for_job(:'job') as final \gset
commit;
select tps.check((select total = 200 from public.invoices where id = :'final')
  and (select string_agg(name, ', ' order by sort) from public.invoice_line_items where invoice_id = :'final' and unit_price < 0) like 'Less payment 1 of 5 (invoice #%), Less payment 3 of 5 (invoice #%), Less payment 2 of 5 (invoice #%), Less payment 4 of 5 (invoice #%)',
  'the final invoice takes off the four payments billed, by name and in the order of their invoices (not the voided one), and bills the last $200');
select tps.check(tps.rows(:'job') = '1:200.00:approval:deposit/200.00/sent, 2:200.00:date:progress/200.00/draft, 3:200.00:work_starts:progress/200.00/draft, 4:200.00:by_hand:progress/200.00/draft, 5:200.00:work_done:standard/200.00/draft',
  'the last payment is the final invoice');
select tps.check((select sum(total) = 1000 from public.invoices where job_id = :'job' and status <> 'void'), 'and together they come to the quote''s total');
select tps.check((select count(*) = 0 from public.notifications where title like 'Payment 4 of 5%')
  and (select count(*) = 2 from public.notifications where title like 'Payment 2 of 5%'),
  'nobody is told about a payment the office made by hand, only about the one made on its date');

-- ===== Tax, sending by itself, the final invoice first, and autopay ==============================
begin;
set local role authenticated;
select tps.as_user(:'pat');
select id as co from public.companies where name = 'Pine Patios' \gset
select id as erin from public.clients where display_name = 'Erin Estes' \gset
select public.merge_company_settings(:'co', '{"payment_schedule": {"send": true}}');
-- $1,000 of taxed work at 10%: $1,100. A third when they approve, a third as the work starts, the rest when it's done.
select tps.quote(:'co', :'erin', 'Pergola', 1000, 0.10) as pergola \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 30, "due": "approval"}, {"kind": "percent", "value": 30, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]'
 where id = :'pergola';
select public.convert_quote_to_job(planet_test.sign(:'pergola')) as pjob \gset
-- The office approved it, so there's no deposit invoice until they make it (as before); then it's the first payment.
select public.create_invoice_for_job(:'pjob', 'deposit') as pdeposit \gset
commit;
select tps.check(tps.kept(:'pergola') = '330.00 approval, 330.00 work_starts, 440.00 work_done', 'a schedule on a taxed quote is of its total, tax and all');
select tps.check(tps.rows(:'pjob') = '1:330.00:approval:deposit/330.00/draft, 2:330.00:work_starts:-, 3:440.00:work_done:-',
  'the office''s Deposit button makes the payment due at approval, untaxed as deposits are');
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'pjob', 'Build', private.company_today(:'co'), 'in_progress');
select invoice_id as pstart from public.job_installments where id = tps.row_id(:'pjob', 2) \gset
select tps.check((select subtotal = 330 and tax_amount = 0 and total = 330 from public.invoices where id = :'pstart')
  and (select description = 'Part of the $1,100.00 total, tax included' from public.invoice_line_items where invoice_id = :'pstart'),
  'a payment before the last bills its amount, tax included, with no tax of its own, and says so');
select tps.check((select send_state = 'waiting' from public.job_installments where id = tps.row_id(:'pjob', 2))
  and tps.told('Payment 2 of 3 for job #%') is null, 'with "send by themselves" on it waits for the server to send it, and nobody is told it''s ready');
-- A payment made as the work starts waits half an hour (see further down); this one has.
update public.job_installments set made_at = now() - interval '31 minutes' where id = tps.row_id(:'pjob', 2);
set role service_role;
select tps.check((select count(*) = 1 and bool_and(invoice_id = :'pstart') from public.claim_installment_sends(10)), 'the server claims it to send');
select tps.check((select count(*) = 0 from public.claim_installment_sends(10)), 'once');
select public.installment_sent(tps.row_id(:'pjob', 2), false, 'Add a valid email address for this client first.');
reset role;
select tps.check(tps.told('Payment 2 of 3 for job #% wasn''t sent') = (select format(
    E'olly@pine-patios.test: Payment 2 of 3 for job #%1$s wasn''t sent | Add a valid email address for this client first. It''s in Drafts: send it from the invoice.\n'
    'pat@pine-patios.test: Payment 2 of 3 for job #%1$s wasn''t sent | Add a valid email address for this client first. It''s in Drafts: send it from the invoice.',
    (select number from public.jobs where id = :'pjob'))),
  'a send that didn''t go tells the owner and the office why, and that it''s in Drafts');
begin;
set local role authenticated;
select tps.as_user(:'olly');
select public.create_invoice_for_job(:'pjob') as pfinal \gset
commit;
select tps.check((select subtotal = 340 and tax_amount = 100 and total = 440 from public.invoices where id = :'pfinal')
  and (select sum(total) = 1100 and sum(tax_amount) = 100 from public.invoices where job_id = :'pjob'),
  'the final invoice takes both payments off and carries the job''s tax: the rest is $440, and the job''s tax is $100');

-- A job whose final invoice comes first: the payments still to come are on it.
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Fire pit', 500) as pit \gset
update public.quotes set payment_schedule = jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 50, 'due', 'date', 'on', (private.company_today(:'co') - 1)::text),
    jsonb_build_object('kind', 'rest', 'due', 'work_done'))
 where id = :'pit';
select public.convert_quote_to_job(planet_test.sign(:'pit')) as pitjob \gset
select public.create_invoice_for_job(:'pitjob') as pitfinal \gset
commit;
set role service_role;
select tps.check(public.make_due_installments() = 0, 'a date payment after the final invoice isn''t made');
reset role;
select tps.check((select count(*) = 2 and bool_and(invoice_id = :'pitfinal' and problem is null) from public.job_installments where job_id = :'pitjob')
  and (select total = 500 from public.invoices where id = :'pitfinal'), 'the final invoice billed it, so both payments are on that invoice');
-- Voiding that final invoice frees both payments: nothing is written on them, the one whose date has
-- passed isn't made by itself, and each is invoiced again by hand for what was signed.
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.invoices set status = 'void' where id = :'pitfinal';
commit;
set role service_role;
select tps.check(public.make_due_installments() = 0, 'after the final invoice is voided, a payment it billed isn''t made again by itself');
reset role;
begin;
set local role authenticated;
select tps.as_user(:'olly');
select public.invoice_installment(tps.row_id(:'pitjob', 1)) as pit_one \gset
select public.invoice_installment(tps.row_id(:'pitjob', 2)) as pit_two \gset
commit;
select tps.check(tps.rows(:'pitjob') = '1:250.00:date:progress/250.00/draft, 2:250.00:work_done:standard/250.00/draft'
  and (select count(*) = 0 from public.job_installments where job_id = :'pitjob' and problem is not null),
  'and each is invoiced again by hand, the payment for when the work is done included: $250 on account, then the final invoice for $250');

-- Autopay is as it was: it charges the invoices it makes itself (the final one, as the work is marked
-- complete), never a progress invoice, so a payment's invoice queues no charge.
insert into public.integrations (company_id, provider, status, settings) values (:'co', 'stripe', 'connected', '{"autopay": true, "refunds": true}');
begin;
set local role authenticated;
select tps.as_user(:'pat');
select public.autopay_set_settings(:'co', jsonb_build_object('enabled', true, 'terms', 'We charge the card on file when the work is done. You''ll get a receipt each time.',
  'timing', 'end_of_day', 'days', null, 'max_amount', null, 'receipts', true, 'jobs_default', true, 'card_required', false));
commit;
insert into public.clients (company_id, display_name, email) values (:'co', 'Ava Autopay', 'ava@example.test') returning id as ava \gset
select public.autopay_save_payment_method(:'co', :'ava', '{"stripe_payment_method_id": "pm_ava", "stripe_customer_id": "cus_ava", "stripe_account": "acct_pine", "livemode": false,
  "type": "card", "brand": "visa", "last4": "4242", "exp_month": 8, "exp_year": 2030, "status": "active", "source": "hub", "make_default": true}') as ava_card \gset
select public.autopay_record_authorization(:'co', :'ava', :'ava_card', 'hub', private.autopay_terms_version(:'co'), '203.0.113.7', 'Test browser', 'client', 'client');
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'ava', 'Walkway', 600) as walk \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'walk';
select planet_test.sign(:'walk');
select public.convert_quote_to_job(planet_test.sign(:'walk')) as wjob \gset
update public.jobs set autopay = true where id = :'wjob';
commit;
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'wjob', 'Walkway', private.company_today(:'co'), 'in_progress');
select tps.check((select autopay from public.jobs where id = :'wjob') and tps.rows(:'wjob') = '1:300.00:work_starts:progress/300.00/draft, 2:300.00:work_done:-'
  and (select count(*) = 0 from public.autopay_charges where job_id = :'wjob'),
  'on a job on autopay, the payment due as the work starts is a draft, and no card charge is queued for it');
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.jobs set status = 'requires_invoicing' where id = :'wjob';
commit;
select tps.check((select count(*) = 1 and bool_and(bill = 'standard' and invoice_id is null and status = 'waiting') from public.autopay_charges where job_id = :'wjob'),
  'marking the work complete queues the final invoice''s charge, as it always did');
select tps.check((select count(*) = 0 from public.autopay_charges a join public.job_installments s on s.invoice_id = a.invoice_id where s.due <> 'work_done'),
  'no payment''s own invoice is charged by autopay');

-- A payment that can't be made (more than what's left) is kept with why, and the office is told once.
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Steps', 400) as steps \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "by_hand"}, {"kind": "rest", "due": "work_starts"}]' where id = :'steps';
select planet_test.sign(:'steps');
select public.convert_quote_to_job(planet_test.sign(:'steps')) as sjob \gset
select public.create_invoice_for_job(:'sjob', 'progress', 400) as sall \gset
commit;
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'sjob', 'Steps', private.company_today(:'co'), 'completed');
select tps.check((select invoice_id is null and made_at is not null and problem = 'That''s more than what''s left to bill on this job ($0.00)' from public.job_installments where id = tps.row_id(:'sjob', 2))
  and (select count(*) = 2 from public.notifications where title = format('Payment 2 of 2 for job #%s couldn''t be invoiced', (select number from public.jobs where id = :'sjob'))),
  'a payment with nothing left to bill is noted, and the owner and office are told');
set role service_role;
select tps.check(public.make_due_installments() = 0, 'and it isn''t tried again by itself');
reset role;

-- ===== One payment that can't be made doesn't stop the others ====================================
-- (20261113001610_one_payment_doesnt_stop_the_others.sql) Two jobs with a payment due today. The
-- first one's invoice fails in a way the database didn't expect (a stand-in guard here).
create function tps.locked_books() returns trigger language plpgsql as $$
begin
  raise exception 'The books are locked';
end $$;
create trigger tps_locked_books before insert on public.invoices
  for each row when (new.subject like '%Cursed deck%') execute function tps.locked_books();
begin;
set local role authenticated;
select tps.as_user(:'pat');
select public.merge_company_settings(:'co', '{"payment_schedule": {"send": false}}');
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Cursed deck', 900) as cursed \gset
update public.quotes set payment_schedule = jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 50, 'due', 'date', 'on', private.company_today(:'co')::text),
    jsonb_build_object('kind', 'rest', 'due', 'work_done'))
 where id = :'cursed';
select public.convert_quote_to_job(planet_test.sign(:'cursed')) as cursed_job \gset
select tps.quote(:'co', :'erin', 'Good deck', 700) as good \gset
update public.quotes set payment_schedule = jsonb_build_array(
    jsonb_build_object('kind', 'percent', 'value', 50, 'due', 'date', 'on', private.company_today(:'co')::text),
    jsonb_build_object('kind', 'rest', 'due', 'work_done'))
 where id = :'good';
select public.convert_quote_to_job(planet_test.sign(:'good')) as good_job \gset
commit;
set role service_role;
select tps.check(public.make_due_installments() = 1, 'with one payment that can''t be made, the hourly run still makes the other');
reset role;
select tps.check(tps.rows(:'good_job') = '1:350.00:date:progress/350.00/draft, 2:350.00:work_done:-', 'the good job''s payment is a draft invoice');
select tps.check((select invoice_id is null and made_at is null and attempts = 1 and problem = 'The books are locked' from public.job_installments where id = tps.row_id(:'cursed_job', 1))
  and tps.told('Payment 1 of 2 for job #' || (select number from public.jobs where id = :'cursed_job') || ' couldn''t%') is null,
  'the one that failed keeps its reason, to try again, and nobody is told yet');
set role service_role;
select public.make_due_installments() as made \gset
select tps.check(:'made' = 0 and (select attempts = 2 and made_at is null from public.job_installments where id = tps.row_id(:'cursed_job', 1)),
  'the next hour it''s tried again');
select public.make_due_installments() as made \gset
select tps.check(:'made' = 0 and (select attempts = 3 and made_at is not null and problem = 'The books are locked' from public.job_installments where id = tps.row_id(:'cursed_job', 1)),
  'and after the third try it''s left for the office');
select public.make_due_installments() as made \gset
select tps.check(:'made' = 0 and (select attempts = 3 from public.job_installments where id = tps.row_id(:'cursed_job', 1)), 'never tried again by itself');
reset role;
select tps.check(tps.told('Payment 1 of 2 for job #' || (select number from public.jobs where id = :'cursed_job') || ' couldn''t%') = (select format(
    E'olly@pine-patios.test: Payment 1 of 2 for job #%1$s couldn''t be invoiced | The books are locked. It was tried three times and won''t be tried again by itself. Invoice it from the job when it''s sorted out.\n'
    'pat@pine-patios.test: Payment 1 of 2 for job #%1$s couldn''t be invoiced | The books are locked. It was tried three times and won''t be tried again by itself. Invoice it from the job when it''s sorted out.',
    (select number from public.jobs where id = :'cursed_job'))),
  'the owner and the office are told once, with the reason');
drop trigger tps_locked_books on public.invoices;
begin;
set local role authenticated;
select tps.as_user(:'olly');
select public.invoice_installment(tps.row_id(:'cursed_job', 1)) as cursed_invoice \gset
commit;
select tps.check((select problem is null and invoice_id = :'cursed_invoice' from public.job_installments where id = tps.row_id(:'cursed_job', 1)),
  'once it''s sorted out, the office invoices it from the job and the reason is gone');

-- ===== Sent by themselves: a payment made as a visit starts waits, and can be called off =========
-- (20261113001620_started_payments_wait_before_sending.sql)
begin;
set local role authenticated;
select tps.as_user(:'pat');
select public.merge_company_settings(:'co', '{"payment_schedule": {"send": true}}');
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Gazebo', 800) as gazebo \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'gazebo';
select planet_test.sign(:'gazebo');
select public.convert_quote_to_job(planet_test.sign(:'gazebo')) as gjob \gset
commit;
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'gjob', 'Gazebo', private.company_today(:'co')) returning id as gv \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'gv', :'cruz');
begin;
set local role authenticated;
select tps.as_user(:'cruz');
update public.visits set status = 'in_progress' where id = :'gv';
commit;
select tps.check(tps.rows(:'gjob') = '1:400.00:work_starts:progress/400.00/draft, 2:400.00:work_done:-'
  and (select send_state = 'waiting' from public.job_installments where id = tps.row_id(:'gjob', 1)), 'Cruz taps Start: the payment is a draft waiting to be sent');
set role service_role;
select tps.check((select count(*) = 0 from public.claim_installment_sends(10)), 'for its first half hour the server doesn''t send it');
reset role;
-- It was the wrong visit: the office puts it back.
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.visits set status = 'scheduled' where id = :'gv';
commit;
select tps.check(tps.rows(:'gjob') = '1:400.00:work_starts:-, 2:400.00:work_done:-'
  and (select made_at is null and send_state is null from public.job_installments where id = tps.row_id(:'gjob', 1))
  and (select count(*) = 0 from public.invoices where job_id = :'gjob'),
  'the visit goes back to scheduled: the untouched draft is gone and the payment is as it was before the tap');
-- The work really starts. This time the office changes the draft before the visit is put back again.
begin;
set local role authenticated;
select tps.as_user(:'cruz');
update public.visits set status = 'in_progress' where id = :'gv';
commit;
select invoice_id as gdraft from public.job_installments where id = tps.row_id(:'gjob', 1) \gset
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.invoices set due_on = due_on + 7 where id = :'gdraft';
update public.visits set status = 'scheduled' where id = :'gv';
commit;
select tps.check((select send_state is null and invoice_id = :'gdraft' and made_at is not null from public.job_installments where id = tps.row_id(:'gjob', 1))
  and (select status = 'draft' from public.invoices where id = :'gdraft')
  and tps.told('Payment 1 of 2 for job #' || (select number from public.jobs where id = :'gjob') || ' wasn''t sent') like
      'olly@pine-patios.test: Payment 1 of 2 for job #% wasn''t sent | The visit that started the work was put back, and its invoice had been changed, so it''s in Drafts for you to send or delete.%',
  'a draft the office has changed stays theirs: not sent by itself, and they''re told');
set role service_role;
select tps.check((select count(*) = 0 from public.claim_installment_sends(10)), 'and the server never claims it');
reset role;

-- Half an hour on, a started payment is sent; one the office already sent by hand never is.
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Arbor', 600) as arbor \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'arbor';
select planet_test.sign(:'arbor');
select public.convert_quote_to_job(planet_test.sign(:'arbor')) as ajob \gset
select tps.quote(:'co', :'erin', 'Trellis', 500) as trellis \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'trellis';
select planet_test.sign(:'trellis');
select public.convert_quote_to_job(planet_test.sign(:'trellis')) as tjob \gset
commit;
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'ajob', 'Arbor', private.company_today(:'co'), 'in_progress'), (:'co', :'tjob', 'Trellis', private.company_today(:'co'), 'in_progress');
begin;
set local role authenticated;
select tps.as_user(:'olly');
update public.invoices set status = 'sent' where id = (select invoice_id from public.job_installments where id = tps.row_id(:'tjob', 1));
commit;
update public.job_installments set made_at = now() - interval '31 minutes' where job_id in (:'ajob', :'tjob') and position = 1;
set role service_role;
select tps.check((select count(*) = 1 and bool_and(id = tps.row_id(:'ajob', 1)) from public.claim_installment_sends(10)),
  'after half an hour the server claims the started payment to send, and not the one the office sent by hand');
reset role;
select tps.check((select send_state is null from public.job_installments where id = tps.row_id(:'tjob', 1)), 'the one sent by hand is no longer waiting');
-- The office sends the claimed one by hand in the moment before the server does: the server checks, and calls its own send off.
set role service_role;
select public.installment_send_called_off(tps.row_id(:'ajob', 1));
reset role;
select tps.check((select send_state is null from public.job_installments where id = tps.row_id(:'ajob', 1))
  and tps.told('Payment 1 of 2 for job #' || (select number from public.jobs where id = :'ajob') || '%') is null,
  'a send the server calls off is over, with nobody told');
select tps.check(not has_function_privilege('authenticated', 'public.installment_send_called_off(uuid)', 'execute'), 'only the server calls a send off');

-- ===== A job with payments to come isn't switched to visit by visit silently =====================
-- (20261113001630_schedule_or_visit_by_visit.sql)
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Fence', 900) as fence \gset
update public.quotes set payment_schedule = '[{"kind": "amount", "value": 300, "due": "approval"}, {"kind": "amount", "value": 300, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'fence';
select planet_test.sign(:'fence');
select public.convert_quote_to_job(planet_test.sign(:'fence')) as fjob \gset
select public.create_invoice_for_job(:'fjob', 'deposit') as fdeposit \gset
select tps.check(tps.error_of(format($q$update public.jobs set billing_mode = 'per_visit' where id = %L$q$, :'fjob'))
    = '22023: This job''s payment schedule still has payments to come: Payment 2 of 3 ($300.00), Payment 3 of 3 ($300.00). Billing it after each visit would bill them twice, so drop them from the job first',
  'a job with payments to come can''t be switched to invoicing after each visit without dropping them, and the refusal names them');
select tps.check(tps.error_of(format($q$update public.jobs set pricing = 'per_visit', invoice_schedule = 'after_visit' where id = %L$q$, :'fjob')) like '22023: This job''s payment schedule still has payments to come:%after each visit%',
  'however the change is written');
select tps.check(tps.error_of(format($q$update public.jobs set kind = 'recurring', recurrence_rule = 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO', starts_on = current_date where id = %L$q$, :'fjob')) like '22023: This job''s payment schedule still has payments to come:%as repeating work%',
  'nor made a repeating job');
update public.jobs set billing_mode = 'progress' where id = :'fjob';
update public.jobs set billing_mode = 'on_completion', title = 'Fence and gate' where id = :'fjob';
select tps.check((select title = 'Fence and gate' from public.jobs where id = :'fjob'), 'anything else about the job still changes, progress billing included');
select tps.as_user(:'cruz');
select tps.check(tps.error_of(format('select public.drop_unmade_installments(%L)', :'fjob')) = 'P0002: Job not found', 'the crew can''t drop a job''s payments');
select tps.as_user(:'olly');
select tps.check(public.drop_unmade_installments(:'fjob') = 2, 'the office drops the two payments still to come');
update public.jobs set billing_mode = 'per_visit' where id = :'fjob';
commit;
select tps.check(tps.rows(:'fjob') = '1:300.00:approval:deposit/300.00/draft' and (select billing_mode = 'per_visit' from public.jobs where id = :'fjob'),
  'then the job is invoiced after each visit, and the payment already invoiced keeps its invoice');
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'fjob', 'Fence', private.company_today(:'co'), 'in_progress');
select tps.check((select count(*) = 1 from public.invoices where job_id = :'fjob'), 'the work starting makes no payment''s invoice any more, so nothing is billed twice');
-- A job that was switched before the guard (the migration marks those): nothing is made for it either way.
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.quote(:'co', :'erin', 'Old fence', 400) as oldfence \gset
update public.quotes set payment_schedule = '[{"kind": "percent", "value": 50, "due": "work_starts"}, {"kind": "rest", "due": "work_done"}]' where id = :'oldfence';
select planet_test.sign(:'oldfence');
select public.convert_quote_to_job(planet_test.sign(:'oldfence')) as ojob \gset
commit;
alter table public.jobs disable trigger keeps_schedule;
update public.jobs set billing_mode = 'per_visit' where id = :'ojob';
alter table public.jobs enable trigger keeps_schedule;
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'ojob', 'Old fence', private.company_today(:'co'), 'in_progress');
select tps.check((select count(*) = 0 from public.invoices where job_id = :'ojob')
  and (select made_at is not null and problem = 'Not made: this job is invoiced visit by visit now' from public.job_installments where id = tps.row_id(:'ojob', 1)),
  'a job switched before the guard has no payment made as its work starts, and the payment says why');
begin;
set local role authenticated;
select tps.as_user(:'olly');
select tps.check(tps.error_of(format('select public.invoice_installment(%L)', tps.row_id(:'ojob', 2))) = '22023: This job is invoiced after each visit, so its payment schedule no longer applies',
  'nor by hand');
commit;

-- Only the server runs the hourly run and the sends.
select tps.check(not has_function_privilege('authenticated', 'public.make_due_installments()', 'execute')
  and not has_function_privilege('authenticated', 'public.claim_installment_sends(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.installment_sent(uuid, boolean, text)', 'execute')
  and not has_table_privilege('authenticated', 'public.job_installments', 'insert')
  and not has_table_privilege('authenticated', 'public.job_installments', 'update'),
  'only the database and the server write payments');

\echo 'All payment schedule tests passed.'
