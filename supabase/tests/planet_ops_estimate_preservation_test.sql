-- Planet Ops Phase 3 hardening: the internal estimate behind every customer document is kept exactly
-- as it was used, whether or not the business requires approval; approval is reviewed; no mixed or
-- stale snapshots; retries make nothing twice (20261126000100_planet_ops_estimate_preservation.sql).
-- Fictional numbers only. Run with scripts/test-db.sh.
--
-- The original defect (before 20261126000100): with "require approval" off, a document made from a
-- saved draft left that draft editable, so the estimate version its document, issued version and job
-- pointed at could change after the fact ($4,375 sent; the "same" version later read $15,250).
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpo_ep;
grant usage on schema tpo_ep to authenticated, service_role;
create function tpo_ep.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpo_ep.expect_error(p_sql text, p_what text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not like p_like then raise exception 'FAIL (wrong error "%"): %', sqlerrm, p_what; end if;
    raise notice 'ok - % (%)', p_what, sqlerrm; return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tpo_ep.as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute p_sql into v;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return v;
exception when others then
  reset role;
  perform set_config('request.jwt.claims', '', true);
  raise;
end $$;
-- An estimate version's lines as the editor sends them back, with one line's count changed.
create function tpo_ep.lines(p_version uuid, p_key text default null, p_count numeric default null) returns jsonb language sql as $$
  select jsonb_build_object('lines', jsonb_agg(jsonb_build_object('id', id, 'key', key, 'section', section, 'name', name, 'customer_item', customer_item,
           'count', case when key = p_key then p_count else count end, 'hours', hours, 'days', days, 'unit', unit, 'unit_cost', unit_cost, 'rate_id', rate_id,
           'risk_pct', risk_pct) order by sort))
    from public.estimate_lines where version_id = p_version
$$;
-- Everything that makes up a version's estimate: settings, totals, lines with rate snapshots, scope.
create function tpo_ep.evidence(p_version uuid) returns text language sql as $$
  select md5(jsonb_build_object(
    'v', (select to_jsonb(v) - array['status', 'approved_by', 'approved_at', 'approval_note', 'locked_at', 'locked_by'] from public.estimate_versions v where v.id = p_version),
    'lines', (select jsonb_agg(to_jsonb(l) order by l.sort) from public.estimate_lines l where l.version_id = p_version))::text)
$$;
create function tpo_ep.rev(p_version uuid) returns integer language sql as $$ select revision from public.estimate_versions where id = p_version $$;
grant execute on all functions in schema tpo_ep to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2600000-0000-0000-0000-000000000001', 'owner@planet-ep.test', '{"full_name": "Test Owner"}'),
  ('e2600000-0000-0000-0000-000000000002', 'estimator@planet-ep.test', '{"full_name": "Test Estimator"}');
\set owner 'e2600000-0000-0000-0000-000000000001'
\set est 'e2600000-0000-0000-0000-000000000002'
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner', 'role', 'authenticated')::text, true);
select public.create_company('TEST Planet Demolition EP', 'general') as co \gset
commit;
insert into public.memberships (company_id, user_id, role) values (:'co', :'est', 'estimator');
insert into public.clients (company_id, display_name) values (:'co', 'TEST – Preservation Customer') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '7 Test Lane', 'Testburg', 'CA', '95001') returning id as property \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Garage demolition') returning id as req \gset
select tpo_ep.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 30, %L)::text', :'co', 'test.crew', 'labor', 'TEST crew hour', 'hour', current_date - 30)) as rate \gset
-- Approval not required (Settings → Estimating, switched off).
update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{estimating}', '{"require_approval": false}') where id = :'co';

-- A complete estimate: crew 2 × 8 h at the $30 rate, 3 tons at $80, $100 contingency; 30% markup.
select tpo_ep.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2600000-0000-0000-0000-0000000000e1', 'Garage demolition', :'req')) as e1 \gset
select current_version_id as v1 from public.estimates where id = :'e1' \gset
select tpo_ep.as(:'est', format($f$select public.save_estimate_version(%L, 0, %L::jsonb)::text$f$, :'v1', jsonb_build_object(
  'scope', jsonb_build_object('customer_overview', 'Remove the garage and its slab.', 'site_notes', 'INTERNAL: narrow gate'),
  'pricing_method', 'markup', 'pricing_pct', 0.3, 'owner_pay_method', 'none',
  'lines', jsonb_build_array(
    jsonb_build_object('key', 'crew', 'section', 'labor', 'name', 'Crew', 'count', 2, 'hours', 8, 'days', 1, 'unit', 'hour', 'rate_id', :'rate', 'includes_burden', true, 'customer_item', 'Demolition'),
    jsonb_build_object('key', 'debris', 'section', 'disposal', 'name', 'Mixed debris', 'count', 3, 'unit', 'ton', 'unit_cost', 80, 'customer_item', 'Haul-off and disposal'),
    jsonb_build_object('key', 'contingency', 'section', 'contingency', 'name', 'Contingency', 'count', 1, 'unit', 'lump', 'unit_cost', 100, 'customer_item', 'Demolition')))));
-- 480 + 240 + 100 = 820; 30% = 246 → 1,066.
select tpo_ep.check((select status = 'draft' and selling_price = 1066 and revision = 1 from public.estimate_versions where id = :'v1'), 'a saved, complete draft: $1,066');

-- ===== Making the document: from the revision the person saw, locked, not approved ===============
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v1', 'line_items', 'a2600000-0000-0000-0000-0000000000f0')),
  'from a draft, the person must say which saved revision they reviewed', '%saved again since you opened it%');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L, 0)::text', :'v1', 'line_items', 'a2600000-0000-0000-0000-0000000000f0')),
  'a stale revision is refused (someone saved after they looked)', '%saved again since you opened it%');
select tpo_ep.check(not exists (select 1 from public.quotes where company_id = :'co') and (select status = 'draft' from public.estimate_versions where id = :'v1'),
  'a refused create leaves no document and the draft as it was');
select tpo_ep.evidence(:'v1') as ev1 \gset
select tpo_ep.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'v1', 'line_items', 'a2600000-0000-0000-0000-0000000000f1')) as q1 \gset
select tpo_ep.check((select status = 'locked' and locked_at is not null and locked_by = :'est' and approved_by is null and approved_at is null and approval_note is null
                     from public.estimate_versions where id = :'v1')
                    and (select baseline_version_id is null from public.estimates where id = :'e1'),
  'the draft is locked by being used, and nothing claims it was approved (no approver, time or baseline)');
select tpo_ep.check(tpo_ep.evidence(:'v1') = :'ev1', 'locking changes nothing in the estimate itself');
select tpo_ep.check((select sum(unit_price) = 1066 and count(*) = 2 from public.quote_line_items where quote_id = :'q1'), 'the document carries the version''s $1,066');
select tpo_ep.check(tpo_ep.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'v1', 'line_items', 'a2600000-0000-0000-0000-0000000000f1')) = :'q1'
                    and (select count(*) from public.quotes where company_id = :'co') = 1, 'a retry after a timeout returns the same document');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'v1', 'proposal', 'a2600000-0000-0000-0000-0000000000f1')),
  'the same key asking for another kind of document is refused, not answered with the first', '%already used to make a different document%');

-- ===== The used version can't change: not by saving, not by writing to it =======================
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v1', tpo_ep.lines(:'v1', 'debris', 40))),
  'the version used for the document can''t be saved again (quantities)', '%used for a customer document%');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v1', '{"pricing_pct": 0.9}')),
  'nor its pricing', '%used for a customer document%');
select tpo_ep.expect_error(format('update public.estimate_lines set unit_cost = 1 where version_id = %L', :'v1'), 'not even the database''s owner can rewrite its lines', '%used for a customer document%');
select tpo_ep.expect_error(format('update public.estimate_versions set scope = %L where id = %L', '{}', :'v1'), 'or its scope', '%used for a customer document%');
select tpo_ep.expect_error(format('delete from public.estimate_lines where version_id = %L', :'v1'), 'or delete its lines', '%used for a customer document%');
select tpo_ep.expect_error(format('update public.estimate_versions set status = %L where id = %L', 'draft', :'v1'), 'or unlock it', '%used for a customer document%');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('update public.estimate_versions set status = %L where id = %L', 'draft', :'v1')), 'staff can''t write to versions at all', '%permission denied%');
-- A rate change later doesn't move it either.
select tpo_ep.as(:'owner', format('select public.set_estimate_rate(%L, %L, %L, %L, %L, 45, %L)::text', :'co', 'test.crew', 'labor', 'TEST crew hour', 'hour', current_date)) as rate2 \gset
select tpo_ep.check(tpo_ep.evidence(:'v1') = :'ev1', 'a new rate in Settings leaves the used version exactly as it was');

-- ===== Later changes are a revision; the document stays; negotiating doesn't touch the estimate ===
select tpo_ep.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e1', 'More debris')) as v2 \gset
select tpo_ep.check((select number = 2 and status = 'draft' and based_on_version_id = :'v1' from public.estimate_versions where id = :'v2'), 'revising makes version 2, a draft, from version 1');
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v2', tpo_ep.lines(:'v2', 'debris', 6)));
select tpo_ep.check((select selling_price = 1378 from public.estimate_versions where id = :'v2'), 'version 2 prices 6 tons: $1,378 (the rate snapshot it copied, not the new $45)');
update public.quote_line_items set unit_price = unit_price - 66 where quote_id = :'q1' and name = 'Demolition';
select tpo_ep.check(tpo_ep.evidence(:'v1') = :'ev1' and (select sum(unit_price) = 1000 from public.quote_line_items where quote_id = :'q1'),
  'negotiating the document to $1,000 leaves version 1''s calculated $1,066; version 2 leaves the document');

-- ===== Refresh: only after reviewing the differences, and not if anything changed since =========
select tpo_ep.as(:'est', format('select public.estimate_quote_diff(%L, %L)::text', :'q1', :'v2')) as diff \gset
select tpo_ep.check((:'diff'::jsonb ->> 'to_status') = 'draft' and (:'diff'::jsonb ->> 'token') is not null, 'the differences carry a token for what was shown');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.refresh_quote_from_estimate(%L, %L)::text', :'q1', :'v2')),
  'refreshing without having reviewed the differences is refused', '%changed since you reviewed%');
-- Someone saves version 2 again after the review: the reviewed comparison is stale.
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'v2', tpo_ep.lines(:'v2', 'debris', 7)));
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'q1', :'v2', :'diff'::jsonb ->> 'token')),
  'the estimate changed after the review: refused', '%changed since you reviewed%');
select tpo_ep.as(:'est', format('select public.estimate_quote_diff(%L, %L)::text', :'q1', :'v2')) as diff \gset
-- Someone edits the document after the review: stale too.
update public.quote_line_items set unit_price = unit_price + 1 where quote_id = :'q1' and name = 'Demolition';
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'q1', :'v2', :'diff'::jsonb ->> 'token')),
  'the document changed after the review: refused', '%changed since you reviewed%');
select tpo_ep.check((select sum(unit_price) = 1001 from public.quote_line_items where quote_id = :'q1') and (select estimate_version_id = :'v1' from public.quotes where id = :'q1'),
  'a refused refresh changes nothing');
select tpo_ep.as(:'est', format('select public.estimate_quote_diff(%L, %L)::text', :'q1', :'v2')) as diff \gset
select tpo_ep.evidence(:'v2') as ev2 \gset
select tpo_ep.as(:'est', format('select public.refresh_quote_from_estimate(%L, %L, p_expected => %L)::text', :'q1', :'v2', :'diff'::jsonb ->> 'token'));
select tpo_ep.check((select estimate_version_id = :'v2' from public.quotes where id = :'q1') and (select sum(unit_price) = 1482 from public.quote_line_items where quote_id = :'q1')
                    and (select status = 'locked' and approved_at is null from public.estimate_versions where id = :'v2') and tpo_ep.evidence(:'v2') = :'ev2',
  'refreshed after a current review: version 2''s $1,456, and version 2 is locked as it was');
select tpo_ep.check(tpo_ep.evidence(:'v1') = :'ev1', 'version 1, used before, is still exactly as it was');

-- ===== Issued, signed, converted: the job's estimate version is the one the signed version carried
update public.quotes set status = 'sent', sent_at = now() where id = :'q1';
select tpo_ep.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e1', 'While the customer reads it')) as v3 \gset
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'v3', tpo_ep.lines(:'v3', 'debris', 12)));
select tpo_ep.check((select estimate_version_id = :'v2' from public.quote_versions where quote_id = :'q1' and number = 1)
                    and (select sum(unit_price) = 1482 from public.quote_line_items where quote_id = :'q1'),
  'editing the estimate while the document is out (version 3) leaves the issued version on version 2');
select planet_test.sign(:'q1');
select tpo_ep.as(:'est', format('select public.convert_quote_to_job(%L)::text', :'q1')) as job \gset
select tpo_ep.check((select estimate_version_id = :'v2' from public.jobs where id = :'job'), 'the job links version 2, not the newer version 3');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.save_estimate_version(%L, %s, %L::jsonb)::text', :'v2', tpo_ep.rev(:'v2'), tpo_ep.lines(:'v2', 'debris', 99))),
  'after signing and converting, the job''s estimate version still can''t be edited', '%used for a customer document%');
select tpo_ep.check(tpo_ep.evidence(:'v2') = :'ev2' and (select selling_price = 1482 from public.estimate_versions where id = :'v2'),
  'the job''s estimate evidence is exactly what the signed document was made from');
-- Approving version 2 later is a real, separate approval of the same content.
select tpo_ep.as(:'owner', format('select public.approve_estimate_version(%L, %s)::text', :'v2', tpo_ep.rev(:'v2')));
select tpo_ep.check((select status = 'approved' and approved_by = :'owner' and approved_at is not null and locked_at is not null from public.estimate_versions where id = :'v2')
                    and tpo_ep.evidence(:'v2') = :'ev2' and (select baseline_version_id = :'v2' from public.estimates where id = :'e1'),
  'approving it later records the approver and time on the same, unchanged content (now the baseline)');
select tpo_ep.as(:'est', format('select public.estimate_summary(%L)::text', :'e1')) as summary \gset
select tpo_ep.check((select string_agg(x ->> 'number' || ':' || (x ->> 'status'), ',' order by (x ->> 'number')::int) from jsonb_array_elements(:'summary'::jsonb -> 'versions') x) = '1:locked,2:approved,3:draft'
                    and (:'summary'::jsonb -> 'jobs' -> 0 ->> 'estimate_version')::int = 2
                    and (select bool_or((d -> 'sent' -> 0 ->> 'estimate_version')::int = 2) from jsonb_array_elements(:'summary'::jsonb -> 'documents') d),
  'the summary shows each version''s state, the issued version and the job on version 2');

-- ===== With approval required: a draft can't be used; approval is of the revision reviewed =====
update public.companies set settings = jsonb_set(settings, '{estimating}', '{"require_approval": true}') where id = :'co';
select tpo_ep.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2600000-0000-0000-0000-0000000000e2', 'Shed demolition', :'req')) as e2 \gset
select current_version_id as w1 from public.estimates where id = :'e2' \gset
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'w1',
  '{"pricing_method": "markup", "pricing_pct": 0.5, "lines": [{"key": "a", "section": "other", "name": "Shed", "count": 1, "unit": "lump", "unit_cost": 200, "customer_item": "Demolition"}]}'));
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'w1', 'proposal', 'a2600000-0000-0000-0000-0000000000f2')),
  'with approval required, a saved draft can''t become a document', '%requires an approved estimate%');
-- The owner opens it at revision 1; the estimator saves revision 2; approving what was reviewed is refused.
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'w1',
  '{"lines": [{"key": "a", "section": "other", "name": "Shed", "count": 2, "unit": "lump", "unit_cost": 200, "customer_item": "Demolition"}]}'));
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'owner', format('select public.approve_estimate_version(%L, 1)::text', :'w1')),
  'approving from an outdated screen is refused: the approver didn''t review revision 2', '%saved again since you opened it%');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'owner', format('select public.approve_estimate_version(%L)::text', :'w1')),
  'approving without saying which revision was reviewed is refused', '%saved again since you opened it%');
select tpo_ep.check((select status = 'draft' and approved_at is null from public.estimate_versions where id = :'w1'), 'nothing was approved');
select tpo_ep.as(:'owner', format('select public.approve_estimate_version(%L, 2)::text', :'w1'));
select tpo_ep.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'w1', 'proposal', 'a2600000-0000-0000-0000-0000000000f2')) as q2 \gset
select tpo_ep.check((select status = 'approved' and locked_at is null and revision = 2 and selling_price = 600 from public.estimate_versions where id = :'w1')
                    and (select sum(unit_price) = 600 from public.quote_line_items where quote_id = :'q2'),
  'approved revision 2 ($600) becomes the document; an approved version isn''t "locked", it''s frozen by approval');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L)::text', :'v2', 'proposal', 'a2600000-0000-0000-0000-0000000000f2')),
  'the same key with another version is refused', '%already used to make a different document%');

-- ===== Retried "New estimate": the same one; a key reused for another request is refused =========
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'property', 'Pool removal') returning id as req2 \gset
select tpo_ep.check(tpo_ep.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2600000-0000-0000-0000-0000000000e2', 'Shed demolition', :'req')) = :'e2',
  'a double-clicked or retried New estimate opens the same estimate');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2600000-0000-0000-0000-0000000000e2', 'Pool removal', :'req2')),
  'the same key for another request is refused, not answered with the first estimate', '%already used for a different estimate%');

-- ===== At the same moment (a second connection) =================================================
create schema tpo_ep_x;
create extension dblink schema tpo_ep_x;
select tpo_ep_x.dblink_connect('other', 'dbname=' || current_database() || ' user=postgres');
-- (a) A save is in progress when someone makes a document: the document waits for it, then sees
-- that the revision they reviewed is gone, and makes nothing.
update public.companies set settings = jsonb_set(settings, '{estimating}', '{"require_approval": false}') where id = :'co';
select tpo_ep.as(:'est', format('select public.create_estimate(%L, %L, %L, %L)', :'co', 'a2600000-0000-0000-0000-0000000000e3', 'Fence removal', :'req')) as e3 \gset
select current_version_id as x1 from public.estimates where id = :'e3' \gset
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'x1',
  '{"pricing_method": "markup", "pricing_pct": 0, "lines": [{"key": "a", "section": "other", "name": "Fence", "count": 1, "unit": "lump", "unit_cost": 300, "customer_item": "Demolition"}]}'));
select tpo_ep_x.dblink_exec('other', 'begin');
select tpo_ep_x.dblink_exec('other', format('set local "request.jwt.claims" = %L', json_build_object('sub', :'est', 'role', 'authenticated')::text));
select tpo_ep_x.dblink_exec('other', 'set local role authenticated');
select * from tpo_ep_x.dblink('other', format($s$select public.save_estimate_version(%L, 1, '{"lines": [{"key": "a", "section": "other", "name": "Fence", "count": 3, "unit": "lump", "unit_cost": 300, "customer_item": "Demolition"}]}')::text$s$, :'x1')) as t(r text);
set lock_timeout = '300ms';
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'x1', 'line_items', 'a2600000-0000-0000-0000-0000000000f3')),
  'making a document waits while a save of the same version is in progress (no half-saved read)', '%lock timeout%');
reset lock_timeout;
select tpo_ep_x.dblink_exec('other', 'commit');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.create_quote_from_estimate(%L, %L, %L, 1)::text', :'x1', 'line_items', 'a2600000-0000-0000-0000-0000000000f3')),
  'once that save lands, the document from the revision reviewed before it is refused', '%saved again since you opened it%');
select tpo_ep.as(:'est', format('select public.create_quote_from_estimate(%L, %L, %L, 2)::text', :'x1', 'line_items', 'a2600000-0000-0000-0000-0000000000f3')) as q3 \gset
select tpo_ep.check((select sum(unit_price) = 900 from public.quote_line_items where quote_id = :'q3') and (select status = 'locked' and selling_price = 900 from public.estimate_versions where id = :'x1'),
  'made from the current revision: the document and the locked version agree ($900)');
-- (b) A document is being made when someone saves: the save waits, then is refused (the version is
-- now the document's), so nothing is mixed.
select tpo_ep.as(:'est', format('select public.revise_estimate(%L, %L)::text', :'e3', 'Second document')) as x2 \gset
select tpo_ep.as(:'est', format('select public.save_estimate_version(%L, 0, %L::jsonb)::text', :'x2', tpo_ep.lines(:'x2')));
select tpo_ep_x.dblink_exec('other', 'begin');
select tpo_ep_x.dblink_exec('other', format('set local "request.jwt.claims" = %L', json_build_object('sub', :'est', 'role', 'authenticated')::text));
select tpo_ep_x.dblink_exec('other', 'set local role authenticated');
select * from tpo_ep_x.dblink('other', format($s$select public.create_quote_from_estimate(%L, 'proposal', 'a2600000-0000-0000-0000-0000000000f4', 1)::text$s$, :'x2')) as t(r text);
set lock_timeout = '300ms';
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'x2', tpo_ep.lines(:'x2', 'a', 5))),
  'a save waits while a document is being made from the same version', '%lock timeout%');
reset lock_timeout;
select tpo_ep_x.dblink_exec('other', 'commit');
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.save_estimate_version(%L, 1, %L::jsonb)::text', :'x2', tpo_ep.lines(:'x2', 'a', 5))),
  'and then it''s refused: that version is the document''s now', '%used for a customer document%');
-- (c) Two people convert the same signed document at once: one job.
select id as q4 from public.quotes where from_estimate_key = 'a2600000-0000-0000-0000-0000000000f4' \gset
update public.quotes set status = 'sent', sent_at = now() where id = :'q4';
select planet_test.sign(:'q4');
select tpo_ep_x.dblink_exec('other', 'begin');
select tpo_ep_x.dblink_exec('other', format('set local "request.jwt.claims" = %L', json_build_object('sub', :'est', 'role', 'authenticated')::text));
select tpo_ep_x.dblink_exec('other', 'set local role authenticated');
select r as job4 from tpo_ep_x.dblink('other', format($s$select public.convert_quote_to_job(%L)::text$s$, :'q4')) as t(r text) \gset
set lock_timeout = '300ms';
select tpo_ep.expect_error(format('select tpo_ep.as(%L, %L)', :'est', format('select public.convert_quote_to_job(%L)::text', :'q4')), 'a second conversion waits for the first', '%lock timeout%');
reset lock_timeout;
select tpo_ep_x.dblink_exec('other', 'commit');
select tpo_ep.check(tpo_ep.as(:'est', format('select public.convert_quote_to_job(%L)::text', :'q4')) = :'job4' and (select count(*) from public.jobs where quote_id = :'q4') = 1
                    and (select estimate_version_id = :'x2' from public.jobs where id = :'job4'),
  'then finds the same job: one job, on the signed version''s estimate version');
select tpo_ep_x.dblink_disconnect('other');
drop extension dblink;
drop schema tpo_ep_x;

-- The company is kept: sub_isolation_test.sql sweeps tables with rows in them.
\o
\echo 'All Planet Ops estimate preservation tests passed.'
