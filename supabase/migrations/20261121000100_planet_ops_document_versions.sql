-- Planet Ops Phase 1c: document versions and customer change requests
-- (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3, "Customer requests for changes").
--
-- 1. Versions. Each time a quote, proposal or change order is issued to the customer (sent, sent
--    again with changes, its exact price sent, or presented on the in-person signing screen), the
--    complete offered document is kept as an immutable snapshot (public.quote_versions): its
--    number in sequence, private.quote_version (scope, lines, options and their prices, schedule,
--    payment schedule and deposit, Contract Terms, Payment Terms, the contract sections' words and
--    the template's terms), its fingerprint and totals, who issued it and when. Later changes to
--    company defaults, templates or price lists don't change a snapshot.
--    Editing an issued document makes a draft revision: the customer's link keeps the issued
--    version and shows no unsent changes (the API checks the fingerprint), and nothing goes out
--    until someone sends it. Issuing a new version supersedes the pending one.
-- 2. Signing. On the customer's link, only the current issued version is signed: never a
--    superseded one, never an unsent draft revision. In person, the screen shows the document as
--    it is, so signing there issues it first. Either way the signature records the version
--    (approval.version_id / version_number) and the version records that it was signed.
-- 3. Change requests (public.quote_change_requests). "Request changes" saves the customer's note as
--    typed, who sent it (the client, from their own link or the office's copy), the server's time,
--    the document and the exact version they reviewed. A retry with the same request key is the
--    same request. On a pending document it marks it "Changes requested" and pauses signing until
--    the office issues a version again (a revision, or the same one made available again). It
--    never edits the agreement and is never an acceptance. On a signed agreement the signed
--    original stays as it is; the request is logged against it and, for an active job, a proposed
--    change order (a draft) is started for the office. Each request notifies the document's owner
--    (its salesperson, else the office) and creates one follow-up task (public.follow_up_tasks).
--
-- Existing documents waiting for an answer get their current version as version 1, so a page opened
-- before this migration still signs.

-- ---------------------------------------------------------------------------------------------
-- 1. Versions
-- ---------------------------------------------------------------------------------------------

create table public.quote_versions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  quote_id uuid not null,
  number integer not null check (number > 0),
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{32}$'),
  document jsonb not null,
  presentation text,
  subtotal numeric(12, 2),
  discount_amount numeric(12, 2),
  tax_amount numeric(12, 2),
  total numeric(12, 2),
  issued_at timestamptz not null default now(),
  issued_by uuid references auth.users (id) on delete set null,
  issued_via text not null check (issued_via in ('sent', 'in_person', 'site_price', 'promo', 'existing')),
  superseded_at timestamptz,
  superseded_by uuid,
  signed_at timestamptz,
  unique (company_id, id),
  unique (quote_id, number),
  foreign key (company_id, quote_id) references public.quotes (company_id, id) on delete cascade
);
create index quote_versions_quote_idx on public.quote_versions (quote_id, number desc);
comment on table public.quote_versions is 'Planet Ops: each version of a quote, proposal or change order as issued to the customer, kept as issued (immutable).';

alter table public.quote_versions enable row level security;
create policy quote_versions_read on public.quote_versions for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
grant select on public.quote_versions to authenticated;

-- A version is kept as issued: only its superseding and signing are recorded, once each. It goes
-- only with its quote (or its company).
create function private.quote_version_stays() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'An issued version is kept as issued and can''t be deleted.' using errcode = '22023';
  end if;
  if (to_jsonb(new) - 'superseded_at' - 'superseded_by' - 'signed_at') is distinct from (to_jsonb(old) - 'superseded_at' - 'superseded_by' - 'signed_at')
     or (old.superseded_at is not null and new.superseded_at is distinct from old.superseded_at)
     or (old.superseded_by is not null and new.superseded_by is distinct from old.superseded_by)
     or (old.signed_at is not null and new.signed_at is distinct from old.signed_at) then
    raise exception 'An issued version is kept as issued. Make a new revision for anything that changes.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger quote_version_stays before update or delete on public.quote_versions
  for each row execute function private.quote_version_stays();

-- Issue the document as it is now: a new version when it differs from the last one issued (which
-- is then superseded, unless it was signed), else the last one again. Returns the version's id.
create function private.issue_version(p_quote uuid, p_via text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  q public.quotes;
  v_document jsonb;
  v_fingerprint text;
  v_last public.quote_versions;
  v_id uuid;
begin
  select * into q from public.quotes where id = p_quote;
  if not found then return null; end if;
  -- One version at a time for a quote, whoever issues it.
  perform pg_advisory_xact_lock(hashtextextended('quote_versions:' || p_quote::text, 0));
  v_document := private.quote_version(p_quote);
  v_fingerprint := md5(v_document::text);
  select * into v_last from public.quote_versions where quote_id = p_quote order by number desc limit 1;
  if found and v_last.fingerprint = v_fingerprint and v_last.superseded_at is null then
    return v_last.id;
  end if;
  insert into public.quote_versions (company_id, quote_id, number, fingerprint, document, presentation, subtotal, discount_amount, tax_amount, total, issued_by, issued_via)
  values (q.company_id, p_quote, coalesce(v_last.number, 0) + 1, v_fingerprint, v_document, q.presentation,
          q.subtotal, q.discount_amount, q.tax_amount, q.total, (select auth.uid()), p_via)
  returning id into v_id;
  update public.quote_versions set superseded_at = now(), superseded_by = v_id
   where quote_id = p_quote and id <> v_id and superseded_at is null and signed_at is null;
  return v_id;
end $$;

-- The version a customer's link would sign now: the last one issued, while it's current.
create function private.current_version(p_quote uuid) returns public.quote_versions
language sql stable security definer set search_path = '' as $$
  select * from public.quote_versions where quote_id = p_quote and superseded_at is null and signed_at is null
   order by number desc limit 1
$$;

-- Issuing again resolves the open change requests (the office answered them with this version) and
-- makes it available to sign: a document with changes requested is waiting for an answer again.
create function private.answer_change_requests(p_quote uuid, p_version uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.quote_change_requests
     set resolved_at = now(), resolved_by = (select auth.uid()), resolved_version_id = p_version
   where quote_id = p_quote and resolved_at is null and signed_agreement = false;
  update public.follow_up_tasks t set done_at = now(), done_by = (select auth.uid())
    from public.quote_change_requests r
   where r.quote_id = p_quote and t.source = 'change_request' and t.source_id = r.id and t.done_at is null and r.resolved_at is not null and r.signed_agreement = false;
end $$;

-- Sent (or its exact price sent, or the range sent again): the version sent is issued. Inserted as
-- sent too (an import, the demo).
create function private.issue_on_send() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  v_id := private.issue_version(new.id, 'sent');
  perform private.answer_change_requests(new.id, v_id);
  return null;
end $$;
create trigger issue_on_send after update of status, sent_at, exact_sent_at, range_sent_at on public.quotes
  for each row
  when (new.status = 'sent' and new.is_template is not true and (old.status is distinct from 'sent' or old.sent_at is distinct from new.sent_at
        or old.exact_sent_at is distinct from new.exact_sent_at or old.range_sent_at is distinct from new.range_sent_at))
  execute function private.issue_on_send();
create trigger issue_on_send_insert after insert on public.quotes
  for each row when (new.status = 'sent' and new.is_template is not true)
  execute function private.issue_on_send();

-- "Resend" / "Make available to sign" from the office or the server (and, as 'promo', the server after
-- the customer applies or removes a promo code on their link): issue the document as it is now
-- (a new version when it changed, else the same one again), answer open change requests, and put a
-- document with changes requested back to waiting for the customer. The sender's access is checked
-- by the API (and, from Phase 1d, its send_pricing area).
create function public.issue_quote_version(p_quote uuid, p_via text default 'sent') returns uuid
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v_id uuid;
begin
  select * into q from public.quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found.' using errcode = 'P0002'; end if;
  if (select auth.uid()) is not null and not (private.has_role(q.company_id, '{owner,admin,office,estimator}') and private.has_perm(q.company_id, 'sales')) then
    raise exception 'Only people who sell can send a document to the customer.' using errcode = '42501';
  end if;
  if q.status not in ('sent', 'changes_requested') or q.is_template then
    raise exception 'Only a document that''s with the customer can be issued again.' using errcode = '22023';
  end if;
  if p_via not in ('sent', 'site_price', 'promo') then
    raise exception 'Unknown way to issue a version.' using errcode = '22023';
  end if;
  v_id := private.issue_version(p_quote, p_via);
  -- A promo code the customer applied on their own link is their own change, like choosing an
  -- option: issued so their page stays current, never an answer to a change request.
  if p_via <> 'promo' then
    perform private.answer_change_requests(p_quote, v_id);
    if q.status = 'changes_requested' then
      update public.quotes set status = 'sent' where id = p_quote;
    end if;
  end if;
  return v_id;
end $$;
revoke execute on function public.issue_quote_version(uuid, text) from public, anon;
grant execute on function public.issue_quote_version(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2. Signing a version
-- ---------------------------------------------------------------------------------------------

-- As in 20261120000100, and: a document with changes requested isn't signed until the office issues
-- it again; on the customer's link only the current issued version signs (not a superseded one, not
-- an unsent draft revision); in person, the document on the screen is issued as it's signed. The
-- signature records its version, and the version that it was signed.
create or replace function private.signed_version() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_version jsonb; v_fingerprint text; v_seen text; v_issued public.quote_versions; v_id uuid;
begin
  if jsonb_typeof(new.approval) is distinct from 'object' or coalesce(new.approval ->> 'method', '') = 'manual' then
    return new;  -- Not the customer's: private.customer_signature_to_accept refuses it.
  end if;
  if not private.is_customer_signature(new.approval) then
    raise exception 'A drawn signature is needed to sign: draw it with a finger, mouse or stylus. A typed name alone doesn''t sign.'
      using errcode = '22023';
  end if;
  if private.is_customer_signature(old.approval) then
    raise exception 'The customer already signed this. Make a new revision (Copy as new draft) for anything that changes, and send that to sign.'
      using errcode = '22023';
  end if;
  if old.status = 'changes_requested' then
    raise exception 'Changes were requested on this document, so signing is paused until the updated version is sent.'
      using errcode = 'CX410';
  end if;
  v_version := private.quote_version(new.id);
  v_fingerprint := md5(v_version::text);
  v_seen := nullif(new.approval ->> 'seen_fingerprint', '');
  if v_seen is null then
    raise exception 'A document is signed only from a page showing its exact version. Open it again and sign there.'
      using errcode = 'CX410';
  end if;
  -- The version now, or (when the customer chose another option as they signed) the version just
  -- before that choice (private.offered_version). Any other change since the page opened refuses it.
  if v_seen <> v_fingerprint and v_seen is distinct from private.offered_version(new.id) then
    raise exception 'This document changed after it was opened, so it wasn''t signed. Look over the latest version and sign that.'
      using errcode = 'CX410';
  end if;
  v_issued := private.current_version(new.id);
  if new.approval ->> 'method' = 'in_person' then
    -- The screen shows the document as it is: that's the version presented and signed.
    v_id := case when v_issued.id is not null and v_issued.fingerprint = v_seen then v_issued.id else private.issue_version(new.id, 'in_person') end;
  else
    if v_issued.id is null or v_issued.fingerprint <> v_seen then
      raise exception 'This isn''t the version that was sent to you, so it wasn''t signed. Open the latest link you were sent.'
        using errcode = 'CX410';
    end if;
    v_id := v_issued.id;
  end if;
  update public.quote_versions set signed_at = now() where id = v_id;
  new.approval := new.approval || jsonb_build_object(
    'signed_at', now(),
    'fingerprint', v_fingerprint,
    'document', v_version,
    'version_id', v_id,
    'version_number', (select number from public.quote_versions where id = v_id),
    'choices', jsonb_build_object(
      'option_id', new.option_id,
      'selected_line_ids', (select coalesce(jsonb_agg(l.id order by l.sort, l.id), '[]') from public.quote_line_items l
                             where l.quote_id = new.id and l.optional and l.selected),
      'subtotal', new.subtotal, 'discount_amount', new.discount_amount, 'tax_amount', new.tax_amount, 'total', new.total));
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. Follow-up tasks and change requests
-- ---------------------------------------------------------------------------------------------

-- A follow-up for the office: who it's for (else the office as a whole), what and where. One per
-- source record, so a retried event never makes a second one.
create table public.follow_up_tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  assigned_to uuid references auth.users (id) on delete set null,
  title text not null check (length(title) between 1 and 300),
  body text check (length(body) <= 4000),
  link text check (length(link) <= 500),
  related_type text check (related_type in ('quote', 'job', 'request')),
  related_id uuid,
  source text not null check (source in ('change_request')),
  source_id uuid not null,
  due_on date,
  done_at timestamptz,
  done_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (source, source_id)
);
create index follow_up_tasks_open_idx on public.follow_up_tasks (company_id, assigned_to) where done_at is null;
create index follow_up_tasks_related_idx on public.follow_up_tasks (related_type, related_id);
alter table public.follow_up_tasks enable row level security;
create policy follow_up_tasks_read on public.follow_up_tasks for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
-- Marking one done (or not) is the office's; the rest is written by the server.
create policy follow_up_tasks_done on public.follow_up_tasks for update to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'))
  with check (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
grant select on public.follow_up_tasks to authenticated;
grant update (done_at, done_by) on public.follow_up_tasks to authenticated;

create table public.quote_change_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  quote_id uuid not null,
  version_id uuid references public.quote_versions (id) on delete set null,
  version_number integer,
  seen_fingerprint text,
  -- The note exactly as the customer typed it.
  message text not null check (length(message) between 1 and 4000),
  client_id uuid,
  -- Who sent it: their own link, or the office's copy of it, and from where.
  identity jsonb not null default '{}' check (jsonb_typeof(identity) = 'object'),
  request_key uuid not null,
  signed_agreement boolean not null default false,
  proposed_change_order_id uuid,
  created_at timestamptz not null default now(),
  response text check (length(response) <= 4000),
  responded_at timestamptz,
  responded_by uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null,
  resolved_version_id uuid references public.quote_versions (id) on delete set null,
  unique (company_id, id),
  unique (quote_id, request_key),
  foreign key (company_id, quote_id) references public.quotes (company_id, id) on delete cascade
);
create index quote_change_requests_quote_idx on public.quote_change_requests (quote_id, created_at);
comment on table public.quote_change_requests is 'Planet Ops: a customer''s "Request changes" note, as typed, on the exact version they reviewed. Never an edit or an acceptance.';
alter table public.quote_change_requests enable row level security;
create policy quote_change_requests_read on public.quote_change_requests for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
grant select on public.quote_change_requests to authenticated;

-- What the customer wrote is kept as written; the office's answer and resolution are added once each
-- way (respond_to_change_request, a version issued).
create function private.change_request_stays() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'A customer''s change request is kept in the history.' using errcode = '22023';
  end if;
  if (to_jsonb(new) - 'response' - 'responded_at' - 'responded_by' - 'resolved_at' - 'resolved_by' - 'resolved_version_id' - 'proposed_change_order_id')
     is distinct from (to_jsonb(old) - 'response' - 'responded_at' - 'responded_by' - 'resolved_at' - 'resolved_by' - 'resolved_version_id' - 'proposed_change_order_id') then
    raise exception 'What the customer wrote is kept as they wrote it.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger change_request_stays before update or delete on public.quote_change_requests
  for each row execute function private.change_request_stays();

-- The people a document's follow-up goes to: its salesperson while they're on the team, else
-- everyone in the office who sells.
create function private.document_owners(p_quote uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  with q as (select company_id, salesperson_id from public.quotes where id = p_quote),
  owner as (
    select m.user_id from public.memberships m, q
     where m.company_id = q.company_id and m.user_id = q.salesperson_id and m.active
  )
  select user_id from owner
  union all
  select m.user_id from public.memberships m, q
   where not exists (select 1 from owner) and m.company_id = q.company_id and m.active
     and m.role in ('owner', 'admin', 'office')
     and 'sales' = any (coalesce((select r.permissions from public.company_roles r where r.id = m.role_id), private.level_permissions(m.role)))
$$;

-- "Request changes" from the customer's link (the server calls it; apps/api/src/routes/public.ts).
-- Returns the request as {id, status, duplicate, change_order_id}.
create function public.request_quote_changes(p_company uuid, p_quote uuid, p_message text, p_request_key uuid, p_seen text, p_identity jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  q public.quotes;
  r public.quote_change_requests;
  v_version public.quote_versions;
  v_signed boolean;
  v_job public.jobs;
  v_co uuid;
  v_assignee uuid;
  v_label text;
  v_owner uuid;
begin
  if p_message is null or length(trim(p_message)) < 3 then
    raise exception 'Tell us what you''d like changed.' using errcode = '22023';
  end if;
  select * into q from public.quotes where company_id = p_company and id = p_quote for update;
  if not found or q.is_template then raise exception 'Quote not found.' using errcode = 'P0002'; end if;
  -- The same request again (a retry, a double tap): what was saved the first time.
  select * into r from public.quote_change_requests where quote_id = p_quote and request_key = p_request_key;
  if found then
    return jsonb_build_object('id', r.id, 'status', q.status, 'duplicate', true, 'change_order_id', r.proposed_change_order_id);
  end if;
  if q.status not in ('sent', 'changes_requested', 'approved', 'converted') then
    raise exception 'This document isn''t open for changes.' using errcode = '22023';
  end if;
  v_signed := q.status in ('approved', 'converted');
  -- The version they reviewed: the signed one, or the one their page showed.
  if v_signed then
    select * into v_version from public.quote_versions where id = nullif(q.approval ->> 'version_id', '')::uuid;
  else
    select * into v_version from public.quote_versions where quote_id = p_quote and fingerprint = p_seen order by number desc limit 1;
    if not found then
      v_version := private.current_version(p_quote);
    end if;
  end if;
  v_label := case when q.change_order_for is not null then 'change order' when q.presentation = 'proposal' then 'proposal' else 'quote' end;

  insert into public.quote_change_requests (company_id, quote_id, version_id, version_number, seen_fingerprint, message, client_id, identity, request_key, signed_agreement)
  values (p_company, p_quote, v_version.id, v_version.number, p_seen, p_message, q.client_id, coalesce(p_identity, '{}'), p_request_key, v_signed)
  returning * into r;

  if not v_signed then
    -- Pending: marked "Changes requested", and signing waits for the office to issue it again.
    if q.status = 'sent' then
      update public.quotes set status = 'changes_requested' where id = p_quote;
    end if;
  else
    -- Signed: the original stays as signed. For an active job, the office gets a proposed change
    -- order (a draft) to price and send; nothing in the agreement changes.
    select * into v_job from public.jobs
     where company_id = p_company and status = 'active'
       and id = coalesce(q.change_order_for, (select j.id from public.jobs j where j.company_id = p_company and j.quote_id = p_quote order by j.created_at limit 1));
    if found then
      insert into public.quotes (company_id, client_id, property_id, title, change_order_for, salesperson_id, status, message)
      values (p_company, v_job.client_id, v_job.property_id, left('Change requested: ' || q.title, 200), v_job.id, q.salesperson_id, 'draft', null)
      returning id into v_co;
      update public.quote_change_requests set proposed_change_order_id = v_co where id = r.id;
    end if;
  end if;

  -- One follow-up task, for the document's salesperson (else the office), and a notification.
  v_assignee := (select m.user_id from public.memberships m where m.company_id = p_company and m.user_id = q.salesperson_id and m.active);
  insert into public.follow_up_tasks (company_id, assigned_to, title, body, link, related_type, related_id, source, source_id, due_on)
  values (p_company, v_assignee,
          left(case when v_signed then 'Customer asked for a change to signed ' || v_label || ' #' || q.number else 'Review the change request on ' || v_label || ' #' || q.number end, 300),
          left(p_message, 4000), '/quotes/' || p_quote, 'quote', p_quote, 'change_request', r.id, current_date)
  on conflict (source, source_id) do nothing;
  -- A pending document's "Changes requested" already tells the office (the notify_changes_requested
  -- automation); its salesperson hears here. A signed one changes no status, so its owners hear here.
  for v_owner in select u from (select v_assignee as u where not v_signed and v_assignee is not null
                                union all select o from private.document_owners(p_quote) o where v_signed) x loop
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    values (p_company, v_owner, 'quote',
            left('Changes requested on ' || v_label || ' #' || q.number || ': ' || q.title, 300), left(p_message, 1000),
            case when v_co is not null then '/quotes/' || v_co else '/quotes/' || p_quote end);
  end loop;
  perform private.emit(p_company, 'quote.change_request', 'quote', p_quote,
    'Customer asked for changes on ' || v_label || ' #' || q.number,
    jsonb_build_object('request_id', r.id, 'version', v_version.number, 'signed', v_signed, 'change_order_id', v_co));
  return jsonb_build_object('id', r.id, 'status', case when v_signed then q.status else 'changes_requested' end, 'duplicate', false, 'change_order_id', v_co);
end $$;
revoke execute on function public.request_quote_changes(uuid, uuid, text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.request_quote_changes(uuid, uuid, text, uuid, text, jsonb) to service_role;

-- The office answers a request: its reply is kept beside the note (once; a later word is a new reply
-- in the timeline's messages). Resolving it without a new version is the office's call too: the
-- document goes back to waiting only when it's issued again (issue_quote_version).
create function public.respond_to_change_request(p_request uuid, p_response text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.quote_change_requests;
begin
  select * into r from public.quote_change_requests where id = p_request for update;
  if not found or not (private.has_role(r.company_id, '{owner,admin,office,estimator}') and private.has_perm(r.company_id, 'sales')) then
    raise exception 'Change request not found.' using errcode = 'P0002';
  end if;
  if p_response is null or length(trim(p_response)) = 0 then
    raise exception 'Write the reply first.' using errcode = '22023';
  end if;
  if r.response is not null then
    raise exception 'This request already has a reply.' using errcode = '22023';
  end if;
  update public.quote_change_requests set response = p_response, responded_at = now(), responded_by = (select auth.uid()) where id = p_request;
  -- A signed agreement's request is answered by the reply (its change order, if any, goes its own way).
  if r.signed_agreement then
    update public.quote_change_requests set resolved_at = now(), resolved_by = (select auth.uid()) where id = p_request and resolved_at is null;
    update public.follow_up_tasks set done_at = now(), done_by = (select auth.uid())
     where source = 'change_request' and source_id = p_request and done_at is null;
  end if;
end $$;
revoke execute on function public.respond_to_change_request(uuid, text) from public, anon;
grant execute on function public.respond_to_change_request(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Documents already with customers: their current version is version 1.
-- ---------------------------------------------------------------------------------------------

insert into public.quote_versions (company_id, quote_id, number, fingerprint, document, presentation, subtotal, discount_amount, tax_amount, total, issued_at, issued_via)
select q.company_id, q.id, 1, md5(private.quote_version(q.id)::text), private.quote_version(q.id), q.presentation,
       q.subtotal, q.discount_amount, q.tax_amount, q.total, coalesce(q.sent_at, now()), 'existing'
  from public.quotes q
 where q.status in ('sent', 'changes_requested') and q.is_template is not true;

revoke execute on function private.quote_version_stays(), private.issue_version(uuid, text), private.current_version(uuid),
  private.answer_change_requests(uuid, uuid), private.issue_on_send(), private.change_request_stays(),
  private.document_owners(uuid) from public;

-- An assistant that sends a quote again issues its version: a change to quotes, as sending is
-- (as in 20261113000950_price_changes.sql, with issue_quote_version added).
create or replace function private.assistant_rpc_area(p_function text) returns text
language sql immutable set search_path = '' as $$
  select case p_function
    when 'apply_price_change' then 'jobs'
    when 'convert_quote_to_job' then 'quotes'
    when 'create_invoice_for_job' then 'invoices'
    when 'duplicate_quote' then 'quotes'
    when 'edit_invoice' then 'invoices'
    when 'issue_quote_version' then 'quotes'
    when 'merge_clients' then 'invoices'
    when 'merge_company_settings' then 'company'
    when 'quote_exact_sent' then 'quotes'
    when 'remove_late_fee' then 'invoices'
    when 'set_checklist_services' then 'checklists'
    when 'set_weather_rules' then 'prices'
    when 'undo_price_change' then 'jobs'
  end
$$;

select private.fold_member_checks('public.quote_versions');
select private.fold_member_checks('public.follow_up_tasks');
select private.fold_member_checks('public.quote_change_requests');
