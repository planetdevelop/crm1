-- Database tests for 20261113000410_deposit_invoice_at_every_approval.sql: a quote's deposit gets
-- its invoice as the client approves whether or not it's paid online; not paid online, the people
-- who look after money are told at once; sent on to pay online, they're told once if it's still
-- unpaid an hour later; and the server before this one, which calls with two arguments, gets what
-- it always got.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tda;
grant usage on schema tda to authenticated, service_role;
create function tda.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- A sent quote for p_total asking for p_deposit up front.
create function tda.quote(p_company uuid, p_client uuid, p_title text, p_total numeric, p_deposit numeric) returns uuid language plpgsql as $$
declare v_quote uuid;
begin
  insert into public.quotes (company_id, client_id, title, deposit_amount) values (p_company, p_client, p_title, p_deposit) returning id into v_quote;
  insert into public.quote_line_items (company_id, quote_id, name, unit_price) values (p_company, v_quote, 'Work', p_total);
  update public.quotes set status = 'sent', sent_at = now() where id = v_quote;
  return v_quote;
end $$;
-- The bell notifications about an invoice, as "who: title | body" lines.
create function tda.told(p_invoice uuid) returns text language sql stable as $$
  select string_agg(u.email || ': ' || n.title || ' | ' || coalesce(n.body, ''), E'\n' order by u.email, n.created_at)
  from public.notifications n join auth.users u on u.id = n.user_id
  where n.kind = 'invoice' and n.link = '/invoices/' || p_invoice
$$;
grant execute on all functions in schema tda to authenticated, service_role;

\set dana 'd4100000-0000-0000-0000-000000000001'
\set omar 'd4100000-0000-0000-0000-000000000002'
\set cal 'd4100000-0000-0000-0000-000000000003'

-- Dana owns Dune Decks; Omar is in her office; Cal is on a crew (never told about money).
insert into auth.users (id, email, raw_user_meta_data) values
  (:'dana', 'dana@dune-decks.test', '{"full_name": "Dana Dune"}'),
  (:'omar', 'omar@dune-decks.test', '{"full_name": "Omar Office"}'),
  (:'cal', 'cal@dune-decks.test', '{"full_name": "Cal Crew"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'dana', 'role', 'authenticated')::text, true);
select public.create_company('Dune Decks', 'general', 'America/Denver') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'omar', 'office'), (:'co', :'cal', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Erin Estes') returning id as erin \gset
select tda.quote(:'co', :'erin', 'Deck', 5000, 500) as deck \gset
select tda.quote(:'co', :'erin', 'Stairs', 800, 200) as stairs \gset
select tda.quote(:'co', :'erin', 'Railing', 600, 150) as railing \gset
select tda.quote(:'co', :'erin', 'Bench', 300, 100) as bench \gset
select tda.quote(:'co', :'erin', 'Planter', 250, 0) as planter \gset
commit;

set role service_role;
select tda.check(public.approve_hub_quote(:'co', :'deck', null, planet_test.approval(:'deck', '{"name": "Erin Estes"}')), 'Erin approves the deck');
select tda.check(public.approve_hub_quote(:'co', :'stairs', null, planet_test.approval(:'stairs', '{"name": "Erin Estes"}')), 'the stairs');
select tda.check(public.approve_hub_quote(:'co', :'railing', null, planet_test.approval(:'railing', '{"name": "Erin Estes"}')), 'the railing');
select tda.check(public.approve_hub_quote(:'co', :'bench', null, planet_test.approval(:'bench', '{"name": "Erin Estes"}')), 'the bench');
select tda.check(public.approve_hub_quote(:'co', :'planter', null, planet_test.approval(:'planter', '{"name": "Erin Estes"}')), 'and the planter');

-- ===== Not paid online: the invoice is made, and the office is told at once ====================
select public.hub_deposit_invoice(:'co', :'deck', false) as deck_deposit \gset
reset role;
select tda.check((select kind = 'deposit' and status = 'sent' and total = 500 and balance_due = 500 and due_on = issued_on + 30
                    from public.invoices where id = :'deck_deposit'),
  'a business without online payments gets the deposit''s invoice too: sent, owed, due on its payment terms');
select tda.check((select deposit_invoice_id = :'deck_deposit' and deposit_told_at is not null from public.quotes where id = :'deck'), 'the quote keeps it, and that the office was told');
select tda.check(tda.told(:'deck_deposit') = (select format(
    E'dana@dune-decks.test: Erin Estes owes a $500.00 deposit on quote #%1$s | They approved it online. Invoice #%2$s is for the deposit: record the payment on it when it comes in.\n'
    'omar@dune-decks.test: Erin Estes owes a $500.00 deposit on quote #%1$s | They approved it online. Invoice #%2$s is for the deposit: record the payment on it when it comes in.',
    (select number from public.quotes where id = :'deck'), (select number from public.invoices where id = :'deck_deposit'))),
  'the owner and the office are told on the bell, with the invoice to record it on; the crew isn''t');
set role service_role;
select tda.check(public.hub_deposit_invoice(:'co', :'deck', false) = :'deck_deposit', 'asked again, it''s the same invoice');
select tda.check(public.tell_unpaid_deposits() = 0, 'and the hourly run has nothing to add');
reset role;
select tda.check((select count(*) = 2 from public.notifications where link = '/invoices/' || :'deck_deposit'), 'so nobody is told twice');

-- The office records the cheque against it, as against any invoice.
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'omar', 'role', 'authenticated')::text, true);
insert into public.payments (company_id, invoice_id, client_id, amount, method) values (:'co', :'deck_deposit', :'erin', 500, 'check');
commit;
select tda.check((select status = 'paid' and balance_due = 0 from public.invoices where id = :'deck_deposit'), 'a cheque recorded on it pays it');

-- ===== Sent on to pay online: told an hour later, only if it's still unpaid ====================
set role service_role;
-- The server before this one calls with two arguments, and means "paying online".
select public.hub_deposit_invoice(:'co', :'stairs') as stairs_deposit \gset
select public.hub_deposit_invoice(:'co', :'railing', true) as railing_deposit \gset
select public.hub_deposit_invoice(:'co', :'bench', true) as bench_deposit \gset
select tda.check(public.hub_deposit_invoice(:'co', :'planter', false) is null, 'a quote that asks for no deposit gets no invoice');
reset role;
select tda.check((select count(*) = 3 and bool_and(deposit_told_at is null) from public.quotes where id in (:'stairs', :'railing', :'bench'))
  and tda.told(:'stairs_deposit') is null and tda.told(:'railing_deposit') is null,
  'while the client is on Stripe''s page, nobody is told yet');
set role service_role;
select tda.check(public.tell_unpaid_deposits() = 0, 'nor in the first hour');
reset role;

-- An hour goes by: Erin paid for the railing, the bench's bank payment is on its way, the stairs are unpaid.
set session_replication_role = replica;
update public.invoices set created_at = now() - interval '61 minutes' where id in (:'stairs_deposit', :'railing_deposit', :'bench_deposit');
set session_replication_role = default;
insert into public.payments (company_id, invoice_id, client_id, amount, method, processor, processor_ref)
values (:'co', :'railing_deposit', :'erin', 150, 'card', 'stripe', 'pi_tda_railing');
insert into public.stripe_invoices (company_id, invoice_id, stripe_id, origin, status, amount_due) values (:'co', :'bench_deposit', 'in_tda_bench', 'crewtavo', 'processing', 100);
set role service_role;
select tda.check(public.tell_unpaid_deposits() = 1, 'an hour on, the hourly run tells the office about the one still unpaid');
reset role;
select tda.check(tda.told(:'stairs_deposit') = (select format(
    E'dana@dune-decks.test: Erin Estes hasn''t paid the $200.00 deposit on quote #%1$s | They approved it online but the deposit isn''t paid yet. Invoice #%2$s is for it.\n'
    'omar@dune-decks.test: Erin Estes hasn''t paid the $200.00 deposit on quote #%1$s | They approved it online but the deposit isn''t paid yet. Invoice #%2$s is for it.',
    (select number from public.quotes where id = :'stairs'), (select number from public.invoices where id = :'stairs_deposit'))),
  'in words that say it wasn''t paid online');
select tda.check(tda.told(:'railing_deposit') is null and (select deposit_told_at is not null from public.quotes where id = :'railing'),
  'a deposit paid in that hour is settled without a word');
select tda.check(tda.told(:'bench_deposit') is null and (select deposit_told_at is null from public.quotes where id = :'bench'),
  'one whose bank payment is on its way is left for the next hour');
set role service_role;
select tda.check(public.tell_unpaid_deposits() = 0, 'a second run tells nobody again');
reset role;
-- The bank payment bounces: now it's unpaid, and the office hears.
update public.stripe_invoices set status = 'open' where stripe_id = 'in_tda_bench';
set role service_role;
select tda.check(public.tell_unpaid_deposits() = 1, 'when that bank payment bounces, the next run tells the office');
reset role;

-- ===== Who may call ===========================================================================
select tda.check(not has_function_privilege('authenticated', 'public.hub_deposit_invoice(uuid, uuid, boolean)', 'execute')
  and not has_function_privilege('anon', 'public.hub_deposit_invoice(uuid, uuid, boolean)', 'execute')
  and not has_function_privilege('authenticated', 'public.tell_unpaid_deposits()', 'execute')
  and not has_function_privilege('anon', 'public.tell_unpaid_deposits()', 'execute'),
  'only the server makes deposit invoices and runs the hourly check');
select tda.check((select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'hub_deposit_invoice'),
  'there is one hub_deposit_invoice, so a call with two arguments isn''t ambiguous');

\echo 'All deposit at approval tests passed.'
