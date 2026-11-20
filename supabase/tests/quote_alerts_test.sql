-- Database tests for 20261113001120_high_value_quote_alerts.sql: with "Tell me about quotes over $X"
-- set, a quote at or above it being sent, approved or sent back for changes tells the owners, the
-- admins and its salesperson on the bell, once per quote per event; nothing while it's off, under
-- the amount, or for a template.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tqa;
grant usage on schema tqa to authenticated, service_role;
create function tqa.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tqa.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The alerts about a quote (not its other notices, like a salesperson handed it), as "who: title | body" lines.
create function tqa.told(p_quote uuid) returns text language sql stable as $$
  select string_agg(u.email || ': ' || n.title || ' | ' || coalesce(n.body, ''), E'\n' order by n.created_at, u.email)
  from public.notifications n join auth.users u on u.id = n.user_id
  where n.kind = 'quote' and n.link = '/quotes/' || p_quote and n.body like '%you asked to hear about.'
$$;
create function tqa.count(p_quote uuid) returns bigint language sql stable as $$
  select count(*) from public.notifications where kind = 'quote' and link = '/quotes/' || p_quote and body like '%you asked to hear about.'
$$;
grant execute on all functions in schema tqa to authenticated, service_role;

\set ora 'a5c10000-0000-0000-0000-000000000001'
\set ada 'a5c10000-0000-0000-0000-000000000002'
\set sam 'a5c10000-0000-0000-0000-000000000003'
\set oz 'a5c10000-0000-0000-0000-000000000004'

begin;
-- Ora owns Oak Roofing; Ada is an admin; Sam sells (an estimator); Oz is in the office.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'ora', 'ora@oak.test', '{"full_name": "Ora Oak"}'), (:'ada', 'ada@oak.test', '{"full_name": "Ada Admin"}'),
  (:'sam', 'sam@oak.test', '{"full_name": "Sam Seller"}'), (:'oz', 'oz@oak.test', '{"full_name": "Oz Office"}');
set local role authenticated;
select tqa.as_user(:'ora');
select public.create_company('Oak Roofing', 'roofing') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'ada', 'admin'), (:'co', :'sam', 'estimator'), (:'co', :'oz', 'office');
insert into public.clients (company_id, display_name) values (:'co', 'Lee Lopez') returning id as lee \gset

set local role authenticated;
select tqa.as_user(:'oz');
insert into public.quotes (company_id, client_id, title, salesperson_id) values (:'co', :'lee', 'New roof', :'sam') returning id as big \gset
insert into public.quote_line_items (company_id, quote_id, name, unit_price) values (:'co', :'big', 'Roof', 25000);
insert into public.quotes (company_id, client_id, title) values (:'co', :'lee', 'Gutter repair') returning id as small \gset
insert into public.quote_line_items (company_id, quote_id, name, unit_price) values (:'co', :'small', 'Gutters', 900);

-- ===== Off until it's set =====================================================================
update public.quotes set status = 'sent', sent_at = now() where id = :'big';
select tqa.check(tqa.count(:'big') = 0, 'with no amount set, nobody is told');
update public.quotes set status = 'draft' where id = :'big';

select tqa.as_user(:'ora');
select public.merge_company_settings(:'co', '{"quotes": {"alert_over": 10000}}');
select tqa.as_user(:'oz');

-- ===== Sent, changes asked for, approved: each once ===========================================
update public.quotes set status = 'sent', sent_at = now() where id = :'big';
update public.quotes set status = 'sent', sent_at = now() where id = :'small';
reset role;
select tqa.check(tqa.told(:'big') = (select format(
    E'ada@oak.test: Quote #%1$s for $25,000.00 was sent to Lee Lopez | New roof. It''s at or above the $10,000.00 you asked to hear about.\n'
    'ora@oak.test: Quote #%1$s for $25,000.00 was sent to Lee Lopez | New roof. It''s at or above the $10,000.00 you asked to hear about.\n'
    'sam@oak.test: Quote #%1$s for $25,000.00 was sent to Lee Lopez | New roof. It''s at or above the $10,000.00 you asked to hear about.',
    (select number from public.quotes where id = :'big'))),
  'a quote over the amount being sent tells the owner, the admin and its salesperson, with the client and the amount; not the rest of the office');
select tqa.check(tqa.count(:'small') = 0, 'a quote under it tells nobody');
commit;

set role service_role;
update public.quotes set status = 'changes_requested' where id = :'big';
reset role;
select tqa.check(tqa.count(:'big') = 6 and tqa.told(:'big') like '%sam@oak.test: Lee Lopez asked for changes to quote #% for $25,000.00 | New roof.%',
  'the client asking for changes in the Client Hub tells them too');
begin;
set local role authenticated;
select tqa.as_user(:'oz');
update public.quotes set status = 'sent', sent_at = now() where id = :'big';
commit;
select tqa.check(tqa.count(:'big') = 6, 'sending it again after the changes tells nobody again');
set role service_role;
update public.quotes set status = 'changes_requested' where id = :'big';
select tqa.check(public.approve_hub_quote(:'co', :'big', null, planet_test.approval(:'big', '{"name": "Lee Lopez"}')), 'Lee approves it');
reset role;
select tqa.check(tqa.count(:'big') = 9 and tqa.told(:'big') like '%ora@oak.test: Lee Lopez approved quote #% for $25,000.00 | New roof.%',
  'asking for changes twice tells once; approving tells them');
begin;
set local role authenticated;
select tqa.as_user(:'oz');
select public.convert_quote_to_job(planet_test.sign(:'big'));
commit;
select tqa.check(tqa.count(:'big') = 9, 'making it a job isn''t approving it again');

-- Converted straight from sent counts as approved.
begin;
set local role authenticated;
select tqa.as_user(:'oz');
insert into public.quotes (company_id, client_id, title) values (:'co', :'lee', 'Barn roof') returning id as barn \gset
insert into public.quote_line_items (company_id, quote_id, name, unit_price) values (:'co', :'barn', 'Roof', 12000);
update public.quotes set status = 'sent', sent_at = now() where id = :'barn';
select public.convert_quote_to_job(planet_test.sign(:'barn'));
commit;
select tqa.check((select string_agg(event, ',' order by event) = 'approved,sent' from public.quote_alerts where quote_id = :'barn') and tqa.told(:'barn') like '%ada@oak.test: Lee Lopez approved quote #% for $12,000.00 | Barn roof.%',
  'a quote converted straight from sent tells them it was approved');
select tqa.check((select count(*) = 3 from public.quote_alerts where quote_id = :'big'), 'each event is kept once');

-- ===== Not whoever did it (20261113001660_quote_alerts_skip_who_did_it.sql) ====================
begin;
set local role authenticated;
select tqa.as_user(:'ora');
insert into public.quotes (company_id, client_id, title, salesperson_id) values (:'co', :'lee', 'Shop roof', :'sam') returning id as shop \gset
insert into public.quote_line_items (company_id, quote_id, name, unit_price) values (:'co', :'shop', 'Roof', 18000);
update public.quotes set status = 'sent', sent_at = now() where id = :'shop';
commit;
select tqa.check(tqa.told(:'shop') = (select format(
    E'ada@oak.test: Quote #%1$s for $18,000.00 was sent to Lee Lopez | Shop roof. It''s at or above the $10,000.00 you asked to hear about.\n'
    'sam@oak.test: Quote #%1$s for $18,000.00 was sent to Lee Lopez | Shop roof. It''s at or above the $10,000.00 you asked to hear about.',
    (select number from public.quotes where id = :'shop'))),
  'the owner sending her own quote isn''t told about it; the admin and the salesperson are');
begin;
set local role authenticated;
select tqa.as_user(:'sam');
select planet_test.sign(:'shop');
commit;
-- Planet Ops: only the customer's signature accepts it (20261120000100), so nobody on the team did it
-- themselves: the owner, the admin and the salesperson are all told.
select tqa.check(tqa.count(:'shop') = 5 and tqa.told(:'shop') like '%ada@oak.test: Lee Lopez approved quote #% for $18,000.00 |%ora@oak.test: Lee Lopez approved quote #% for $18,000.00 |%sam@oak.test: Lee Lopez approved quote #% for $18,000.00 |%',
  'when the customer signs, the owner, the admin and the salesperson are told');
select tqa.check((select count(*) = 2 from public.quote_alerts where quote_id = :'shop'), 'and each event is still kept once');

-- ===== Only the database writes them ===========================================================
select tqa.check(not has_table_privilege('authenticated', 'public.quote_alerts', 'insert'), 'nobody writes quote_alerts but the database');
begin;
set local role authenticated;
select tqa.as_user(:'sam');
select tqa.check((select count(*) = 0 from public.quote_alerts), 'an estimator doesn''t read them');
select tqa.as_user(:'ada');
select tqa.check((select count(*) = 7 from public.quote_alerts), 'an admin does');
commit;

\echo 'All quote alert tests passed.'
