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
create function tpo_qp.customer_signs(p_company uuid, p_quote uuid) returns boolean language sql as $$
  select public.approve_hub_quote(p_company, p_quote, '{}',
    jsonb_build_object('name', 'Test Customer', 'signed_at', now(), 'seen_fingerprint', public.quote_fingerprint(p_quote)))
$$;
grant execute on all functions in schema tpo_qp to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a0d00000-0000-0000-0000-000000000001', 'owner@planet-qp.test', '{"full_name": "Test Owner"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('TEST Planet Demolition QP', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Proposal Customer') returning id as client \gset
commit;

-- ===== Contract Terms and Payment Terms, from the company's defaults ===========================
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

-- ===== Quote or proposal: one record, one total ================================================
select tpo_qp.check((select presentation from public.quotes where id = :'quote') = 'line_items', 'a quote is a line-item quote unless made a proposal');
select (select total from public.quotes where id = :'quote') as total_before \gset
update public.quotes set presentation = 'proposal', narrative = '{"overview": "TEST overview", "scope": "1. Disconnect utilities\n2. Demolish\n3. Haul", "inclusions": "Debris removal", "exclusions": "Asbestos abatement", "assumptions": "Clear access", "alternates": "Leave the slab"}' where id = :'quote';
select tpo_qp.check((select presentation = 'proposal' and total = :'total_before'::numeric and narrative ->> 'exclusions' = 'Asbestos abatement' from public.quotes where id = :'quote'),
  'switched to a proposal, it keeps the same total, and its narrative scope');
update public.quotes set presentation = 'line_items' where id = :'quote';
select tpo_qp.check((select total = :'total_before'::numeric and narrative ->> 'scope' like '1. Disconnect%' and payment_terms like '%edited%' from public.quotes where id = :'quote'),
  'and back again keeps prices, scope and terms');
select tpo_qp.expect_error(format('update public.quotes set narrative = %L where id = %L', '{"warranty": "x"}', :'quote'), 'the narrative takes only its own sections');
select tpo_qp.expect_error(format('update public.quotes set presentation = %L where id = %L', 'letter', :'quote'), 'and the layout is one of the two');
commit;

-- Each of these is part of the version the customer signs.
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
select tpo_qp.expect_error(format('select public.approve_hub_quote(%L, %L, %L, jsonb_build_object(%L, %L, %L, now(), %L, %L))', :'co', :'quote', '{}', 'name', 'Test Customer', 'signed_at', 'seen_fingerprint', :'v4'),
  'a page that showed the old Payment Terms can''t sign', '%changed after it was opened%');
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'quote'), 'the customer signs the proposal they saw');
select tpo_qp.check((select approval -> 'document' -> 'quote' ->> 'payment_terms' = 'TEST placeholder payment terms, revised.'
                       and approval -> 'document' -> 'quote' ->> 'presentation' = 'proposal' from public.quotes where id = :'quote'),
  'the signed copy keeps the layout and the terms as signed');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "a0d00000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tpo_qp.expect_error(format('update public.quotes set contract_terms = %L where id = %L', 'different', :'quote'), 'once signed, the Contract Terms stay as signed', '%stay as signed%');
select tpo_qp.expect_error(format('update public.quotes set payment_terms = %L where id = %L', 'different', :'quote'), 'and the Payment Terms', '%stay as signed%');
select tpo_qp.expect_error(format('update public.quotes set presentation = %L where id = %L', 'line_items', :'quote'), 'and the layout', '%stay as signed%');
commit;

-- ===== A required company countersignature =====================================================
select public.convert_quote_to_job(:'quote') as job \gset
-- Off (the default): a change order the customer signs joins the job at once.
insert into public.quotes (company_id, client_id, title, change_order_for) values (:'co', :'client', 'CO: slab', :'job') returning id as co_off \gset
insert into public.quote_line_items (company_id, quote_id, name, quantity, unit, unit_price) values (:'co', :'co_off', 'Remove slab', 1, 'ea', 2500);
update public.quotes set status = 'sent', sent_at = now() where id = :'co_off';
select tpo_qp.check(tpo_qp.customer_signs(:'co', :'co_off'), 'the customer signs a change order');
select tpo_qp.check((select status from public.quotes where id = :'co_off') = 'converted', 'without a required countersignature, the customer''s signature finalizes it');

-- On: the customer's signature is acceptance; it joins the job once the company countersigns.
update public.companies set settings = jsonb_set(settings, '{quotes,countersign_required}', 'true') where id = :'co';
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
update public.quotes set approval = approval || '{"company": {"name": "Test Owner", "signature": "data:image/png;base64,AAAA", "signed_at": "2026-11-20T17:00:00Z"}}' where id = :'co_on';
commit;
select tpo_qp.check((select status from public.quotes where id = :'co_on') = 'converted', 'the company countersigns and it''s finalized');
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
select tpo_qp.expect_error(format('update public.quotes set approval = approval || %L where id = %L', '{"company": {"name": "Test Owner"}}', :'co_moved'),
  'its schedule changed after the customer signed, so the countersignature can''t finalize it', '%changed after the customer signed%');
commit;
select tpo_qp.check((select status from public.quotes where id = :'co_moved') = 'approved' and not exists (select 1 from public.job_line_items where source_quote_id = :'co_moved'),
  'it''s still only accepted, and not on the job');
select tpo_qp.check((select coalesce(sum(round(quantity * unit_price, 2)), 0) from public.job_line_items where job_id = :'job') = 22000 + 2500 + 1200,
  'the job counts only finalized change orders, each once');

delete from public.companies where id = :'co';
\o
\echo 'All Planet Ops quotes and proposals tests passed.'
