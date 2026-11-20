-- Planet Ops Phase 1: customer acceptance needs the customer's drawn signature on the exact document
-- version, for quotes and change orders, on the client hub and in person; internal approval never
-- stands in for it; a signed agreement stays as signed (20261120000100_planet_ops_change_order_signature.sql).
-- The drawing used is one made on the app's own signature pad (planet_test.drawn(), prelude.sql).
-- Run with scripts/test-db.sh.
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
-- The customer signs on their link (approve_hub_quote, as the server calls it), from a page that
-- showed the version with fingerprint p_seen, with the given drawing.
create function tpo_co.hub_signs(p_company uuid, p_quote uuid, p_seen text, p_signature text default planet_test.drawn(), p_name text default 'Test Customer') returns boolean
language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', p_name, 'signed_at', '2000-01-01T00:00:00Z', 'signature', p_signature, 'ip', '203.0.113.5')
      || case when p_seen is null then '{}' else jsonb_build_object('seen_fingerprint', p_seen) end)
$$;
-- The customer signs in person (sign_quote, which the API calls as the server after checking them).
create function tpo_co.in_person_signs(p_quote uuid, p_seen text, p_signature text default planet_test.drawn()) returns jsonb
language plpgsql security definer as $$
declare v_claims text := current_setting('request.jwt.claims', true); v jsonb;
begin
  perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
  v := public.sign_quote(p_quote, jsonb_build_object('name', 'Test Customer', 'signed_at', '2000-01-01T00:00:00Z', 'method', 'in_person', 'signature', p_signature)
                          || case when p_seen is null then '{}' else jsonb_build_object('seen_fingerprint', p_seen) end);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return v;
end $$;
-- With options: the customer signs on their link for p_option, from a page that showed version
-- p_seen, with or without the total they saw (p_total), as the server calls approve_hub_quote.
create function tpo_co.hub_signs_for(p_company uuid, p_quote uuid, p_option uuid, p_seen text, p_total numeric default null) returns boolean
language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'signature', planet_test.drawn(), 'seen_fingerprint', p_seen),
    p_option, p_total)
$$;
-- And in person, for the option shown (sign_quote, as the API calls it), with or without the total.
create function tpo_co.in_person_signs_for(p_quote uuid, p_option uuid, p_seen text, p_total numeric default null) returns jsonb
language plpgsql security definer as $fn$
declare v_claims text := current_setting('request.jwt.claims', true); v jsonb;
begin
  perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
  v := public.sign_quote(p_quote, jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'method', 'in_person',
                                                     'signature', planet_test.drawn(), 'seen_fingerprint', p_seen), p_option, p_total);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return v;
end $fn$;
grant execute on all functions in schema tpo_co to authenticated, service_role;

\set one_pixel 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0c00000-0000-0000-0000-000000000001', 'owner@planet.test', '{"full_name": "Test Owner"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Sample Customer') returning id as client \gset
insert into public.contract_sections (company_id, title, body) values (:'co', 'Contract Terms', 'TEST placeholder contract terms.') returning id as terms \gset
insert into public.contract_sections (company_id, title, body) values (:'co', 'Payment Terms', 'TEST placeholder payment terms.') returning id as payment \gset
-- A quote, sent to the customer.
insert into public.quotes (company_id, client_id, title, section_ids) values (:'co', :'client', 'House demolition', array[:'terms', :'payment']::uuid[]) returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 'Down to the slab', 1, 'ea', 18000) returning id as quote_line \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price, optional, selected) values (:'co', :'quote', 'Remove the shed too', 1, 'ea', 900, true, false) returning id as addon \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
commit;

-- ===== Staff, the API and the database can't accept or convert without the customer ==========
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'quote'),
  'the office can''t mark a quote approved', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = ''{"name": "Test Owner", "method": "manual"}'' where id = %L', :'quote'),
  'nor with a manual approval in its own name: internal approval isn''t the customer''s', '%customer signs this exact version%');
select tpo_co.expect_error(format('select public.convert_quote_to_job(%L)', :'quote'),
  'converting an unsigned quote to a job is refused', '%once the customer signs%');
select tpo_co.expect_error(format('update public.quotes set status = ''converted'', converted_at = now() where id = %L', :'quote'),
  'and so is marking it converted', '%customer signs this exact version%');
select tpo_co.expect_error(format('insert into public.quotes (company_id, client_id, title, status) values (%L, %L, ''Sneaky'', ''approved'')', :'co', :'client'),
  'a quote can''t be inserted already accepted', '%customer signs this exact version%');
select tpo_co.expect_error(format('insert into public.jobs (company_id, client_id, title, quote_id) values (%L, %L, ''Job'', %L)', :'co', :'client', :'quote'),
  'nor a job linked to an unsigned quote', '%only once the customer signs it%');
-- Fabricated signature metadata: a complete-looking customer signature with a real drawing and the
-- right fingerprint, written by someone signed in, is refused whether or not it accepts anything.
select tpo_co.expect_error(format('update public.quotes set approval = jsonb_build_object(''name'', ''Test Customer'', ''signed_at'', now(), ''signature'', planet_test.drawn(), ''method'', ''in_person'', ''seen_fingerprint'', public.quote_fingerprint(id)) where id = %L', :'quote'),
  'staff can''t write a customer signature into the quote', '%Only the customer can sign%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = jsonb_build_object(''name'', ''Test Customer'', ''signed_at'', now(), ''signature'', planet_test.drawn(), ''seen_fingerprint'', public.quote_fingerprint(id)) where id = %L', :'quote'),
  'nor accept the quote with one', '%Only the customer can sign%');
select tpo_co.expect_error(format('select public.sign_quote(%L, ''{"name": "Test Customer", "method": "in_person"}'')', :'quote'),
  'nor call the in-person signing step directly', '%permission denied%');
select tpo_co.check((select status = 'sent' and approval is null from public.quotes where id = :'quote'), 'the quote is still waiting for the customer, with no approval on it');
select tpo_co.check(public.quote_fingerprint(:'quote') ~ '^[0-9a-f]{32}$', 'a member can read the version fingerprint of their own quote (the signing screen''s)');
commit;

-- ===== Only a drawn signature signs: missing, typed or invalid drawings, on both paths ========
select public.quote_fingerprint(:'quote') as qv1 \gset
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, null)', :'co', :'quote', :'qv1'),
  'on the link: no drawing is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, %L)', :'co', :'quote', :'qv1', 'Test Customer'),
  'a typed name where the drawing goes is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, %L)', :'co', :'quote', :'qv1', :'one_pixel'),
  'a one-pixel image is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, %L)', :'co', :'quote', :'qv1', 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ'),
  'another kind of picture is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, %L)', :'co', :'quote', :'qv1', substr(planet_test.drawn(), 1, 60)),
  'a truncated drawing is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L, planet_test.drawn(), %L)', :'co', :'quote', :'qv1', '  '),
  'a drawing without the printed name is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs(%L, %L, null)', :'quote', :'qv1'),
  'in person: no drawing is refused', '%drawn signature is needed%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs(%L, %L, %L)', :'quote', :'qv1', 'Test Customer'),
  'in person: a typed name is refused', '%drawn signature is needed%');
-- A blank pad, a tap and a malformed image are refused by the API, which decodes the whole drawing
-- (apps/api/test/drawnSignature.test.ts); only the server writes signatures here.

-- ===== Every acceptance is from a page showing this exact version ============================
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, null)', :'co', :'quote'),
  'on the link: a signature without the version fingerprint is refused', '%page showing its exact version%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs(%L, null)', :'quote'),
  'in person: also refused without it', '%page showing its exact version%');
-- Same price, different scope.
update public.quote_line_items set description = 'Down to the slab, and the driveway' where id = :'quote_line';
select tpo_co.check(public.quote_fingerprint(:'quote') <> :'qv1' and (select total from public.quotes where id = :'quote') = 18000, 'a scope change at the same price is a new version');
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'quote', :'qv1'),
  'so a link page opened before it can''t sign', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs(%L, %L)', :'quote', :'qv1'),
  'nor an in-person screen opened before it', '%changed after it was opened%');
select public.quote_fingerprint(:'quote') as qv2 \gset
update public.quotes set starts_on = current_date + 14 where id = :'quote';
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'quote', :'qv2'), 'a schedule change makes an open page outdated', '%changed after it was opened%');
select public.quote_fingerprint(:'quote') as qv3 \gset
update public.contract_sections set body = 'TEST placeholder contract terms, revised.' where id = :'terms';
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'quote', :'qv3'), 'so does a Contract Terms change', '%changed after it was opened%');
select public.quote_fingerprint(:'quote') as qv4 \gset
update public.contract_sections set body = 'TEST placeholder payment terms, revised.' where id = :'payment';
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'quote', :'qv4'), 'and a Payment Terms change', '%changed after it was opened%');
select public.quote_fingerprint(:'quote') as qv5 \gset
update public.quotes set deposit_amount = 500 where id = :'quote';
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'quote', :'qv5'), 'and a deposit change', '%changed after it was opened%');
update public.quote_line_items set unit_price = 950 where id = :'addon';
select tpo_co.check(public.quote_fingerprint(:'quote') <> :'qv5', 'an offered option''s price is part of the version too');
select tpo_co.check((select status = 'sent' and approval is null from public.quotes where id = :'quote'), 'no outdated page signed anything');

-- ===== The customer signs the version they saw: the original signed document is kept =========
select public.quote_fingerprint(:'quote') as qv6 \gset
update public.quote_line_items set selected = true where id = :'addon';
select tpo_co.check(public.quote_fingerprint(:'quote') = :'qv6', 'ticking an add-on is the customer''s choice, not a new version');
select tpo_co.check(public.approve_hub_quote(:'co', :'quote', array[:'addon']::uuid[],
  jsonb_build_object('name', 'Test Customer', 'signed_at', '2000-01-01T00:00:00Z', 'signature', planet_test.drawn(), 'seen_fingerprint', :'qv6')),
  'the customer signs on their link, with the shed added');
select tpo_co.check((select status from public.quotes where id = :'quote') = 'approved', 'the quote is accepted');
select tpo_co.check((select approval ->> 'name' = 'Test Customer' and approval ->> 'signature' = planet_test.drawn()
                       and (approval ->> 'signed_at')::timestamptz > now() - interval '1 hour'
                     from public.quotes where id = :'quote'),
  'the printed name, the drawing and the signing time are kept separately, the time from the database''s clock (not the caller''s)');
select tpo_co.check((select approval ->> 'fingerprint' = :'qv6'
                       and approval -> 'document' -> 'lines' @> jsonb_build_array(jsonb_build_object('description', 'Down to the slab, and the driveway'))
                       and approval -> 'document' -> 'sections' @> '[{"body": "TEST placeholder payment terms, revised."}]'
                       and approval -> 'document' -> 'quote' ->> 'starts_on' is not null
                     from public.quotes where id = :'quote'), 'the signed version is kept: scope, terms and schedule as signed');
select tpo_co.check((select approval -> 'choices' -> 'selected_line_ids' = jsonb_build_array(:'addon'::text)
                       and (approval -> 'choices' ->> 'total')::numeric = 18950 and (approval ->> 'total')::numeric = 18950
                     from public.quotes where id = :'quote'), 'with the customer''s choices (the add-on) and the amounts they signed for');
select tpo_co.check(not public.approve_hub_quote(:'co', :'quote', '{}', planet_test.approval(:'quote')), 'a second signature does nothing');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''sent'' where id = %L', :'quote'), 'a signed quote can''t be reopened', '%stays as signed%');
select tpo_co.expect_error(format('update public.quotes set status = ''lost'' where id = %L', :'quote'), 'nor marked lost', '%stays as signed%');
select tpo_co.expect_error(format('delete from public.quotes where id = %L', :'quote'), 'nor deleted');
select tpo_co.expect_error(format('update public.quote_line_items set unit_price = 1 where id = %L', :'quote_line'), 'its signed lines can''t change');
select tpo_co.expect_error(format('update public.quotes set approval = approval || ''{"name": "Someone Else"}'' where id = %L', :'quote'), 'its signature can''t be rewritten');
commit;
select public.convert_quote_to_job(:'quote') as job \gset
select tpo_co.check((select status from public.quotes where id = :'quote') = 'converted' and (select quote_id from public.jobs where id = :'job') = :'quote',
  'the signed quote becomes a job, linked to it');
select tpo_co.check((select approval ->> 'fingerprint' from public.quotes where id = :'quote') = :'qv6', 'and keeps the signed document');

-- In person: the same, on another quote.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Garage demolition') returning id as garage \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'garage', 'Demolish garage', 1, 'ea', 6000);
update public.quotes set status = 'sent', sent_at = now() where id = :'garage';
select tpo_co.check((tpo_co.in_person_signs(:'garage', public.quote_fingerprint(:'garage')) ->> 'total')::numeric = 6000, 'the customer signs in person, drawing on the screen');
select tpo_co.check((select status = 'approved' and approval ->> 'method' = 'in_person' and approval ->> 'fingerprint' = private.quote_fingerprint(id) from public.quotes where id = :'garage'),
  'accepted, tied to the version on the screen');
select tpo_co.check(not public.approve_hub_quote(:'co', :'garage', '{}', planet_test.approval(:'garage')), 'nobody signs over a signature already given');
-- An office approval from before the rule: it needs the customer's signature before it's a job.
alter table public.quotes disable trigger c_customer_signature_to_accept_update;
insert into public.quotes (company_id, client_id, title, status) values (:'co', :'client', 'Old office-approved', 'sent') returning id as legacy \gset
update public.quotes set status = 'approved', approval = '{"name": "Test Owner", "method": "manual"}' where id = :'legacy';
alter table public.quotes enable trigger c_customer_signature_to_accept_update;
select tpo_co.expect_error(format('select public.convert_quote_to_job(%L)', :'legacy'), 'a quote the office approved itself isn''t made a job', '%once the customer signs%');

-- ===== Change orders: the same, and a signed one stays as signed =============================
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: remove garage slab', :'job') returning id as add \gset
insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price) values (:'co', :'add', 'Remove garage slab', 'Break out and haul the slab', 1, 'ea', 2500) returning id as add_line \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'add';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'add'), 'the office can''t finalize an unsigned change order', '%customer signs this exact version%');
select tpo_co.expect_error(format('select public.convert_quote_to_job(%L)', :'add'), 'nor add it to the job by converting it', '%customer signs this exact version%');
select tpo_co.expect_error(format('insert into public.quotes (company_id, client_id, title, status, change_order_for) values (%L, %L, ''Sneaky'', ''converted'', %L)', :'co', :'client', :'job'),
  'nor insert one already finalized', '%customer signs this exact version%');
commit;
select public.quote_fingerprint(:'add') as cv1 \gset
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, null)', :'co', :'add'), 'a change order isn''t signed without its version fingerprint', '%page showing its exact version%');
update public.quote_line_items set description = 'Break out and haul the slab and the walkway' where id = :'add_line';
select tpo_co.expect_error(format('select tpo_co.hub_signs(%L, %L, %L)', :'co', :'add', :'cv1'), 'nor from a page showing an older version (same price)', '%changed after it was opened%');
select tpo_co.check(not exists (select 1 from public.job_line_items where source_quote_id = :'add'), 'nothing was added to the job');
select tpo_co.check(tpo_co.hub_signs(:'co', :'add', public.quote_fingerprint(:'add')), 'the customer signs the change order they saw');
select tpo_co.check((select status from public.quotes where id = :'add') = 'converted', 'it''s finalized and added to the job');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add' and unit_price = 2500) = 1, 'its line is on the job once');
select tpo_co.check(not tpo_co.hub_signs(:'co', :'add', public.quote_fingerprint(:'add')), 'a repeated signature does nothing');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add') = 1, 'and adds nothing twice');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''sent'' where id = %L', :'add'), 'a signed change order can''t be reopened', '%stays as signed%');
select tpo_co.expect_error(format('update public.quotes set status = ''archived'' where id = %L', :'add'), 'nor archived', '%stays as signed%');
select tpo_co.expect_error(format('delete from public.quotes where id = %L', :'add'), 'nor deleted');
select tpo_co.expect_error(format('update public.quote_line_items set unit_price = 1 where id = %L', :'add_line'), 'its signed price can''t change');
select tpo_co.expect_error(format('update public.quote_line_items set description = ''something else'' where id = %L', :'add_line'), 'nor its signed scope');
select tpo_co.expect_error(format('insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (%L, %L, ''Extra'', 1, ''ea'', 10)', :'co', :'add'), 'nor can lines be added');
select tpo_co.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(''fingerprint'', ''0'') where id = %L', :'add'), 'nor the version it was signed for');
commit;
select tpo_co.expect_error(format('update public.quotes set status = ''sent'' where id = %L', :'add'), 'not even by the server', '%stays as signed%');

-- Credits and $0 changes need the signature too, and count once.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: leave the fence', :'job') returning id as credit \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'credit', 'Leave the fence standing (credit)', 1, 'ea', -800);
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: start a week later', :'job') returning id as zero \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'zero', 'Start date moves one week later', 1, 'ea', 0);
update public.quotes set status = 'sent', sent_at = now() where id in (:'credit', :'zero');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'' where id = %L', :'credit'), 'an unsigned credit isn''t finalized', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'' where id = %L', :'zero'), 'nor an unsigned $0 change', '%customer signs this exact version%');
select tpo_co.check(tpo_co.hub_signs(:'co', :'credit', public.quote_fingerprint(:'credit')), 'the customer signs the credit on their link');
select tpo_co.check((tpo_co.in_person_signs(:'zero', public.quote_fingerprint(:'zero')) ->> 'total')::numeric = 0, 'and the $0 change in person');
select tpo_co.check((select coalesce(sum(round(quantity * unit_price, 2)), 0) from public.job_line_items where job_id = :'job') = 18950 + 2500 - 800,
  'the job is the original signed agreement plus the signed changes, credit included, each once');

-- ===== A price set on site is part of the offer: both paths, with or without the total ======
-- An estimate with two options, priced on site for the one shown ("Price adjustment" lines on it).
create function tpo_co.site_priced(p_company uuid, p_client uuid, p_title text) returns uuid
language plpgsql security definer as $fn$
declare v_quote uuid; v_shown uuid;
begin
  insert into public.quotes (company_id, client_id, title) values (p_company, p_client, p_title) returning id into v_quote;
  perform public.apply_quote_options(v_quote, jsonb_build_array(
    jsonb_build_object('name', 'Shingles', 'sort', 0, 'lines', jsonb_build_array(jsonb_build_object('name', 'Shingle roof', 'unit_price', 2000))),
    jsonb_build_object('name', 'Metal', 'sort', 1, 'lines', jsonb_build_array(jsonb_build_object('name', 'Metal roof', 'unit_price', 4000)))), 'replace');
  select id into v_shown from public.quote_options where quote_id = v_quote and sort = 0;
  insert into public.quote_line_items (company_id, quote_id, option_id, name, unit_price) values (p_company, v_quote, v_shown, 'Price adjustment', -150);
  update public.quotes set status = 'sent', sent_at = now(), priced_on_site_at = now() where id = v_quote;
  return v_quote;
end $fn$;
grant execute on function tpo_co.site_priced(uuid, uuid, text) to authenticated, service_role;

select tpo_co.site_priced(:'co', :'client', 'Garage roof') as site \gset
select id as shingles from public.quote_options where quote_id = :'site' and sort = 0 \gset
select id as metal from public.quote_options where quote_id = :'site' and sort = 1 \gset
select tpo_co.check((select option_id = :'shingles' and total = 1850 from public.quotes where id = :'site'), 'an estimate priced on site at $1,850 for the shingles, the option shown');
select public.quote_fingerprint(:'site') as site_v1 \gset
-- The office changes the price set on site after the customer's page opened ($1,850 to $1,750).
update public.quote_line_items set unit_price = -250 where quote_id = :'site' and name = 'Price adjustment';
select tpo_co.check(public.quote_fingerprint(:'site') <> :'site_v1', 'a change to the price set on site is a new version');
select tpo_co.expect_error(format('select tpo_co.hub_signs_for(%L, %L, %L, %L)', :'co', :'site', :'shingles', :'site_v1'),
  'the customer''s link that showed the old price set on site can''t sign it, without the total it saw', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.hub_signs_for(%L, %L, %L, %L, %s)', :'co', :'site', :'shingles', :'site_v1', 1750),
  'nor with the new total typed in', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.hub_signs_for(%L, %L, %L, %L)', :'co', :'site', :'metal', :'site_v1'),
  'nor by choosing the other option, without the total', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs_for(%L, %L, %L)', :'site', :'shingles', :'site_v1'),
  'the in-person screen that showed the old price can''t sign it either, without the total', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs_for(%L, %L, %L, %s)', :'site', :'shingles', :'site_v1', 1750),
  'nor with the new total', '%changed after it was opened%');
-- Taken off (back to the estimate's price): a new version too.
select public.quote_fingerprint(:'site') as site_v2 \gset
update public.quotes set priced_on_site_at = null where id = :'site';
delete from public.quote_line_items where quote_id = :'site' and name = 'Price adjustment';
select tpo_co.check(public.quote_fingerprint(:'site') <> :'site_v2' and (select total from public.quotes where id = :'site') = 2000, 'taking the price set on site off is a new version');
select tpo_co.expect_error(format('select tpo_co.hub_signs_for(%L, %L, %L, %L)', :'co', :'site', :'shingles', :'site_v2'),
  'a page that showed the price set on site can''t sign the estimate''s price', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs_for(%L, %L, %L)', :'site', :'shingles', :'site_v2'),
  'on either path', '%changed after it was opened%');
select tpo_co.check((select status = 'sent' and approval is null from public.quotes where id = :'site'), 'none of them signed it');
-- The page that shows it now signs, the customer choosing the other option: that choice takes the
-- price set on site off as they sign, and it's still the version they saw.
select tpo_co.site_priced(:'co', :'client', 'Carport roof') as site2 \gset
select id as site2_metal from public.quote_options where quote_id = :'site2' and sort = 1 \gset
select public.quote_fingerprint(:'site2') as site2_v \gset
select tpo_co.check(tpo_co.hub_signs_for(:'co', :'site2', :'site2_metal', :'site2_v'), 'a customer signs for the other option from the current page, without the total');
select tpo_co.check((select status = 'approved' and option_id = :'site2_metal' and total = 4000
                       and approval ->> 'seen_fingerprint' = :'site2_v' and approval ->> 'fingerprint' = public.quote_fingerprint(id)
                       and approval -> 'choices' ->> 'option_id' = :'site2_metal' and (approval -> 'choices' ->> 'total')::numeric = 4000
                       and not exists (select 1 from public.quote_line_items l where l.quote_id = :'site2' and l.name = 'Price adjustment')
                     from public.quotes where id = :'site2'),
  'signed for the option they chose at its price, the price set on site for the other gone, the version kept as signed');
select public.convert_quote_to_job(:'site2') as site2_job \gset
select tpo_co.check((select status from public.quotes where id = :'site2') = 'converted', 'and it becomes a job');
-- For the option shown, at the price set on site: on their link, and in person, without the total.
select tpo_co.site_priced(:'co', :'client', 'Porch roof') as site3 \gset
select id as site3_shingles from public.quote_options where quote_id = :'site3' and sort = 0 \gset
select tpo_co.check(tpo_co.hub_signs_for(:'co', :'site3', :'site3_shingles', public.quote_fingerprint(:'site3')), 'a customer signs for the option shown at the price set on site, on their link');
select tpo_co.check((select status = 'approved' and total = 1850 and (approval ->> 'total')::numeric = 1850 from public.quotes where id = :'site3'), 'at $1,850');
select tpo_co.site_priced(:'co', :'client', 'Deck roof') as site4 \gset
select id as site4_shingles from public.quote_options where quote_id = :'site4' and sort = 0 \gset
select tpo_co.in_person_signs_for(:'site4', :'site4_shingles', public.quote_fingerprint(:'site4')) is not null as signed \gset
select tpo_co.check((select status = 'approved' and total = 1850 and approval ->> 'fingerprint' = public.quote_fingerprint(id) from public.quotes where id = :'site4'),
  'and in person, without the total');
-- A choice the office makes isn't the customer's: switching the shown option takes the price set on
-- site off, and a page from before can't sign.
select tpo_co.site_priced(:'co', :'client', 'Shed roof') as site5 \gset
select id as site5_metal from public.quote_options where quote_id = :'site5' and sort = 1 \gset
select public.quote_fingerprint(:'site5') as site5_v \gset
update public.quotes set option_id = :'site5_metal' where id = :'site5';
select tpo_co.expect_error(format('select tpo_co.hub_signs_for(%L, %L, %L, %L)', :'co', :'site5', :'site5_metal', :'site5_v'),
  'the office showing the other option (which takes the price set on site off) makes an open page outdated', '%changed after it was opened%');
select tpo_co.expect_error(format('select tpo_co.in_person_signs_for(%L, %L, %L)', :'site5', :'site5_metal', :'site5_v'),
  'in person too', '%changed after it was opened%');

-- ===== Deleting the job or the company still works =============================================
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Other job quote') returning id as q2 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'q2', 'Other', 1, 'ea', 100);
select public.convert_quote_to_job(planet_test.sign(:'q2')) as job2 \gset
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: other', :'job2') returning id as co2 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co2', 'Extra', 1, 'ea', 100);
select planet_test.sign(:'co2');
delete from public.jobs where id = :'job2';
select tpo_co.check((select change_order_for is null and status = 'converted' from public.quotes where id = :'co2'), 'deleting its job leaves the signed change order, unlinked');
delete from public.companies where id = :'co';
select tpo_co.check(not exists (select 1 from public.quotes where company_id = :'co'), 'deleting the company removes its signed agreements too');
\o
\echo 'All Planet Ops signature tests passed.'
