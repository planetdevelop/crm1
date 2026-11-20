-- Planet Ops Phase 1c: document versions and customer change requests
-- (20261121000100_planet_ops_document_versions.sql). Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_dv;
grant usage on schema tpo_dv to authenticated, service_role;
create function tpo_dv.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_dv.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- The customer signs on their link, from a page that showed version p_seen (approve_hub_quote, as the server calls it).
create function tpo_dv.hub_signs(p_company uuid, p_quote uuid, p_seen text) returns boolean language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'signature', planet_test.drawn(), 'seen_fingerprint', p_seen))
$$;
-- And in person (sign_quote, as the API calls it).
create function tpo_dv.in_person_signs(p_quote uuid, p_seen text) returns jsonb language plpgsql security definer as $fn$
declare v_claims text := current_setting('request.jwt.claims', true); v jsonb;
begin
  perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
  v := public.sign_quote(p_quote, jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'method', 'in_person',
                                                     'signature', planet_test.drawn(), 'seen_fingerprint', p_seen));
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return v;
end $fn$;
-- "Request changes" on the customer's link (request_quote_changes, as the server calls it).
create function tpo_dv.asks(p_company uuid, p_quote uuid, p_message text, p_key uuid, p_seen text) returns jsonb language sql as $$
  select public.request_quote_changes(p_company, p_quote, p_message, p_key, p_seen, '{"link": "own", "ip": "203.0.113.5"}')
$$;
grant execute on all functions in schema tpo_dv to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0e00000-0000-0000-0000-000000000001', 'owner@planet-dv.test', '{"full_name": "Test Owner"}'),
  ('a0e00000-0000-0000-0000-000000000002', 'estimator@planet-dv.test', '{"full_name": "Test Estimator"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0e00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition DV', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Versions Customer') returning id as client \gset
commit;
insert into public.memberships (company_id, user_id, role, active) values (:'co', 'a0e00000-0000-0000-0000-000000000002', 'estimator', true);
update public.companies set settings = settings || '{"quotes": {"contract_terms": "TEST placeholder contract terms.", "payment_terms": "TEST placeholder payment terms."}}' where id = :'co';

-- A line-item quote, owned by the estimator, sent to the customer.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0e00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.quotes (company_id, client_id, title, salesperson_id) values (:'co', :'client', 'House demolition', 'a0e00000-0000-0000-0000-000000000002') returning id as quote \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 18000);
select tpo_dv.check(not exists (select 1 from public.quote_versions where quote_id = :'quote'), 'a draft has no issued version');
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
commit;

-- ===== Sending issues version 1, kept as issued ==============================================
select tpo_dv.check((select count(*) = 1 and bool_and(number = 1 and issued_via = 'sent' and superseded_at is null and signed_at is null
                       and fingerprint = public.quote_fingerprint(:'quote') and total = 18000
                       and document -> 'quote' ->> 'contract_terms' = 'TEST placeholder contract terms.')
                     from public.quote_versions where quote_id = :'quote'),
  'sending issues version 1: the whole document, its fingerprint and total, as sent');
select fingerprint as v1 from public.quote_versions where quote_id = :'quote' and number = 1 \gset
select id as v1_id from public.quote_versions where quote_id = :'quote' and number = 1 \gset
-- The company's defaults change: what was issued doesn't.
update public.companies set settings = jsonb_set(settings, '{quotes,contract_terms}', '"TEST placeholder contract terms, newer."') where id = :'co';
select tpo_dv.check((select document -> 'quote' ->> 'contract_terms' from public.quote_versions where id = :'v1_id') = 'TEST placeholder contract terms.',
  'a later change to the company''s default terms doesn''t change an issued version');
-- Nobody edits or deletes an issued version, or makes one up.
select tpo_dv.expect_error(format('update public.quote_versions set total = 1 where id = %L', :'v1_id'), 'an issued version can''t be edited', '%kept as issued%');
select tpo_dv.expect_error(format('delete from public.quote_versions where id = %L', :'v1_id'), 'or deleted', '%kept as issued%');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0e00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_dv.expect_error(format('insert into public.quote_versions (company_id, quote_id, number, fingerprint, document, issued_via) values (%L, %L, 9, %L, %L, %L)', :'co', :'quote', :'v1', '{}', 'sent'),
  'or made up by someone signed in');
select tpo_dv.check((select count(*) from public.quote_versions where quote_id = :'quote') = 1, 'the office reads the versions');
commit;

-- ===== Editing an issued document makes a draft revision; nothing is sent ====================
update public.quote_line_items set description = 'Down to the slab, footings out' where quote_id = :'quote';
select public.quote_fingerprint(:'quote') as draft_fp \gset
select tpo_dv.check(:'draft_fp' <> :'v1' and (select count(*) from public.quote_versions where quote_id = :'quote') = 1
                    and (select status from public.quotes where id = :'quote') = 'sent',
  'editing a sent quote makes a draft revision: no new version is issued, and it isn''t sent');
select tpo_dv.expect_error(format('select tpo_dv.hub_signs(%L, %L, %L)', :'co', :'quote', :'draft_fp'),
  'the customer''s link can''t sign the unsent draft revision', '%isn''t the version that was sent to you%');
select tpo_dv.expect_error(format('select tpo_dv.hub_signs(%L, %L, %L)', :'co', :'quote', :'v1'),
  'nor the version it showed, which has changed since', '%changed after it was opened%');

-- ===== Issuing the revision supersedes version 1 ==============================================
select public.issue_quote_version(:'quote') as v2_id \gset
select tpo_dv.check((select number = 2 and fingerprint = :'draft_fp' and superseded_at is null from public.quote_versions where id = :'v2_id')
                    and (select superseded_at is not null and superseded_by = :'v2_id' from public.quote_versions where id = :'v1_id'),
  'sending the revision issues version 2 and supersedes version 1');
select tpo_dv.check(public.issue_quote_version(:'quote') = :'v2_id' and (select count(*) from public.quote_versions where quote_id = :'quote') = 2,
  'sending it again unchanged issues no new version');
select tpo_dv.expect_error(format('select tpo_dv.hub_signs(%L, %L, %L)', :'co', :'quote', :'v1'),
  'the superseded version 1 can''t be signed', '%changed after it was opened%');

-- ===== Request changes on a line-item quote ===================================================
select tpo_dv.asks(:'co', :'quote', 'Could you leave the detached garage standing?  Thanks!', 'b0000000-0000-4000-8000-000000000001', :'draft_fp') as req1 \gset
select tpo_dv.check((:'req1'::jsonb ->> 'status') = 'changes_requested' and (:'req1'::jsonb ->> 'duplicate')::boolean = false, 'the customer asks for changes');
select (:'req1'::jsonb ->> 'id') as req1_id \gset
select tpo_dv.check((select message = 'Could you leave the detached garage standing?  Thanks!' and version_id = :'v2_id' and version_number = 2
                       and seen_fingerprint = :'draft_fp' and client_id = :'client' and identity ->> 'link' = 'own'
                       and created_at > now() - interval '1 hour' and not signed_agreement and resolved_at is null
                     from public.quote_change_requests where id = :'req1_id'),
  'the note is kept exactly as typed, with the customer, the server''s time and the exact version reviewed (2)');
select tpo_dv.check((select status from public.quotes where id = :'quote') = 'changes_requested' and (select total from public.quotes where id = :'quote') = 18000,
  'the quote is marked "Changes requested"; the note changes nothing in it');
select tpo_dv.check((select count(*) = 1 and bool_and(assigned_to = 'a0e00000-0000-0000-0000-000000000002' and done_at is null and link = '/quotes/' || :'quote')
                     from public.follow_up_tasks where source = 'change_request' and source_id = :'req1_id'),
  'a follow-up task for the quote''s salesperson');
select tpo_dv.check(exists (select 1 from public.notifications where user_id = 'a0e00000-0000-0000-0000-000000000002' and company_id = :'co'
                              and title like 'Changes requested on quote #%' and body like 'Could you leave%'),
  'and a notification to them in the app');
-- The same request again (a retry, a double tap): one request, one task.
select tpo_dv.asks(:'co', :'quote', 'Could you leave the detached garage standing?  Thanks!', 'b0000000-0000-4000-8000-000000000001', :'draft_fp') as again \gset
select tpo_dv.check((:'again'::jsonb ->> 'duplicate')::boolean and (:'again'::jsonb ->> 'id') = :'req1_id'
                    and (select count(*) from public.quote_change_requests where quote_id = :'quote') = 1
                    and (select count(*) from public.follow_up_tasks where source = 'change_request' and related_id = :'quote') = 1,
  'a retried request is the same request, with one follow-up');
-- Signing is paused, on the link and in person.
select tpo_dv.expect_error(format('select tpo_dv.hub_signs(%L, %L, %L)', :'co', :'quote', :'draft_fp'),
  'signing is paused on the link after changes are requested', '%signing is paused%');
select tpo_dv.expect_error(format('select tpo_dv.in_person_signs(%L, %L)', :'quote', :'draft_fp'),
  'and in person', '%signing is paused%');
-- A second request is kept too.
select tpo_dv.asks(:'co', :'quote', 'Also, can you start after the 15th?', 'b0000000-0000-4000-8000-000000000002', :'draft_fp') as req2 \gset
select tpo_dv.check((select count(*) from public.quote_change_requests where quote_id = :'quote') = 2, 'a second request is kept as well');
-- A promo code the customer applies on their link issues the quote as it now is ('promo'), and
-- answers no change request: signing stays paused.
select public.issue_quote_version(:'quote', 'promo') is not null as promo \gset
select tpo_dv.check((select status from public.quotes where id = :'quote') = 'changes_requested'
                    and (select count(*) from public.quote_change_requests where quote_id = :'quote' and resolved_at is null) = 2,
  'a customer''s promo code leaves the change requests open and signing paused');
-- Only the server records a request; nobody signed in writes or rewrites one.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0e00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_dv.expect_error(format('select public.request_quote_changes(%L, %L, %L, %L, %L)', :'co', :'quote', 'from staff', 'b0000000-0000-4000-8000-000000000009', :'draft_fp'),
  'staff can''t file a request for the customer', '%permission denied%');
update public.quote_change_requests set message = 'edited' where id = :'req1_id';
select tpo_dv.check((select message from public.quote_change_requests where id = :'req1_id') like 'Could you leave%', 'nor edit what the customer wrote');
-- The office replies.
select public.respond_to_change_request(:'req1_id', 'Yes: we''ll keep the garage. Updated quote coming.');
select tpo_dv.expect_error(format('select public.respond_to_change_request(%L, %L)', :'req1_id', 'again'), 'one reply per request', '%already has a reply%');
commit;
select tpo_dv.check((select response like 'Yes: we''ll keep the garage%' and responded_by = 'a0e00000-0000-0000-0000-000000000001' and resolved_at is null
                     from public.quote_change_requests where id = :'req1_id'),
  'the office''s reply is kept beside the note; the request stays open until a version is sent');

-- The office prepares the revision, then deliberately sends it: version 3, the requests answered.
update public.quote_line_items set unit_price = 16500, description = 'House only; the detached garage stays' where quote_id = :'quote';
select tpo_dv.check((select status from public.quotes where id = :'quote') = 'changes_requested', 'preparing the revision sends nothing');
select public.issue_quote_version(:'quote') as v3_id \gset
select tpo_dv.check((select status from public.quotes where id = :'quote') = 'sent'
                    and (select number from public.quote_versions where id = :'v3_id') = 3
                    and (select superseded_by from public.quote_versions where id = :'v2_id') = :'v3_id'
                    and not exists (select 1 from public.quote_change_requests where quote_id = :'quote' and resolved_at is null)
                    and (select bool_and(resolved_version_id = :'v3_id') from public.quote_change_requests where quote_id = :'quote')
                    and not exists (select 1 from public.follow_up_tasks where related_id = :'quote' and done_at is null),
  'sending the revision issues version 3, answers both requests and closes their follow-up');
select fingerprint as v3 from public.quote_versions where id = :'v3_id' \gset
select tpo_dv.expect_error(format('select tpo_dv.hub_signs(%L, %L, %L)', :'co', :'quote', :'draft_fp'), 'version 2 can''t be signed now', '%changed after it was opened%');
select tpo_dv.check(tpo_dv.hub_signs(:'co', :'quote', :'v3'), 'the customer signs version 3 on their link');
select tpo_dv.check((select status = 'approved' and (approval ->> 'version_id') = :'v3_id' and (approval ->> 'version_number')::int = 3 and (approval ->> 'total')::numeric = 16500
                     from public.quotes where id = :'quote')
                    and (select signed_at is not null from public.quote_versions where id = :'v3_id'),
  'the signature records version 3, and version 3 that it was signed');
select tpo_dv.check((select string_agg(number || ':' || (superseded_at is not null)::text || ':' || (signed_at is not null)::text || ':' || total, ',' order by number)
                     from public.quote_versions where quote_id = :'quote') = '1:true:false:18000.00,2:true:false:18000.00,3:false:true:16500.00',
  'every version is kept: 1 and 2 superseded as sent, 3 signed');

-- ===== Request changes on a proposal, and in-person signing of a revision =====================
insert into public.quotes (company_id, client_id, title, presentation, narrative, salesperson_id) values
  (:'co', :'client', 'Barn removal proposal', 'proposal', '{"overview": "TEST barn", "scope": "1. Demolish\n2. Haul"}', 'a0e00000-0000-0000-0000-000000000002') returning id as prop \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'prop', 'Demolish barn', 1, 'ea', 9000);
update public.quotes set status = 'sent', sent_at = now() where id = :'prop';
select fingerprint as p1 from public.quote_versions where quote_id = :'prop' and number = 1 \gset
select tpo_dv.check((select presentation = 'proposal' and document -> 'quote' -> 'narrative' ->> 'overview' = 'TEST barn' from public.quote_versions where quote_id = :'prop' and number = 1),
  'a proposal''s version keeps its layout and narrative');
select tpo_dv.asks(:'co', :'prop', 'Please add removing the silo.', 'b0000000-0000-4000-8000-000000000003', :'p1') as preq \gset
select tpo_dv.check((select status from public.quotes where id = :'prop') = 'changes_requested'
                    and (select version_number from public.quote_change_requests where id = (:'preq'::jsonb ->> 'id')::uuid) = 1
                    and exists (select 1 from public.follow_up_tasks where source_id = (:'preq'::jsonb ->> 'id')::uuid and title like 'Review the change request on proposal #%'),
  'a proposal takes a change request the same way, labelled a proposal');
update public.quotes set narrative = narrative || '{"inclusions": "Silo removal"}' where id = :'prop';
select tpo_dv.expect_error(format('select tpo_dv.in_person_signs(%L, %L)', :'prop', public.quote_fingerprint(:'prop')),
  'in person, signing still waits while changes are requested', '%signing is paused%');
select public.issue_quote_version(:'prop') as p2_id \gset
update public.quotes set narrative = narrative || '{"assumptions": "Clear access"}' where id = :'prop';
select tpo_dv.check(tpo_dv.in_person_signs(:'prop', public.quote_fingerprint(:'prop')) is not null, 'signed in person on the screen as it is now');
select tpo_dv.check((select (approval ->> 'version_number')::int = 3 and approval ->> 'method' = 'in_person' from public.quotes where id = :'prop')
                    and (select issued_via = 'in_person' and signed_at is not null from public.quote_versions where quote_id = :'prop' and number = 3)
                    and (select superseded_at is not null from public.quote_versions where id = :'p2_id'),
  'in person, the screen''s document is issued as version 3 and signed; version 2 is superseded');

-- ===== Request changes on a change order ======================================================
select public.convert_quote_to_job(:'quote') as job \gset
insert into public.quotes (company_id, client_id, title, change_order_for, salesperson_id) values (:'co', :'client', 'CO: driveway', :'job', 'a0e00000-0000-0000-0000-000000000002') returning id as co1 \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co1', 'Remove driveway', 1, 'ea', 2400);
update public.quotes set status = 'sent', sent_at = now() where id = :'co1';
select tpo_dv.asks(:'co', :'co1', 'Only the front half of the driveway.', 'b0000000-0000-4000-8000-000000000004', (select fingerprint from public.quote_versions where quote_id = :'co1' and number = 1)) as coreq \gset
select tpo_dv.check((select status from public.quotes where id = :'co1') = 'changes_requested'
                    and not exists (select 1 from public.job_line_items where source_quote_id = :'co1')
                    and exists (select 1 from public.follow_up_tasks where source_id = (:'coreq'::jsonb ->> 'id')::uuid and title like 'Review the change request on change order #%'),
  'a change order takes a change request too, and nothing joins the job');

-- ===== A request on a signed agreement: kept as signed, routed into a proposed change order ===
select approval as signed_before from public.quotes where id = :'quote' \gset
select tpo_dv.asks(:'co', :'quote', 'We''d also like the shed removed.', 'b0000000-0000-4000-8000-000000000005', null) as sreq \gset
select tpo_dv.check((select status from public.quotes where id = :'quote') = 'converted'
                    and (select approval from public.quotes where id = :'quote') = :'signed_before'::jsonb,
  'a request on the signed agreement doesn''t reopen or change it');
select tpo_dv.check((select signed_agreement and version_id = :'v3_id' and proposed_change_order_id is not null from public.quote_change_requests where id = (:'sreq'::jsonb ->> 'id')::uuid),
  'it''s logged against the signed version 3, with a proposed change order');
select tpo_dv.check((select status = 'draft' and change_order_for = :'job' and title like 'Change requested: %'
                     from public.quotes where id = (:'sreq'::jsonb ->> 'change_order_id')::uuid),
  'the proposed change order is a draft on the job, for the office to price and send');
select tpo_dv.check(exists (select 1 from public.follow_up_tasks where source_id = (:'sreq'::jsonb ->> 'id')::uuid and title like 'Customer asked for a change to signed quote #%'),
  'with its own follow-up');
select tpo_dv.check((select count(*) from public.job_line_items where job_id = :'job') = 1, 'the job''s scope is unchanged by the note');

-- A document that isn't with the customer takes no request.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Draft only') returning id as draft \gset
select tpo_dv.expect_error(format('select tpo_dv.asks(%L, %L, %L, %L, null)', :'co', :'draft', 'hello there', 'b0000000-0000-4000-8000-000000000006'),
  'a draft takes no change request', '%isn''t open for changes%');

-- The company is kept: sub_isolation_test.sql sweeps these tables with rows in them.
\o
\echo 'All Planet Ops document versions tests passed.'
