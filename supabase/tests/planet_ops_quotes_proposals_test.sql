-- Planet Ops Phase 1b: quote and proposal layouts on one record, separate Contract Terms and Payment
-- Terms filled from the company's defaults, and a configurable company countersignature
-- (20261120000200_planet_ops_quotes_and_proposals.sql). Run with scripts/test-db.sh.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_qp;
grant usage on schema tpo_qp to authenticated, service_role;
create function tpo_qp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_qp.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- The customer signs on their link (approve_hub_quote, as the server calls it), from a page showing
-- the version with fingerprint p_seen (by default, the version as it is now).
create function tpo_qp.customer_signs(p_company uuid, p_quote uuid, p_seen text default null) returns boolean language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'signature', planet_test.drawn(),
                       'seen_fingerprint', coalesce(p_seen, public.quote_fingerprint(p_quote))))
$$;
-- The customer signs in person (sign_quote, as the API calls it once it has checked the seller),
-- with the company's countersignature given in the same step when p_company is set.
create function tpo_qp.in_person_signs(p_quote uuid, p_seen text default null, p_company jsonb default null) returns jsonb
language plpgsql security definer as $fn$
declare v_claims text := current_setting('request.jwt.claims', true); v jsonb;
begin
  perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
  v := public.sign_quote(p_quote, jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'method', 'in_person', 'signature', planet_test.drawn(),
                                                     'seen_fingerprint', coalesce(p_seen, public.quote_fingerprint(p_quote)))
                                  || case when p_company is null then '{}' else jsonb_build_object('company', p_company) end);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return v;
end $fn$;
-- A countersignature as the office's countersign step writes it: the signer's own, chosen on purpose.
create function tpo_qp.countersignature(p_method text default 'drawn', p_user uuid default 'a0d00000-0000-0000-0000-000000000001') returns jsonb language sql as $$
  select jsonb_build_object('name', 'Test Owner', 'user_id', p_user, 'method', p_method, 'signature', planet_test.drawn(), 'signed_at', '2000-01-01T00:00:00Z')
$$;
grant execute on all functions in schema tpo_qp to authenticated, service_role;
\set one_pixel 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0d00000-0000-0000-0000-000000000001', 'owner@planet-qp.test', '{"full_name": "Test Owner"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition QP', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Proposal Customer') returning id as client \gset
commit;

-- ===== Contract Terms and Payment Terms ========================================================
-- Until the company saves its approved wording, new quotes get clearly marked placeholders.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Before the wording') returning id as early \gset
select tpo_qp.check((select contract_terms like '[PLACEHOLDER] Contract Terms:%' and payment_terms like '[PLACEHOLDER] Payment Terms:%' from public.quotes where id = :'early'),
  'until the company saves its own, a new quote starts with clearly marked placeholder Contract Terms and Payment Terms');
commit;

update public.companies set settings = settings || '{"quotes": {"contract_terms": "TEST placeholder contract terms.", "payment_terms": "TEST placeholder payment terms."}}' where id = :'co';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'House demolition') returning id as quote \gset
select tpo_qp.check((select contract_terms = 'TEST placeholder contract terms.' and payment_terms = 'TEST placeholder payment terms.' from public.quotes where id = :'quote'),
  'a new quote starts with the company''s Contract Terms and Payment Terms, as separate sections');
update public.quotes set payment_terms = 'TEST placeholder payment terms, edited for this job.' where id = :'quote';
select tpo_qp.check((select contract_terms = 'TEST placeholder contract terms.' and payment_terms like '%edited for this job%' from public.quotes where id = :'quote'),
  'each is edited for the job on its own');
insert into public.quotes (company_id, client_id, title, contract_terms) values (:'co', :'client', 'Typed terms', 'TEST typed') returning id as typed \gset
select tpo_qp.check((select contract_terms = 'TEST typed' and payment_terms = 'TEST placeholder payment terms.' from public.quotes where id = :'typed'), 'terms given when it''s made are kept');
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'quote', 'Demolish house', 1, 'ea', 18000), (:'co', :'quote', 'Haul debris', 1, 'ea', 4000);
commit;
-- Saved empty, a section is left off.
update public.companies set settings = jsonb_set(settings, '{quotes,payment_terms}', '""') where id = :'co';
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'No payment terms') returning id as none \gset
select tpo_qp.check((select payment_terms is null and contract_terms = 'TEST placeholder contract terms.' from public.quotes where id = :'none'), 'a default saved empty leaves that section off');
update public.companies set settings = jsonb_set(settings, '{quotes,payment_terms}', '"TEST placeholder payment terms."') where id = :'co';

-- ===== Quote or proposal: one record, one total ================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.check((select presentation from public.quotes where id = :'quote') = 'line_items', 'a quote is a line-item quote unless made a proposal');
select (select total from public.quotes where id = :'quote') as total_before \gset
update public.quotes set presentation = 'proposal', narrative = '{"overview": "TEST overview", "scope": "1. Disconnect utilities\n2. Demolish\n3. Haul", "inclusions": "Debris removal", "exclusions": "Asbestos abatement", "assumptions": "Clear access", "alternates": "Keep the garage"}' where id = :'quote';
select tpo_qp.check((select presentation = 'proposal' and total = :'total_before'::numeric and narrative ->> 'exclusions' = 'Asbestos abatement' from public.quotes where id = :'quote'),
  'switched to a proposal, it keeps the same total, and its narrative scope');
update public.quotes set presentation = 'line_items' where id = :'quote';
select tpo_qp.check((select total = :'total_before'::numeric and narrative ->> 'scope' like '1. Disconnect%' and payment_terms like '%edited%' from public.quotes where id = :'quote'),
  'and back again keeps prices, scope and terms');
select tpo_qp.expect_error(format('update public.quotes set narrative = %L where id = %L', '{"warranty": "x"}', :'quote'), 'the narrative takes only its own sections');
select tpo_qp.expect_error(format('update public.quotes set presentation = %L where id = %L', 'letter', :'quote'), 'and the layout is one of the two');
commit;

-- ===== Each of these is part of the exact version the customer signs ===========================
select public.quote_fingerprint(:'quote') as v1 \gset
update public.quotes set presentation = 'proposal' where id = :'quote';
select tpo_qp.check(public.quote_fingerprint(:'quote') <> :'v1', 'the layout is part of the signed version');
select public.quote_fingerprint(:'quote') as v2 \gset
update public.quotes set narrative = narrative || '{"exclusions": "Asbestos abatement and lead paint"}' where id = :'quote';
select tpo_qp.check(public.quote_fingerprint(:'quote') <> :'v2', 'so is the narrative');
select public.quote_fingerprint(:'quote') as v3 \gset
update public.quotes set contract_terms = 'TEST placeholder contract terms, revised.' where id = :'quote';
select tpo_qp.check(public.quote_fingerprint(:'quote') <> :'v3', 'and the Contract Terms');
select public.quote_fingerprint(:'quote') as v4 \gset
update public.quotes set payment_terms = 'TEST placeholder payment terms, revised.' where id = :'quote';
select tpo_qp.check(public.quote_fingerprint(:'quote') <> :'v4', 'and the Payment Terms');
update public.quotes set status = 'sent', sent_at = now() where id = :'quote';
select tpo_qp.expect_error(format('select tpo_qp.customer_signs(%L, %L, %L)', :'co', :'quote', :'v4'), 'a customer page that showed the old Payment Terms can''t sign', '%changed after it was opened%');
select tpo_qp.expect_error(format('select tpo_qp.in_person_signs(%L, %L)', :'quote', :'v4'), 'nor the in-person screen', '%changed after it was opened%');
select tpo_qp.expect_error(format('select tpo_qp.customer_signs(%L, %L, %L)', :'co', :'quote', :'v3'), 'nor one that showed the old Contract Terms', '%changed after it was opened%');
select tpo_qp.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now(), %L, planet_test.drawn()))', :'co', :'quote', '{}', 'name', 'Test Customer', 'signed_at', 'signature'),
  'nor a page that doesn''t say which version it showed', '%exact version%');
select tpo_qp.check((select status from public.quotes where id = :'quote') = 'sent', 'none of them signed it');
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'quote'), 'the customer signs the proposal they saw, on their link');
select tpo_qp.check((select approval -> 'document' -> 'quote' ->> 'payment_terms' = 'TEST placeholder payment terms, revised.'
                       and approval -> 'document' -> 'quote' ->> 'contract_terms' = 'TEST placeholder contract terms, revised.'
                       and approval -> 'document' -> 'quote' ->> 'presentation' = 'proposal'
                       and approval -> 'document' -> 'quote' -> 'narrative' ->> 'exclusions' = 'Asbestos abatement and lead paint'
                       and approval ->> 'fingerprint' = public.quote_fingerprint(id) from public.quotes where id = :'quote'),
  'the signed copy keeps the layout, the narrative and both terms as signed');
select tpo_qp.check((select not (approval ? 'company') from public.quotes where id = :'quote'), 'nothing is signed for the company as the customer signs');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set contract_terms = %L where id = %L', 'different', :'quote'), 'once signed, the Contract Terms stay as signed', '%stay as signed%');
select tpo_qp.expect_error(format('update public.quotes set payment_terms = %L where id = %L', 'different', :'quote'), 'and the Payment Terms', '%stay as signed%');
select tpo_qp.expect_error(format('update public.quotes set presentation = %L where id = %L', 'line_items', :'quote'), 'and the layout', '%stay as signed%');
commit;

-- A proposal signed in person keeps the same.
insert into public.quotes (company_id, client_id, title, presentation, narrative) values (:'co', :'client', 'Garage proposal', 'proposal', '{"overview": "TEST garage", "exclusions": "Foundation"}') returning id as garage \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'garage', 'Demolish garage', 1, 'ea', 6000);
update public.quotes set status = 'sent', sent_at = now() where id = :'garage';
select tpo_qp.in_person_signs(:'garage') is not null as signed \gset
select tpo_qp.check((select status = 'approved' and approval ->> 'method' = 'in_person' and not (approval ? 'company')
                       and approval -> 'document' -> 'quote' ->> 'presentation' = 'proposal'
                       and approval -> 'document' -> 'quote' ->> 'contract_terms' = 'TEST placeholder contract terms.'
                       and approval -> 'document' -> 'quote' ->> 'payment_terms' = 'TEST placeholder payment terms.' from public.quotes where id = :'garage'),
  'a proposal signed in person keeps its layout and both terms as signed, with no company signature unless one is given');

-- ===== Company countersignature off (the default) ==============================================
select public.convert_quote_to_job(:'quote') as job \gset
select tpo_qp.check((select status from public.quotes where id = :'quote') = 'converted', 'without a required countersignature, the customer''s signature is enough to make the job');
-- Optional, it's still the signer's own and bound to the version.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.quotes set approval = approval || jsonb_build_object('company', tpo_qp.countersignature()) where id = :'garage';
commit;
select tpo_qp.check((select approval -> 'company' ->> 'fingerprint' = approval ->> 'fingerprint' and (approval -> 'company' ->> 'signed_at')::timestamptz > now() - interval '1 hour'
                     from public.quotes where id = :'garage'), 'an optional countersignature is stamped with the database''s time and the version the customer signed');
-- Signed while it's off, made a job after it's turned on (below).
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Signed before the rule') returning id as before_rule \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'before_rule', 'Remove pool', 1, 'ea', 9000);
update public.quotes set status = 'sent', sent_at = now() where id = :'before_rule';
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'before_rule'), 'the customer signs another quote while countersignatures are off');
-- A change order: the customer's signature finalizes it.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'CO: slab', :'job') returning id as co_off \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co_off', 'Remove slab', 1, 'ea', 2500);
update public.quotes set status = 'sent', sent_at = now() where id = :'co_off';
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'co_off'), 'the customer signs a change order');
select tpo_qp.check((select status from public.quotes where id = :'co_off') = 'converted', 'without a required countersignature, the customer''s signature finalizes it');

-- ===== Company countersignature required =======================================================
update public.companies set settings = jsonb_set(settings, '{quotes,countersign_required}', 'true') where id = :'co';
select tpo_qp.expect_error(format('select public.convert_quote_to_job(%L)', :'before_rule'), 'turned on after the customer signed, it''s still needed before the job', '%once your company countersigns%');

insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Barn demolition') returning id as barn \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'barn', 'Demolish barn', 1, 'ea', 12000);
update public.quotes set status = 'sent', sent_at = now() where id = :'barn';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set approval = jsonb_build_object(%L, tpo_qp.countersignature()) where id = %L', 'company', :'barn'),
  'the company can''t countersign before the customer signs', '%once the customer has signed%');
commit;
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'barn'), 'the customer signs the quote');
select tpo_qp.check((select status = 'approved' and not (approval ? 'company') from public.quotes where id = :'barn'), 'it''s accepted by the customer, with no company signature added for them');
select tpo_qp.expect_error(format('select public.convert_quote_to_job(%L)', :'barn'), 'it isn''t made a job before the company countersigns', '%once your company countersigns%');
select tpo_qp.expect_error(format('update public.quotes set status = %L where id = %L', 'converted', :'barn'), 'nor marked converted', '%once your company countersigns%');
select tpo_qp.expect_error(format('insert into public.jobs (company_id, client_id, title, quote_id) values (%L, %L, %L, %L)', :'co', :'client', 'Barn', :'barn'), 'nor given to a job', '%once your company countersigns%');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set approval = approval || %L where id = %L', '{"company": {"name": "Test Owner", "user_id": "a0d00000-0000-0000-0000-000000000001", "method": "drawn"}}', :'barn'),
  'a countersignature can''t be a name alone', '%needs to be drawn%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature() || %L) where id = %L', 'company', '{"signature": "Test Owner"}', :'barn'),
  'nor typed words in place of the drawing', '%needs to be drawn%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature() || jsonb_build_object(%L, %L)) where id = %L', 'company', 'signature', :'one_pixel', :'barn'),
  'nor a one-pixel image', '%needs to be drawn%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature() - %L) where id = %L', 'company', 'method', :'barn'),
  'nor one that doesn''t say it was drawn now or their saved one applied on purpose', '%needs to be drawn%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature(%L)) where id = %L', 'company', 'automatic', :'barn'),
  'nor one applied automatically', '%needs to be drawn%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature(%L, %L)) where id = %L', 'company', 'drawn', 'a0d00000-0000-0000-0000-000000000002', :'barn'),
  'nor one signed in someone else''s name', '%person signed in%');
update public.quotes set approval = approval || jsonb_build_object('company', tpo_qp.countersignature()) where id = :'barn';
commit;
select tpo_qp.check((select approval -> 'company' ->> 'user_id' = 'a0d00000-0000-0000-0000-000000000001' and approval -> 'company' ->> 'method' = 'drawn'
                       and approval -> 'company' ->> 'signed_at' <> '2000-01-01T00:00:00Z' and (approval -> 'company' ->> 'signed_at')::timestamptz > now() - interval '1 hour'
                       and approval -> 'company' ->> 'fingerprint' = approval ->> 'fingerprint' and approval ->> 'fingerprint' = public.quote_fingerprint(id)
                       and approval ->> 'signature' = planet_test.drawn() and approval ->> 'name' = 'Test Customer'
                     from public.quotes where id = :'barn'),
  'the company countersigns, drawn by the signer: their identity, the database''s own time, bound to the version the customer signed, the customer''s signature untouched');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set approval = jsonb_set(approval, %L, %L) where id = %L', '{company,name}', '"Someone Else"', :'barn'), 'a countersignature isn''t changed', '%already%');
select tpo_qp.expect_error(format('update public.quotes set approval = approval - %L where id = %L', 'company', :'barn'), 'nor taken off', '%already%');
commit;
select tpo_qp.expect_error(format('update public.quotes set approval = approval - %L where id = %L', 'company', :'barn'), 'not by the server either', '%already countersigned%');
select public.convert_quote_to_job(:'barn') as barn_job \gset
select tpo_qp.check((select status from public.quotes where id = :'barn') = 'converted' and :'barn_job' is not null, 'countersigned, it becomes a job');

-- The signer's own saved signature, applied on purpose for this agreement.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.quotes set approval = approval || jsonb_build_object('company', tpo_qp.countersignature('saved')) where id = :'before_rule';
commit;
select tpo_qp.check((select approval -> 'company' ->> 'method' from public.quotes where id = :'before_rule') = 'saved', 'a saved signature applied on purpose is recorded as such');
select public.convert_quote_to_job(:'before_rule') as before_job \gset
select tpo_qp.check((select status from public.quotes where id = :'before_rule') = 'converted', 'and completes the agreement');

-- In person: signed without a countersignature waits for it; with one given in the same step, it's complete.
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Shed in person') returning id as shed \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'shed', 'Remove shed', 1, 'ea', 1500);
update public.quotes set status = 'sent', sent_at = now() where id = :'shed';
select tpo_qp.in_person_signs(:'shed') is not null as signed \gset
select tpo_qp.expect_error(format('select public.convert_quote_to_job(%L)', :'shed'), 'signed in person without a countersignature, it waits for one', '%once your company countersigns%');
insert into public.quotes (company_id, client_id, title) values (:'co', :'client', 'Deck in person') returning id as deck \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'deck', 'Remove deck', 1, 'ea', 2200);
update public.quotes set status = 'sent', sent_at = now() where id = :'deck';
select tpo_qp.in_person_signs(:'deck', null, tpo_qp.countersignature('drawn')) is not null as signed \gset
select tpo_qp.check((select approval -> 'company' ->> 'fingerprint' = approval ->> 'fingerprint' and approval -> 'company' ->> 'signed_at' <> '2000-01-01T00:00:00Z' from public.quotes where id = :'deck'),
  'a countersignature drawn on the in-person screen is stamped and bound to the version signed');
select public.convert_quote_to_job(:'deck') as deck_job \gset
select tpo_qp.check((select status from public.quotes where id = :'deck') = 'converted', 'and that agreement becomes a job');

-- A change order: the customer's signature is acceptance; it joins the job once the company countersigns.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'CO: shed', :'job') returning id as co_on \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co_on', 'Remove shed', 1, 'ea', 1200);
update public.quotes set status = 'sent', sent_at = now() where id = :'co_on';
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'co_on'), 'the customer signs the change order');
select tpo_qp.check((select status from public.quotes where id = :'co_on') = 'approved', 'it''s accepted by the customer, not yet finalized');
select tpo_qp.check(not exists (select 1 from public.job_line_items where source_quote_id = :'co_on'), 'and not on the job yet');
select tpo_qp.expect_error(format('select public.convert_quote_to_job(%L)', :'co_on'), 'converting it waits for the countersignature too', '%once your company countersigns%');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set approval = approval || %L where id = %L', '{"company": {"name": "Test Owner", "signed_at": "2026-11-20T17:00:00Z"}}', :'co_on'),
  'a required countersignature can''t be a name alone', '%needs to be drawn%');
update public.quotes set approval = approval || jsonb_build_object('company', tpo_qp.countersignature()) where id = :'co_on';
commit;
select tpo_qp.check((select status from public.quotes where id = :'co_on') = 'converted', 'the company countersigns, drawing it, and it''s finalized');
select tpo_qp.check((select count(*) from public.job_line_items where source_quote_id = :'co_on') = 1, 'added to the job once');

-- A change while the countersignature was awaited isn't finalized by it.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'CO: fence', :'job') returning id as co_moved \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co_moved', 'Remove fence', 1, 'ea', 700);
update public.quotes set status = 'sent', sent_at = now() where id = :'co_moved';
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'co_moved'), 'the customer signs another change order');
update public.quotes set starts_on = current_date + 30 where id = :'co_moved';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set approval = approval || jsonb_build_object(%L, tpo_qp.countersignature()) where id = %L', 'company', :'co_moved'),
  'its schedule changed after the customer signed, so it can''t be countersigned', '%changed after the customer signed%');
commit;
select tpo_qp.check((select status from public.quotes where id = :'co_moved') = 'approved' and not exists (select 1 from public.job_line_items where source_quote_id = :'co_moved'),
  'it''s still only accepted, and not on the job');
select tpo_qp.check((select coalesce(sum(round(quantity * unit_price, 2)), 0) from public.job_line_items where job_id = :'job') = 22000 + 2500 + 1200,
  'the job counts only finalized change orders, each once');

delete from public.companies where id = :'co';
\o
\echo 'All Planet Ops quotes and proposals tests passed.'
