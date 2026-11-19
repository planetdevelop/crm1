-- Planet Ops Phase 1: customer acceptance is tied to the complete document version, only the customer
-- signs, and a change order is finalized only with the customer's signature on its exact current
-- version; once signed it stays as signed (20261120000100_planet_ops_change_order_signature.sql).
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
-- The customer signs on their link, from a page that showed the version with this fingerprint.
create function tpo_co.customer_signs(p_company uuid, p_quote uuid, p_seen text) returns boolean language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'signature', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'ip', '203.0.113.5', 'seen_fingerprint', p_seen))
$$;
grant execute on all functions in schema tpo_co to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0c00000-0000-0000-0000-000000000001', 'owner@planet.test', '{"full_name": "Test Owner"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Sample Customer') returning id as client \gset
insert into public.contract_sections (company_id, title, body) values (:'co', 'Contract Terms', 'TEST placeholder contract terms.') returning id as terms \gset
insert into public.contract_sections (company_id, title, body) values (:'co', 'Payment Terms', 'TEST placeholder payment terms.') returning id as payment \gset
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'House demolition') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 18000);
select public.convert_quote_to_job(:'quote') as job \gset

-- An added charge, sent to the customer.
insert into public.quotes (company_id, client_id, title, change_order_for, section_ids) values (:'co', :'client', 'Change order: remove garage slab', :'job', array[:'terms', :'payment']::uuid[]) returning id as add \gset
insert into public.quote_line_items (company_id, quote_id, name, description, quantity, unit, unit_price) values (:'co', :'add', 'Remove garage slab', 'Break out and haul the 20x20 slab', 1, 'ea', 2500) returning id as add_line \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'add';
commit;

-- ===== The office can't finalize it, nor fake the customer's signature ==========================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'add'),
  'the office can''t mark an unsigned change order approved', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = ''{"name": "Test Owner", "method": "manual"}'' where id = %L', :'add'),
  'nor with a manual approval in its own name', '%customer signs this exact version%');
select tpo_co.expect_error(format('select public.convert_quote_to_job(%L)', :'add'),
  'converting an unsigned change order is refused too', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''converted'', converted_at = now() where id = %L', :'add'),
  'and so is marking it added to the job', '%customer signs this exact version%');
select tpo_co.expect_error(format('insert into public.quotes (company_id, client_id, title, status, change_order_for) values (%L, %L, ''Sneaky'', ''converted'', %L)', :'co', :'client', :'job'),
  'a change order can''t be inserted already finalized', '%customer signs this exact version%');
-- Fabricated signature metadata: a customer-looking approval, with or without the right total and
-- fingerprint, written by someone signed in, is refused whether or not it finalizes anything.
select tpo_co.expect_error(format('update public.quotes set approval = jsonb_build_object(''name'', ''Test Customer'', ''signed_at'', now(), ''signature'', ''data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='', ''total'', total, ''method'', ''in_person'', ''seen_fingerprint'', public.quote_fingerprint(id)) where id = %L', :'add'),
  'staff can''t write a customer signature into the quote', '%Only the customer can sign%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now(), approval = jsonb_build_object(''name'', ''Test Customer'', ''signed_at'', now(), ''signature'', ''data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='', ''total'', total, ''seen_fingerprint'', public.quote_fingerprint(id)) where id = %L', :'add'),
  'nor approve it with one', '%Only the customer can sign%');
select tpo_co.expect_error(format('select public.sign_quote(%L, ''{"name": "Test Customer", "method": "in_person", "signed_at": "2026-11-20T15:00:00Z"}'')', :'add'),
  'nor call the in-person signing step directly', '%permission denied%');
select tpo_co.check((select status from public.quotes where id = :'add') = 'sent', 'it''s still waiting for the customer');
select tpo_co.check((select approval from public.quotes where id = :'add') is null, 'with no approval on it');
select tpo_co.check(not exists (select 1 from public.job_line_items where source_quote_id = :'add'), 'and nothing was added to the job');
-- Members get the fingerprint for their own quotes only, the signing screen's.
select tpo_co.check(public.quote_fingerprint(:'add') ~ '^[0-9a-f]{32}$', 'a member can read the version fingerprint of their own change order (the signing screen''s)');
commit;

-- ===== Only a drawn signature signs: a typed name alone never does ============================
select tpo_co.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now(), %L, public.quote_fingerprint(%L)))', :'co', :'add', '{}', 'name', 'Test Customer', 'signed_at', 'seen_fingerprint', :'add'),
  'a change order can''t be signed with a typed name alone', '%drawn signature is needed%');
select tpo_co.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now(), %L, %L, %L, public.quote_fingerprint(%L)))', :'co', :'add', '{}', 'name', 'Test Customer', 'signed_at', 'signature', 'Test Customer', 'seen_fingerprint', :'add'),
  'nor with words where the drawing goes', '%drawn signature is needed%');
select tpo_co.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now(), %L, %L, %L, public.quote_fingerprint(%L)))', :'co', :'add', '{}', 'name', 'Test Customer', 'signed_at', 'signature', 'data:image/jpeg;base64,/9j/4AAQ', 'seen_fingerprint', :'add'),
  'nor with a picture that isn''t a drawn signature', '%drawn signature is needed%');
select tpo_co.check(private.is_customer_signature(jsonb_build_object('name', 'A', 'signed_at', '2026-11-20T15:00:00Z', 'signature', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='))
                and not private.is_customer_signature('{"name": "A", "signed_at": "2026-11-20T15:00:00Z"}')
                and not private.is_customer_signature(jsonb_build_object('signed_at', '2026-11-20T15:00:00Z', 'signature', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='))
                and not private.is_customer_signature(jsonb_build_object('name', 'A', 'signature', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=')),
  'a customer signature is the printed name, the signing time and the drawing, each needed');
select tpo_co.check((select status from public.quotes where id = :'add') = 'sent', 'the change order is still unsigned');

-- ===== Acceptance is tied to the whole document version, not just its total ===================
select public.quote_fingerprint(:'add') as v1 \gset
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, null)', :'co', :'add'),
  'a change order can''t be signed without saying which version the page showed', '%page showing its exact version%');

-- Same price, different scope.
update public.quote_line_items set description = 'Break out and haul the 20x20 slab and the walkway' where id = :'add_line';
select tpo_co.check((select total from public.quotes where id = :'add') = 2500, 'a scope change at the same price');
select tpo_co.check(public.quote_fingerprint(:'add') <> :'v1', 'is a new version');
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v1'),
  'so a page opened before it can''t sign', '%changed after it was opened%');
select public.quote_fingerprint(:'add') as v2 \gset

-- A schedule change.
update public.quotes set starts_on = current_date + 14 where id = :'add';
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v2'),
  'a schedule change makes an open page outdated too', '%changed after it was opened%');
select public.quote_fingerprint(:'add') as v3 \gset

-- Payment terms: the deposit, and the payment terms' wording.
update public.quotes set deposit_amount = 500 where id = :'add';
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v3'),
  'so does a payment-term change (the deposit)', '%changed after it was opened%');
select public.quote_fingerprint(:'add') as v4 \gset
update public.contract_sections set body = 'TEST placeholder payment terms, revised.' where id = :'payment';
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v4'),
  'and the payment terms'' wording', '%changed after it was opened%');
select public.quote_fingerprint(:'add') as v5 \gset

-- Contract terms: their wording, and which sections apply.
update public.contract_sections set body = 'TEST placeholder contract terms, revised.' where id = :'terms';
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v5'),
  'a contract-term change makes it outdated', '%changed after it was opened%');
select public.quote_fingerprint(:'add') as v6 \gset
update public.quotes set section_ids = array[:'terms']::uuid[] where id = :'add';
select tpo_co.expect_error(format('select tpo_co.customer_signs(%L, %L, %L)', :'co', :'add', :'v6'),
  'so does taking a section off', '%changed after it was opened%');
update public.quotes set section_ids = array[:'terms', :'payment']::uuid[] where id = :'add';
select tpo_co.check(public.quote_fingerprint(:'add') = :'v6', 'putting it back is that version again');
select tpo_co.check((select status from public.quotes where id = :'add') = 'sent' and not exists (select 1 from public.job_line_items where source_quote_id = :'add'),
  'none of the outdated pages signed or added anything');

-- ===== The customer signs the version they saw: finalized once, kept as signed ================
select tpo_co.check(tpo_co.customer_signs(:'co', :'add', :'v6'), 'the customer signs from a page showing this version');
select tpo_co.check((select status from public.quotes where id = :'add') = 'converted', 'it''s finalized and added to the job');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add' and unit_price = 2500) = 1, 'its line is on the job once');
select tpo_co.check((select approval ->> 'fingerprint' = :'v6' and approval -> 'document' -> 'lines' -> 0 ->> 'description' = 'Break out and haul the 20x20 slab and the walkway'
                       and approval -> 'document' -> 'sections' @> '[{"body": "TEST placeholder contract terms, revised."}]'
                     from public.quotes where id = :'add'), 'the approval keeps the signed version: its fingerprint, lines and terms');
select tpo_co.check(not tpo_co.customer_signs(:'co', :'add', :'v6'), 'a repeated signature does nothing');
select tpo_co.check((select count(*) from public.job_line_items where source_quote_id = :'add') = 1, 'and adds nothing twice');

-- The signed agreement is preserved: not re-opened, moved, deleted, re-signed or edited.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''sent'' where id = %L', :'add'), 'a signed change order can''t be re-opened', '%stays as signed%');
select tpo_co.expect_error(format('update public.quotes set status = ''draft'' where id = %L', :'add'), 'nor put back to a draft', '%stays as signed%');
select tpo_co.expect_error(format('update public.quotes set status = ''archived'' where id = %L', :'add'), 'nor archived', '%stays as signed%');
select tpo_co.expect_error(format('delete from public.quotes where id = %L', :'add'), 'nor deleted');
select tpo_co.expect_error(format('update public.quote_line_items set unit_price = 1 where id = %L', :'add_line'), 'its signed price can''t change');
select tpo_co.expect_error(format('update public.quote_line_items set description = ''something else'' where id = %L', :'add_line'), 'nor its signed scope');
select tpo_co.expect_error(format('insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (%L, %L, ''Extra'', 1, ''ea'', 10)', :'co', :'add'), 'nor can lines be added to it');
select tpo_co.expect_error(format('update public.quotes set approval = approval || ''{"name": "Someone Else"}'' where id = %L', :'add'), 'its signature can''t be rewritten');
select tpo_co.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(''fingerprint'', ''0'') where id = %L', :'add'), 'nor the version it was signed for');
commit;
select tpo_co.expect_error(format('update public.quotes set status = ''sent'' where id = %L', :'add'), 'not even by the server', '%stays as signed%');
select tpo_co.check((select status = 'converted' and approval ->> 'name' = 'Test Customer' from public.quotes where id = :'add'), 'it''s still the agreement the customer signed');

-- ===== Credits and $0 changes need the signature too ===========================================
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: leave the shed', :'job') returning id as credit \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'credit', 'Leave the shed standing (credit)', 1, 'ea', -800);
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: start a week later', :'job') returning id as zero \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'zero', 'Start date moves one week later', 1, 'ea', 0);
update public.quotes set status = 'sent', sent_at = now() where id in (:'credit', :'zero');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'credit'), 'an unsigned credit isn''t finalized', '%customer signs this exact version%');
select tpo_co.expect_error(format('update public.quotes set status = ''approved'', approved_at = now() where id = %L', :'zero'), 'nor an unsigned $0 change', '%customer signs this exact version%');
commit;
select tpo_co.check(tpo_co.customer_signs(:'co', :'credit', public.quote_fingerprint(:'credit')), 'the customer signs the credit');
select tpo_co.check(tpo_co.customer_signs(:'co', :'zero', public.quote_fingerprint(:'zero')), 'and the $0 change');
select tpo_co.check((select coalesce(sum(round(quantity * unit_price, 2)), 0) from public.job_line_items where job_id = :'job') = 18000 + 2500 - 800,
  'the job is the original agreement plus the signed changes, credit included, each once');

-- ===== An ordinary quote: the office's manual approval and countersignature still work =========
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Shed demolition') returning id as shed \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'shed', 'Demolish shed', 1, 'ea', 1500);
update public.quotes set status = 'approved', approved_at = now(), approval = '{"name": "Test Owner", "method": "manual"}' where id = :'shed';
select tpo_co.check((select status from public.quotes where id = :'shed') = 'approved', 'a quote (not a change order) can still be marked approved by the office');
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Fence removal') returning id as fence \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'fence', 'Remove fence', 1, 'ea', 900);
update public.quotes set status = 'sent', sent_at = now() where id = :'fence';
commit;
select tpo_co.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now()))', :'co', :'fence', '{}', 'name', 'Test Customer', 'signed_at'),
  'an ordinary quote can''t be accepted with a typed name alone either', '%drawn signature is needed%');
select tpo_co.check(tpo_co.customer_signs(:'co', :'fence', public.quote_fingerprint(:'fence')), 'the customer signs a quote on their link, drawing their signature');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0c00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.quotes set approval = approval || '{"company": {"name": "Test Owner", "signature": "data:image/png;base64,AAAA"}}' where id = :'fence';
select tpo_co.check((select approval -> 'company' ->> 'name' = 'Test Owner' and approval ->> 'name' = 'Test Customer' from public.quotes where id = :'fence'), 'and the business countersigns under it');
commit;

-- ===== Deleting the job or the company still works =============================================
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Other job') returning id as job2 \gset
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'Change order: other', :'job2') returning id as co2 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co2', 'Extra', 1, 'ea', 100);
update public.quotes set status = 'sent', sent_at = now() where id = :'co2';
select tpo_co.check(tpo_co.customer_signs(:'co', :'co2', public.quote_fingerprint(:'co2')), 'a change order on another job is signed');
delete from public.jobs where id = :'job2';
select tpo_co.check((select change_order_for is null and status = 'converted' from public.quotes where id = :'co2'), 'deleting its job leaves the signed change order, unlinked');

delete from public.companies where id = :'co';
select tpo_co.check(not exists (select 1 from public.quotes where company_id = :'co'), 'deleting the company removes its signed change orders too');
\o
\echo 'All Planet Ops change-order signature tests passed.'
