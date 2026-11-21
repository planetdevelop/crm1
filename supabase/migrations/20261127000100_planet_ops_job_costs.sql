-- Planet Ops Phase 4: job costs, disposal, and the PDOS file record (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md
-- §6, docs/planet-ops/PHASE4_HANDOFF.md). Builds on Crewtavo's expenses, receipt reading and the
-- job-created folder handoff (job_folder_provisioning, 20261121000300).
--
-- 1. public.cost_documents: every uploaded receipt, supplier invoice, dump ticket or job photo kept as
--    its original (path and checksum never change; never deleted by staff). The same file uploaded
--    again (a retry, a second phone) is the same document (one per checksum). A reader's suggestion
--    (vendor, date, total, category, job) is kept apart from what a reviewer decides, and every review
--    step is in public.cost_document_events.
-- 2. Review (job_costs area): approve with one or more job allocations (a multi-job purchase), mark it
--    reference-only, a duplicate of another document, or rejected. Approving makes the job's expenses
--    (one per document and job: a repeated approval replaces them, never adds); allocations can't
--    exceed the document's total. A likely duplicate (same vendor and document number, or vendor, date
--    and total) must be marked as one, or approved with a reason it isn't.
-- 3. expenses.cost_status: committed (e.g. a signed subcontract), provisional (entered, not reviewed),
--    approved (reviewed actual), paid. Existing expenses are approved, as Crewtavo counted them.
-- 4. public.disposal_tickets: the disposal register. Weight (gross, tare, net, short tons), reported loose
--    volume, nominal container capacity and the load are separate fields; metal weight may be unknown;
--    delivered fill is not outgoing debris. A ticket's charges count in job costs only through one
--    linked expense (made with the ticket, or an existing one linked to it): never twice.
-- 5. public.job_financials: each figure apart: the original approved estimate, the job's estimate
--    version and the latest approved revision (budgets), recorded actual costs by status and category,
--    the contract value, invoiced and paid. A figure with no evidence is null, never 0.
-- 6. The PDOS file record (Google Drive is the official record; the app keeps its own copy first):
--    public.pdos_files, one row per file to mirror, with pending / in_progress / backed_up / failed and
--    retries; private.pdos_folder_name, the {Project address} - {Project type} - {Year} name; claims for
--    the server's worker (apps/api/src/services/pdos.ts). Before a job: the estimate's summary goes to
--    Jobs Bid; after Create Job or a signed conversion: the job's folder set, and the summary moves
--    there. Nothing here talks to Google: the worker does, only when it's set up.

-- ---------------------------------------------------------------------------------------------
-- 1. Cost documents
-- ---------------------------------------------------------------------------------------------

create table public.cost_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  job_id uuid,
  kind text not null check (kind in ('receipt', 'supplier_invoice', 'dump_ticket', 'photo', 'other')),
  storage_path text not null check (char_length(storage_path) between 1 and 500),
  file_name text check (char_length(file_name) <= 255),
  checksum text not null check (checksum ~ '^[0-9a-f]{64}$'),
  size_bytes bigint check (size_bytes >= 0),
  uploaded_by uuid references auth.users (id) on delete set null default auth.uid(),
  uploaded_at timestamptz not null default now(),
  -- What the reader suggested (kept as it was suggested).
  suggested jsonb,
  suggested_at timestamptz,
  -- What the reviewer decided.
  vendor text check (char_length(vendor) <= 200),
  document_number text check (char_length(document_number) <= 100),
  document_date date,
  total numeric(12, 2),
  tax_amount numeric(12, 2),
  category text check (char_length(category) <= 60),
  review_status text not null default 'pending' check (review_status in ('pending', 'approved', 'reference_only', 'duplicate', 'rejected')),
  duplicate_of uuid,
  not_duplicate_reason text check (char_length(not_duplicate_reason) <= 500),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text check (char_length(review_note) <= 1000),
  unique (company_id, id),
  unique (company_id, checksum),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete set null (job_id),
  foreign key (company_id, duplicate_of) references public.cost_documents (company_id, id)
);
comment on table public.cost_documents is 'Planet Ops: an uploaded receipt, supplier invoice, dump ticket or job photo, kept as its original. Suggestions apart from the review; approving makes the job''s expenses.';
create index cost_documents_job_idx on public.cost_documents (company_id, job_id);
create index cost_documents_review_idx on public.cost_documents (company_id, review_status, uploaded_at);

create table public.cost_document_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  document_id uuid not null,
  kind text not null check (kind in ('uploaded', 'uploaded_again', 'suggested', 'reviewed', 'reopened')),
  detail jsonb not null default '{}',
  actor_id uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  foreign key (company_id, document_id) references public.cost_documents (company_id, id) on delete cascade
);
comment on table public.cost_document_events is 'Planet Ops: what happened to a cost document: uploaded, suggested, reviewed (from and to), reopened. Kept as it happened.';
create index cost_document_events_doc_idx on public.cost_document_events (document_id, created_at);

-- Who sees what: the office with job costs sees every document; anyone sees the ones they uploaded.
alter table public.cost_documents enable row level security;
alter table public.cost_document_events enable row level security;
create policy cost_documents_read on public.cost_documents for select to authenticated
  using (private.is_member(company_id) and (uploaded_by = (select auth.uid()) or (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs'))));
create policy cost_document_events_read on public.cost_document_events for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs'));
revoke all on public.cost_documents, public.cost_document_events from anon, authenticated;
grant select on public.cost_documents, public.cost_document_events to authenticated;

-- The original stays: its file, checksum and who uploaded it never change; documents aren't deleted
-- (their job's deletion only unlinks them).
create function private.cost_document_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'A cost document''s original is kept. Mark it rejected or a duplicate instead.' using errcode = '22023';
  end if;
  if (new.storage_path, new.checksum, new.uploaded_by, new.uploaded_at, new.company_id) is distinct from (old.storage_path, old.checksum, old.uploaded_by, old.uploaded_at, old.company_id) then
    raise exception 'A cost document''s original file is kept as it was uploaded.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger cost_document_stays before update or delete on public.cost_documents for each row execute function private.cost_document_stays();
create function private.cost_document_event_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  raise exception 'A cost document''s history is kept as it happened.' using errcode = '22023';
end $$;
create trigger cost_document_event_stays before update or delete on public.cost_document_events for each row execute function private.cost_document_event_stays();

create function private.cost_reviewer(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is null or (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'job_costs'))
$$;

-- Registers an uploaded file (already stored at p_path) as a cost document. Anyone on the team may, for
-- a job they can see; the same file again returns the same document (duplicate = true), never a second.
create function public.register_cost_document(p_company uuid, p_kind text, p_path text, p_checksum text, p_file_name text default null,
  p_size bigint default null, p_job uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.cost_documents;
begin
  if not private.is_member(p_company) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if p_job is not null and not exists (select 1 from public.jobs j where j.id = p_job and j.company_id = p_company)
     or p_job is not null and (select auth.uid()) is not null and not private.cost_reviewer(p_company)
        and not exists (select 1 from private.my_visits() v where v.job_id = p_job) then
    raise exception 'That job isn''t one you can add files to.' using errcode = '42501';
  end if;
  if p_path is null or position(p_company::text in p_path) <> 1 then
    raise exception 'The file must be in this business''s storage.' using errcode = '22023';
  end if;
  select * into d from public.cost_documents where company_id = p_company and checksum = lower(p_checksum);
  if d.id is not null then
    insert into public.cost_document_events (company_id, document_id, kind, detail) values (p_company, d.id, 'uploaded_again', jsonb_build_object('path', p_path, 'job_id', p_job));
    return jsonb_build_object('id', d.id, 'duplicate', true, 'job_id', d.job_id, 'review_status', d.review_status);
  end if;
  begin
    insert into public.cost_documents (company_id, job_id, kind, storage_path, file_name, checksum, size_bytes)
    values (p_company, p_job, p_kind, p_path, nullif(btrim(coalesce(p_file_name, '')), ''), lower(p_checksum), p_size)
    returning * into d;
  exception when unique_violation then
    select * into d from public.cost_documents where company_id = p_company and checksum = lower(p_checksum);
    return jsonb_build_object('id', d.id, 'duplicate', true, 'job_id', d.job_id, 'review_status', d.review_status);
  when check_violation then
    raise exception 'That file can''t be registered: its kind is receipt, supplier invoice, dump ticket, photo or other, with a SHA-256 checksum.' using errcode = '22023';
  end;
  insert into public.cost_document_events (company_id, document_id, kind, detail) values (p_company, d.id, 'uploaded', jsonb_build_object('kind', p_kind, 'job_id', p_job));
  return jsonb_build_object('id', d.id, 'duplicate', false, 'job_id', d.job_id, 'review_status', d.review_status);
end $$;

-- The reader's suggestion (vendor, document_number, date, total, tax, category, job_id, confidence,
-- missing): kept as suggested, for the reviewer to accept or correct. The server, or a reviewer.
create function public.suggest_cost_document(p_document uuid, p_suggested jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.cost_documents;
begin
  select * into d from public.cost_documents where id = p_document for update;
  if not found or not private.cost_reviewer(d.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if jsonb_typeof(p_suggested) is distinct from 'object' then raise exception 'A suggestion is an object.' using errcode = '22023'; end if;
  update public.cost_documents set suggested = p_suggested, suggested_at = now() where id = d.id;
  insert into public.cost_document_events (company_id, document_id, kind, detail) values (d.company_id, d.id, 'suggested', p_suggested);
end $$;

-- Documents that look like this one: the same vendor and document number, or the same vendor, date and
-- total (from the review or the suggestion).
create function public.cost_document_duplicates(p_document uuid, p_vendor text default null, p_number text default null, p_date date default null, p_total numeric default null)
returns table (id uuid, vendor text, document_number text, document_date date, total numeric, review_status text, job_id uuid, why text)
language plpgsql stable security definer set search_path = '' as $$
declare d public.cost_documents; v_vendor text; v_number text; v_date date; v_total numeric;
begin
  select * into d from public.cost_documents c where c.id = p_document;
  if not found or not private.cost_reviewer(d.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  v_vendor := lower(btrim(coalesce(p_vendor, d.vendor, d.suggested ->> 'vendor', '')));
  v_number := lower(btrim(coalesce(p_number, d.document_number, d.suggested ->> 'document_number', '')));
  v_date := coalesce(p_date, d.document_date, nullif(d.suggested ->> 'document_date', '')::date);
  v_total := coalesce(p_total, d.total, nullif(d.suggested ->> 'total', '')::numeric);
  return query
  select c.id, c.vendor, c.document_number, c.document_date, c.total, c.review_status, c.job_id,
         case when v_number <> '' and lower(btrim(coalesce(c.document_number, ''))) = v_number then 'same vendor and document number' else 'same vendor, date and total' end
    from public.cost_documents c
   where c.company_id = d.company_id and c.id <> d.id and c.review_status in ('approved', 'pending', 'reference_only')
     and v_vendor <> '' and lower(btrim(coalesce(c.vendor, ''))) = v_vendor
     and ((v_number <> '' and lower(btrim(coalesce(c.document_number, ''))) = v_number)
          or (v_date is not null and v_total is not null and c.document_date = v_date and c.total = v_total));
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. Expenses: status, their document, their ticket
-- ---------------------------------------------------------------------------------------------

alter table public.expenses add column cost_status text not null default 'approved' check (cost_status in ('committed', 'provisional', 'approved', 'paid'));
alter table public.expenses add column cost_document_id uuid;
alter table public.expenses add constraint expenses_cost_document_fkey foreign key (company_id, cost_document_id) references public.cost_documents (company_id, id);
create unique index expenses_one_per_document_job on public.expenses (cost_document_id, job_id) where cost_document_id is not null;
comment on column public.expenses.cost_status is 'Planet Ops: committed (e.g. a signed subcontract, not yet a cost), provisional (entered, not reviewed), approved (a reviewed actual), paid.';
comment on column public.expenses.cost_document_id is 'Planet Ops: the cost document this expense is the job''s share of (review_cost_document makes these; one per document and job).';

-- An expense made from a document is the review's: staff don't edit its amount, job or document by hand.
create function private.expense_document_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then return coalesce(new, old); end if;
  if tg_op = 'INSERT' and new.cost_document_id is not null
     or tg_op = 'UPDATE' and old.cost_document_id is not null and (new.amount, new.job_id, new.cost_document_id) is distinct from (old.amount, old.job_id, old.cost_document_id)
     or tg_op = 'UPDATE' and old.cost_document_id is null and new.cost_document_id is not null
     or tg_op = 'DELETE' and old.cost_document_id is not null then
    raise exception 'This cost comes from a reviewed document: change it by reviewing the document again.' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger expense_document_guard before insert or update or delete on public.expenses for each row execute function private.expense_document_guard();

-- Approves, corrects or sets aside a document. p_allocations: [{job_id, amount, description?}] (approve
-- only); their sum can't exceed the document's total (credits: their sum is between the total and 0).
create function public.review_cost_document(p_document uuid, p_decision text, p_review jsonb default '{}', p_allocations jsonb default '[]') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.cost_documents;
  v_total numeric; v_sum numeric := 0; a jsonb; v_job uuid; v_amount numeric;
  v_dup uuid; v_reason text; v_candidates integer;
  v_category text; v_vendor text; v_number text; v_date date;
  v_before jsonb;
begin
  select * into d from public.cost_documents where id = p_document for update;
  if not found or not private.cost_reviewer(d.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if p_decision not in ('approved', 'reference_only', 'duplicate', 'rejected', 'pending') then
    raise exception 'Approve, reference only, duplicate, rejected, or back to pending.' using errcode = '22023';
  end if;
  v_before := jsonb_build_object('review_status', d.review_status, 'category', d.category, 'total', d.total, 'vendor', d.vendor);
  v_vendor := nullif(btrim(coalesce(p_review ->> 'vendor', d.vendor, d.suggested ->> 'vendor', '')), '');
  v_number := nullif(btrim(coalesce(p_review ->> 'document_number', d.document_number, d.suggested ->> 'document_number', '')), '');
  begin
    v_date := coalesce(nullif(p_review ->> 'document_date', '')::date, d.document_date, nullif(d.suggested ->> 'document_date', '')::date);
    v_total := coalesce(nullif(p_review ->> 'total', '')::numeric, d.total, nullif(d.suggested ->> 'total', '')::numeric);
  exception when others then
    raise exception 'The date or total isn''t valid.' using errcode = '22023';
  end;
  v_category := nullif(btrim(coalesce(p_review ->> 'category', d.category, d.suggested ->> 'category', '')), '');
  v_reason := nullif(btrim(coalesce(p_review ->> 'not_duplicate_reason', '')), '');
  v_dup := nullif(p_review ->> 'duplicate_of', '')::uuid;

  if p_decision = 'duplicate' then
    if v_dup is null or v_dup = d.id or not exists (select 1 from public.cost_documents where id = v_dup and company_id = d.company_id) then
      raise exception 'Say which document this one duplicates.' using errcode = '22023';
    end if;
  end if;
  if p_decision = 'approved' then
    if v_total is null then raise exception 'Approving needs the document''s total.' using errcode = '22023'; end if;
    if jsonb_typeof(p_allocations) is distinct from 'array' or jsonb_array_length(p_allocations) = 0 then
      raise exception 'Approving needs at least one job and amount.' using errcode = '22023';
    end if;
    select count(*) into v_candidates from public.cost_document_duplicates(d.id, v_vendor, v_number, v_date, v_total);
    if v_candidates > 0 and v_reason is null then
      raise exception 'This looks like a document already entered. Mark it a duplicate, or say why it isn''t one.' using errcode = '22023';
    end if;
    for a in select * from jsonb_array_elements(p_allocations) loop
      begin
        v_job := (a ->> 'job_id')::uuid; v_amount := (a ->> 'amount')::numeric;
      exception when others then raise exception 'Each allocation needs a job and an amount.' using errcode = '22023';
      end;
      if v_job is null or v_amount is null or not exists (select 1 from public.jobs j where j.id = v_job and j.company_id = d.company_id) then
        raise exception 'Each allocation needs one of this business''s jobs and an amount.' using errcode = '22023';
      end if;
      if (select count(*) from jsonb_array_elements(p_allocations) x where x ->> 'job_id' = v_job::text) > 1 then
        raise exception 'One allocation per job.' using errcode = '22023';
      end if;
      v_sum := v_sum + v_amount;
    end loop;
    if (v_total >= 0 and (v_sum < 0 or v_sum > v_total)) or (v_total < 0 and (v_sum > 0 or v_sum < v_total)) then
      raise exception 'The jobs'' amounts add up to more than the document''s total (% of %). Leave the rest unallocated (excluded).', v_sum, v_total using errcode = '22023';
    end if;
  end if;

  -- The job shares: replaced, never added (a repeated review is the same review).
  delete from public.expenses where cost_document_id = d.id;
  if p_decision = 'approved' then
    for a in select * from jsonb_array_elements(p_allocations) loop
      insert into public.expenses (company_id, job_id, user_id, vendor, description, category, amount, incurred_on, receipt_path, tax_amount, cost_status, cost_document_id)
      values (d.company_id, (a ->> 'job_id')::uuid, d.uploaded_by, v_vendor, coalesce(nullif(a ->> 'description', ''), v_category, d.kind),
              v_category, (a ->> 'amount')::numeric, coalesce(v_date, d.uploaded_at::date), d.storage_path,
              case when jsonb_array_length(p_allocations) = 1 and v_total = (a ->> 'amount')::numeric then nullif(p_review ->> 'tax_amount', '')::numeric end,
              'approved', d.id);
    end loop;
  end if;
  update public.cost_documents set
    vendor = v_vendor, document_number = v_number, document_date = v_date, total = v_total, category = v_category,
    tax_amount = coalesce(nullif(p_review ->> 'tax_amount', '')::numeric, tax_amount),
    job_id = coalesce(nullif(p_review ->> 'job_id', '')::uuid, case when jsonb_array_length(coalesce(p_allocations, '[]')) = 1 then (p_allocations -> 0 ->> 'job_id')::uuid end, job_id),
    review_status = p_decision, duplicate_of = case when p_decision = 'duplicate' then v_dup end,
    not_duplicate_reason = case when p_decision = 'approved' then v_reason end,
    reviewed_by = case when p_decision = 'pending' then null else (select auth.uid()) end,
    reviewed_at = case when p_decision = 'pending' then null else now() end,
    review_note = nullif(btrim(coalesce(p_review ->> 'note', '')), '')
  where id = d.id;
  insert into public.cost_document_events (company_id, document_id, kind, detail)
  values (d.company_id, d.id, case when p_decision = 'pending' then 'reopened' else 'reviewed' end,
          jsonb_build_object('from', v_before, 'to', jsonb_build_object('review_status', p_decision, 'category', v_category, 'total', v_total, 'vendor', v_vendor),
                             'suggested_category', d.suggested ->> 'category', 'allocations', case when p_decision = 'approved' then p_allocations end));
  return jsonb_build_object('review_status', p_decision, 'allocated', v_sum, 'excluded', case when p_decision = 'approved' then v_total - v_sum end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 4. Disposal register
-- ---------------------------------------------------------------------------------------------

create table public.disposal_tickets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  job_id uuid not null,
  request_key uuid not null,
  direction text not null default 'outgoing' check (direction in ('outgoing', 'delivered_fill')),
  load_date date not null,
  hauler text check (char_length(hauler) <= 200),
  facility text check (char_length(facility) <= 200),
  ticket_number text check (char_length(ticket_number) <= 100),
  material_stream text check (char_length(material_stream) <= 120),
  is_metal boolean not null default false,
  truck text check (char_length(truck) <= 100),
  driver text check (char_length(driver) <= 120),
  gross_lb numeric(12, 2) check (gross_lb >= 0),
  tare_lb numeric(12, 2) check (tare_lb >= 0),
  net_lb numeric(12, 2) check (net_lb >= 0),
  -- Short tons from the ticket (or net ÷ 2000); null when not weighed (a metal load often isn't).
  short_tons numeric(12, 4) check (short_tons >= 0),
  -- The container's nominal capacity: not measured debris.
  container_capacity_cy numeric(10, 2) check (container_capacity_cy >= 0),
  -- A loose volume someone reported (an estimate of the debris, not the container).
  reported_loose_cy numeric(10, 2) check (reported_loose_cy >= 0),
  quantity_basis text not null default 'unknown' check (quantity_basis in ('weighed', 'volume', 'load', 'unknown')),
  hauling_charge numeric(12, 2),
  tipping_fee numeric(12, 2),
  credit_amount numeric(12, 2) check (credit_amount >= 0),
  cost_document_id uuid,
  expense_id uuid unique,
  notes text check (char_length(notes) <= 2000),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, request_key),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  foreign key (company_id, cost_document_id) references public.cost_documents (company_id, id),
  foreign key (company_id, expense_id) references public.expenses (company_id, id) on delete set null (expense_id),
  check (net_lb is null or gross_lb is null or tare_lb is null or net_lb = gross_lb - tare_lb)
);
create unique index disposal_tickets_number on public.disposal_tickets (company_id, lower(coalesce(facility, '')), lower(ticket_number)) where ticket_number is not null;
comment on table public.disposal_tickets is 'Planet Ops: the disposal register. Weight, reported loose volume, nominal container capacity and the load are separate; charges count in job costs only through the one linked expense.';
alter table public.disposal_tickets enable row level security;
create policy disposal_tickets_read on public.disposal_tickets for select to authenticated
  using (private.is_member(company_id) and (created_by = (select auth.uid()) or (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs'))));
revoke all on public.disposal_tickets from anon, authenticated;
grant select on public.disposal_tickets to authenticated;

-- Records a ticket (a retried save with the same key returns it). p_cost: 'new' makes its expense from
-- its charges (provisional until reviewed), 'link' takes p_expense (already entered from the ticket's
-- receipt), 'none' records the quantities only. A ticket number already on file at that facility is
-- that ticket, not a second one.
create function public.record_disposal_ticket(p_job uuid, p_request_key uuid, p_ticket jsonb, p_cost text default 'none', p_expense uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare j public.jobs; t public.disposal_tickets; v_net numeric; v_tons numeric; v_expense uuid; v_charge numeric;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not private.cost_reviewer(j.company_id) then
    if not (found and private.is_member(j.company_id) and exists (select 1 from private.my_visits() v where v.job_id = p_job)) then
      raise exception 'Not found.' using errcode = 'P0002';
    end if;
    if p_cost <> 'none' then raise exception 'Costs are entered by the office (Job costs).' using errcode = '42501'; end if;
  end if;
  if p_request_key is null then raise exception 'A ticket needs its request key.' using errcode = '22023'; end if;
  select * into t from public.disposal_tickets where company_id = j.company_id and request_key = p_request_key;
  if t.id is not null then return t.id; end if;
  if nullif(btrim(coalesce(p_ticket ->> 'ticket_number', '')), '') is not null then
    select * into t from public.disposal_tickets where company_id = j.company_id and lower(ticket_number) = lower(btrim(p_ticket ->> 'ticket_number'))
       and lower(coalesce(facility, '')) = lower(btrim(coalesce(p_ticket ->> 'facility', '')));
    if t.id is not null then
      if t.job_id <> p_job then raise exception 'Ticket % from that facility is already on job %.', t.ticket_number, (select number from public.jobs where id = t.job_id) using errcode = '22023'; end if;
      return t.id;
    end if;
  end if;
  if p_cost not in ('none', 'new', 'link') then raise exception 'Cost: none, new or link.' using errcode = '22023'; end if;
  begin
    v_net := coalesce(nullif(p_ticket ->> 'net_lb', '')::numeric, nullif(p_ticket ->> 'gross_lb', '')::numeric - nullif(p_ticket ->> 'tare_lb', '')::numeric);
    v_tons := coalesce(nullif(p_ticket ->> 'short_tons', '')::numeric, round(v_net / 2000, 4));
    insert into public.disposal_tickets (company_id, job_id, request_key, direction, load_date, hauler, facility, ticket_number, material_stream, is_metal, truck, driver,
      gross_lb, tare_lb, net_lb, short_tons, container_capacity_cy, reported_loose_cy, quantity_basis, hauling_charge, tipping_fee, credit_amount, cost_document_id, notes)
    values (j.company_id, p_job, p_request_key, coalesce(nullif(p_ticket ->> 'direction', ''), 'outgoing'), coalesce(nullif(p_ticket ->> 'load_date', '')::date, private.company_today(j.company_id)),
      nullif(btrim(coalesce(p_ticket ->> 'hauler', '')), ''), nullif(btrim(coalesce(p_ticket ->> 'facility', '')), ''), nullif(btrim(coalesce(p_ticket ->> 'ticket_number', '')), ''),
      nullif(btrim(coalesce(p_ticket ->> 'material_stream', '')), ''), coalesce((p_ticket ->> 'is_metal')::boolean, false),
      nullif(p_ticket ->> 'truck', ''), nullif(p_ticket ->> 'driver', ''),
      nullif(p_ticket ->> 'gross_lb', '')::numeric, nullif(p_ticket ->> 'tare_lb', '')::numeric, v_net, v_tons,
      nullif(p_ticket ->> 'container_capacity_cy', '')::numeric, nullif(p_ticket ->> 'reported_loose_cy', '')::numeric,
      case when v_tons is not null then 'weighed' else coalesce(nullif(p_ticket ->> 'quantity_basis', ''), 'unknown') end,
      nullif(p_ticket ->> 'hauling_charge', '')::numeric, nullif(p_ticket ->> 'tipping_fee', '')::numeric, nullif(p_ticket ->> 'credit_amount', '')::numeric,
      nullif(p_ticket ->> 'cost_document_id', '')::uuid, nullif(p_ticket ->> 'notes', ''))
    returning * into t;
  exception
    when unique_violation then
      select * into t from public.disposal_tickets where company_id = j.company_id and request_key = p_request_key;
      if t.id is not null then return t.id; end if;
      raise exception 'That ticket number from that facility is already recorded.' using errcode = '22023';
    when check_violation or invalid_text_representation or numeric_value_out_of_range or datatype_mismatch then
      raise exception 'A ticket value isn''t valid: weights, volumes and charges are numbers (not negative; net = gross − tare), the date is a date.' using errcode = '22023';
  end;
  if p_cost = 'new' then
    v_charge := coalesce(t.tipping_fee, 0) + coalesce(t.hauling_charge, 0) - coalesce(t.credit_amount, 0);
    if t.tipping_fee is null and t.hauling_charge is null and t.credit_amount is null then
      raise exception 'The ticket has no charges to enter as a cost.' using errcode = '22023';
    end if;
    insert into public.expenses (company_id, job_id, vendor, description, category, amount, incurred_on, cost_status)
    values (j.company_id, p_job, coalesce(t.facility, t.hauler), 'Disposal ticket ' || coalesce(t.ticket_number, '(no number)'), 'disposal', v_charge, t.load_date, 'provisional')
    returning id into v_expense;
    update public.disposal_tickets set expense_id = v_expense where id = t.id;
  elsif p_cost = 'link' then
    if p_expense is null or not exists (select 1 from public.expenses e where e.id = p_expense and e.company_id = j.company_id and e.job_id = p_job) then
      raise exception 'Link an expense on this job.' using errcode = '22023';
    end if;
    if exists (select 1 from public.disposal_tickets x where x.expense_id = p_expense) then
      raise exception 'That expense is already another ticket''s cost.' using errcode = '22023';
    end if;
    update public.disposal_tickets set expense_id = p_expense where id = t.id;
  end if;
  return t.id;
end $$;

-- The job's disposal totals, each kept to its meaning. Unknowns are counted, never added as 0.
create function public.job_disposal_totals(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare j public.jobs;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not private.cost_reviewer(j.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return (select jsonb_build_object(
    'loads', count(*) filter (where direction = 'outgoing'),
    'weighed_loads', count(*) filter (where direction = 'outgoing' and short_tons is not null),
    'unweighed_loads', count(*) filter (where direction = 'outgoing' and short_tons is null),
    'weighed_tons', sum(short_tons) filter (where direction = 'outgoing'),
    'metal_tons', sum(short_tons) filter (where direction = 'outgoing' and is_metal),
    'metal_loads_unweighed', count(*) filter (where direction = 'outgoing' and is_metal and short_tons is null),
    'nonmetal_reported_loose_cy', sum(reported_loose_cy) filter (where direction = 'outgoing' and not is_metal),
    'metal_reported_loose_cy', sum(reported_loose_cy) filter (where direction = 'outgoing' and is_metal),
    'nominal_container_capacity_cy', sum(container_capacity_cy) filter (where direction = 'outgoing'),
    'tipping_fees', sum(tipping_fee) filter (where direction = 'outgoing'),
    'hauling_charges', sum(hauling_charge),
    'credits', sum(credit_amount),
    'delivered_fill_loads', count(*) filter (where direction = 'delivered_fill'),
    'delivered_fill_tons', sum(short_tons) filter (where direction = 'delivered_fill'),
    'tickets_without_cost', count(*) filter (where expense_id is null and (tipping_fee is not null or hauling_charge is not null)),
    'disposal_rate_per_ton', case when sum(short_tons) filter (where direction = 'outgoing' and tipping_fee is not null and short_tons is not null) > 0
                                  then round(sum(tipping_fee) filter (where direction = 'outgoing' and tipping_fee is not null and short_tons is not null)
                                             / sum(short_tons) filter (where direction = 'outgoing' and tipping_fee is not null and short_tons is not null), 2) end)
    from public.disposal_tickets where job_id = p_job);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 5. The job's figures, apart
-- ---------------------------------------------------------------------------------------------

create function public.job_financials(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  j public.jobs; v_estimate uuid; b public.estimate_versions; jv public.estimate_versions; r public.estimate_versions;
  v_costs boolean; v_contract jsonb; v_actuals jsonb;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not private.cost_reviewer(j.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  v_costs := private.estimating_can(j.company_id, 'estimate_costs');
  select v.estimate_id into v_estimate from public.estimate_versions v where v.id = j.estimate_version_id;
  select x.* into b from public.estimates e join public.estimate_versions x on x.id = e.baseline_version_id where e.id = v_estimate;
  select * into jv from public.estimate_versions where id = j.estimate_version_id;
  select * into r from public.estimate_versions where estimate_id = v_estimate and status = 'approved' order by number desc limit 1;
  begin
    v_contract := public.job_contract_summary(p_job);
  exception when others then
    v_contract := null;
  end;
  select jsonb_build_object(
    'approved', sum(amount) filter (where cost_status in ('approved', 'paid')),
    'paid', sum(amount) filter (where cost_status = 'paid'),
    'provisional', sum(amount) filter (where cost_status = 'provisional'),
    'committed', sum(amount) filter (where cost_status = 'committed'),
    'count', count(*),
    'by_category', (select coalesce(jsonb_object_agg(coalesce(c, 'uncategorized'), s), '{}') from (
        select category c, sum(amount) s from public.expenses where job_id = p_job and cost_status in ('approved', 'paid') group by category) x))
    into v_actuals from public.expenses where job_id = p_job and not in_line_costs;
  return jsonb_build_object(
    'estimate_costs_visible', v_costs,
    'original_estimate', case when b.id is null then null else jsonb_build_object('version', b.number, 'approved_at', b.approved_at,
        'base_cost', case when v_costs then b.base_cost end, 'selling_price', case when v_costs then b.selling_price end) end,
    'job_estimate', case when jv.id is null then null else jsonb_build_object('version', jv.number, 'status', jv.status,
        'base_cost', case when v_costs then jv.base_cost end, 'selling_price', case when v_costs then jv.selling_price end) end,
    'latest_approved_revision', case when r.id is null or r.id = b.id then null else jsonb_build_object('version', r.number, 'approved_at', r.approved_at,
        'base_cost', case when v_costs then r.base_cost end) end,
    'actual_costs', case when (v_actuals ->> 'count')::int = 0 then null else v_actuals end,
    'labor_note', 'Labor from time entries is on the job''s costs card (Phase 6 adds classified time).',
    'disposal', public.job_disposal_totals(p_job),
    'contract_value', v_contract -> 'revised_total',
    'original_contract', v_contract -> 'original_amount',
    'invoiced', v_contract -> 'invoiced',
    'paid', v_contract -> 'paid',
    'outstanding', v_contract -> 'outstanding');
end $$;

-- ---------------------------------------------------------------------------------------------
-- 6. The PDOS file record
-- ---------------------------------------------------------------------------------------------

create table public.pdos_files (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  source_kind text not null check (source_kind in ('estimate_summary', 'cost_document', 'disposal_ticket', 'signed_document', 'job_record')),
  source_id uuid not null,
  job_id uuid,
  estimate_id uuid,
  -- Where it belongs now: Jobs Bid (before a job), or one of the job's folders.
  destination text not null check (destination in ('jobs_bid', 'job_root', 'job_documents', 'job_receipts', 'job_dump_tickets', 'media', 'held')),
  file_name text not null check (char_length(file_name) between 1 and 300),
  version integer not null default 1,
  status text not null default 'pending' check (status in ('pending', 'in_progress', 'backed_up', 'failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text check (char_length(last_error) <= 1000),
  drive_file_id text,
  drive_parent_id text,
  backed_up_version integer,
  backed_up_at timestamptz,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, source_kind, source_id),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete set null (job_id)
);
comment on table public.pdos_files is 'Planet Ops: each file mirrored to the PDOS Google Drive (the official record; the app keeps its own copy first), where it belongs, and its backup state.';
create index pdos_files_due_idx on public.pdos_files (status, next_attempt_at);
alter table public.pdos_files enable row level security;
create policy pdos_files_read on public.pdos_files for select to authenticated using (private.has_role(company_id, '{owner,admin,office}'));
revoke all on public.pdos_files from anon, authenticated;
grant select on public.pdos_files to authenticated;

alter table public.job_folder_provisioning add column next_attempt_at timestamptz not null default now();
alter table public.job_folder_provisioning add column steps jsonb not null default '{}';
alter table public.job_folder_provisioning add column claimed_at timestamptz;
comment on column public.job_folder_provisioning.steps is 'Planet Ops: the Drive ids made so far (folder, each subfolder, media), so a retry resumes the same set.';

-- The folder name: {Project address} - {Project type} - {Year}, the job's creation year; characters
-- Drive or the PDOS index can't take become spaces. Another job with the same name gets this job's
-- number on the end (never merged into it).
create function private.pdos_folder_name(p_job uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare j public.jobs; v_address text; v_type text; v_name text;
begin
  select * into j from public.jobs where id = p_job;
  select nullif(btrim(p.line1), '') into v_address from public.properties p where p.id = j.property_id;
  select nullif(btrim(e.project_type), '') into v_type from public.estimate_versions v join public.estimates e on e.id = v.estimate_id where v.id = j.estimate_version_id;
  v_name := coalesce(v_address, 'No address') || ' - ' || coalesce(v_type, nullif(btrim(j.title), ''), 'Project') || ' - ' || extract(year from j.created_at)::int;
  v_name := btrim(regexp_replace(regexp_replace(v_name, '[\\/:*?"<>|#%\r\n\t]+', ' ', 'g'), '\s+', ' ', 'g'));
  if exists (select 1 from public.job_folder_provisioning f where f.company_id = j.company_id and f.job_id <> j.id and lower(f.folder_name) = lower(v_name)) then
    v_name := v_name || ' - Job ' || coalesce(j.number::text, left(j.id::text, 8));
  end if;
  return left(v_name, 250);
end $$;

-- Queueing: the estimate's summary goes to Jobs Bid when it's made, and to the job's Documents & Permits
-- once a job is made from it (the same file: the worker moves it, keeping its Drive id). A cost document
-- goes to the job's Reciepts or Dump Tickets (photos to Media), and waits (held) until it has a job.
create function private.pdos_queue_summary() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.pdos_files (company_id, source_kind, source_id, estimate_id, job_id, destination, file_name)
  values (new.company_id, 'estimate_summary', new.id, new.estimate_id, new.job_id, case when new.job_id is null then 'jobs_bid' else 'job_documents' end, new.title || '.html')
  on conflict (company_id, source_kind, source_id) do update
     set destination = excluded.destination, job_id = excluded.job_id, file_name = excluded.file_name,
         version = public.pdos_files.version + 1, status = 'pending', attempts = 0, next_attempt_at = now(), last_error = null, updated_at = now();
  return null;
end $$;
-- Every change to the summary (a save, an approval, a document, its job) is a new version to copy;
-- the worker copies the latest one, so a burst of saves is one copy.
create trigger pdos_queue_summary after insert on public.estimate_summaries
  for each row execute function private.pdos_queue_summary();
create trigger pdos_queue_summary_change after update on public.estimate_summaries
  for each row when ((old.job_id, old.title, old.updated_at) is distinct from (new.job_id, new.title, new.updated_at)) execute function private.pdos_queue_summary();

create function private.pdos_queue_document() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.job_id is not distinct from old.job_id then return null; end if;
  insert into public.pdos_files (company_id, source_kind, source_id, job_id, destination, file_name)
  values (new.company_id, 'cost_document', new.id, new.job_id,
          case when new.job_id is null then 'held' when new.kind = 'dump_ticket' then 'job_dump_tickets' when new.kind = 'photo' then 'media' else 'job_receipts' end,
          coalesce(new.file_name, new.kind || '-' || left(new.id::text, 8)))
  on conflict (company_id, source_kind, source_id) do update
     set destination = excluded.destination, job_id = excluded.job_id, status = 'pending', attempts = 0, next_attempt_at = now(), last_error = null, updated_at = now();
  return null;
end $$;
create trigger pdos_queue_document after insert or update of job_id on public.cost_documents
  for each row execute function private.pdos_queue_document();

-- The server's worker: claims due work (a claim older than 10 minutes is treated as abandoned), and
-- reports each result. Retries back off: 1, 5, 30 minutes, then hourly.
create function public.pdos_claim(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_folders jsonb; v_files jsonb;
begin
  if (select auth.uid()) is not null then raise exception 'Only the server runs Drive backup.' using errcode = '42501'; end if;
  with due as (
    select job_id from public.job_folder_provisioning
     where status in ('pending', 'failed', 'in_progress') and next_attempt_at <= now() and (claimed_at is null or claimed_at < now() - interval '10 minutes')
     order by requested_at limit p_limit for update skip locked),
  claimed as (
    update public.job_folder_provisioning f set status = 'in_progress', claimed_at = now(), attempts = f.attempts + 1,
           folder_name = coalesce(f.folder_name, private.pdos_folder_name(f.job_id))
      from due where f.job_id = due.job_id
    returning f.job_id, f.company_id, f.folder_name, f.steps, f.folder_id, f.media_folder_id)
  select coalesce(jsonb_agg(to_jsonb(claimed)), '[]') into v_folders from claimed;
  with due as (
    select p.id from public.pdos_files p
     where p.status in ('pending', 'failed', 'in_progress') and p.destination <> 'held' and p.next_attempt_at <= now()
       and (p.claimed_at is null or p.claimed_at < now() - interval '10 minutes')
       and (p.destination = 'jobs_bid' or exists (select 1 from public.job_folder_provisioning f where f.job_id = p.job_id and f.status = 'done'))
     order by p.created_at limit p_limit for update skip locked),
  claimed as (
    update public.pdos_files p set status = 'in_progress', claimed_at = now(), attempts = p.attempts + 1, updated_at = now()
      from due where p.id = due.id
    returning p.id, p.company_id, p.source_kind, p.source_id, p.job_id, p.destination, p.file_name, p.version, p.drive_file_id, p.drive_parent_id)
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('folders',
           (select f.steps || jsonb_build_object('folder', f.folder_id, 'media', f.media_folder_id) from public.job_folder_provisioning f where f.job_id = c.job_id))), '[]')
    into v_files from claimed c;
  return jsonb_build_object('folders', v_folders, 'files', v_files);
end $$;

create function public.pdos_folder_progress(p_job uuid, p_steps jsonb, p_done boolean, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null then raise exception 'Only the server runs Drive backup.' using errcode = '42501'; end if;
  update public.job_folder_provisioning f set
    steps = f.steps || coalesce(p_steps, '{}'),
    folder_id = coalesce(p_steps ->> 'folder', f.folder_id), media_folder_id = coalesce(p_steps ->> 'media', f.media_folder_id),
    status = case when p_done then 'done' when p_error is not null then 'failed' else f.status end,
    last_error = case when p_done then null else left(p_error, 1000) end,
    claimed_at = case when p_done or p_error is not null then null else f.claimed_at end,
    next_attempt_at = case when p_error is null then f.next_attempt_at
                           else now() + case when f.attempts <= 1 then interval '1 minute' when f.attempts = 2 then interval '5 minutes' when f.attempts = 3 then interval '30 minutes' else interval '1 hour' end end,
    updated_at = now()
  where f.job_id = p_job;
end $$;

create function public.pdos_file_result(p_id uuid, p_version integer, p_drive_file_id text, p_parent text, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null then raise exception 'Only the server runs Drive backup.' using errcode = '42501'; end if;
  update public.pdos_files p set
    drive_file_id = coalesce(p_drive_file_id, p.drive_file_id), drive_parent_id = coalesce(p_parent, p.drive_parent_id),
    -- A newer version queued while this one was copying stays pending.
    status = case when p_error is not null then 'failed' when p.version > p_version then 'pending' else 'backed_up' end,
    backed_up_version = case when p_error is null then p_version else p.backed_up_version end,
    backed_up_at = case when p_error is null then now() else p.backed_up_at end,
    last_error = case when p_error is null then null else left(p_error, 1000) end,
    claimed_at = null,
    next_attempt_at = case when p_error is null then now()
                           else now() + case when p.attempts <= 1 then interval '1 minute' when p.attempts = 2 then interval '5 minutes' when p.attempts = 3 then interval '30 minutes' else interval '1 hour' end end,
    updated_at = now()
  where p.id = p_id;
end $$;

-- An admin's retry now (Settings → PDOS backup): failed and pending work is due again.
create function public.pdos_retry(p_company uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer; m integer;
begin
  if not ((select auth.uid()) is null or private.has_role(p_company, '{owner,admin}')) then raise exception 'Retrying backup is for owners and admins.' using errcode = '42501'; end if;
  update public.pdos_files set next_attempt_at = now(), updated_at = now() where company_id = p_company and status in ('failed', 'pending');
  get diagnostics n = row_count;
  update public.job_folder_provisioning set next_attempt_at = now(), updated_at = now() where company_id = p_company and status in ('failed', 'pending');
  get diagnostics m = row_count;
  return n + m;
end $$;

-- What's backed up, waiting, or failed (for the status screen).
create function public.pdos_status(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.has_role(p_company, '{owner,admin,office}') then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'configured', coalesce((select (c.settings -> 'pdos' ->> 'enabled')::boolean from public.companies c where c.id = p_company), false),
    'files', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.pdos_files where company_id = p_company group by status) x),
    'held', (select count(*) from public.pdos_files where company_id = p_company and destination = 'held'),
    'folders', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.job_folder_provisioning where company_id = p_company group by status) x),
    'last_backed_up_at', (select max(backed_up_at) from public.pdos_files where company_id = p_company),
    'failures', (select coalesce(jsonb_agg(jsonb_build_object('kind', 'file', 'id', id, 'name', file_name, 'error', last_error, 'attempts', attempts, 'next', next_attempt_at) order by updated_at desc), '[]')
                   from (select * from public.pdos_files where company_id = p_company and status = 'failed' order by updated_at desc limit 50) f)
               || (select coalesce(jsonb_agg(jsonb_build_object('kind', 'folder', 'id', job_id, 'name', folder_name, 'error', last_error, 'attempts', attempts, 'next', next_attempt_at)), '[]')
                   from public.job_folder_provisioning where company_id = p_company and status = 'failed'));
end $$;

-- Existing summaries are queued once (Jobs Bid, or their job's folder).
insert into public.pdos_files (company_id, source_kind, source_id, estimate_id, job_id, destination, file_name)
select s.company_id, 'estimate_summary', s.id, s.estimate_id, s.job_id, case when s.job_id is null then 'jobs_bid' else 'job_documents' end, s.title || '.html'
  from public.estimate_summaries s
on conflict (company_id, source_kind, source_id) do nothing;

revoke execute on function private.cost_document_stays(), private.cost_document_event_stays(), private.cost_reviewer(uuid), private.expense_document_guard(),
  private.pdos_folder_name(uuid), private.pdos_queue_summary(), private.pdos_queue_document() from public;
revoke execute on function public.register_cost_document(uuid, text, text, text, text, bigint, uuid), public.suggest_cost_document(uuid, jsonb),
  public.cost_document_duplicates(uuid, text, text, date, numeric), public.review_cost_document(uuid, text, jsonb, jsonb),
  public.record_disposal_ticket(uuid, uuid, jsonb, text, uuid), public.job_disposal_totals(uuid), public.job_financials(uuid),
  public.pdos_claim(integer), public.pdos_folder_progress(uuid, jsonb, boolean, text), public.pdos_file_result(uuid, integer, text, text, text),
  public.pdos_retry(uuid), public.pdos_status(uuid) from public, anon;
grant execute on function public.register_cost_document(uuid, text, text, text, text, bigint, uuid), public.suggest_cost_document(uuid, jsonb),
  public.cost_document_duplicates(uuid, text, text, date, numeric), public.review_cost_document(uuid, text, jsonb, jsonb),
  public.record_disposal_ticket(uuid, uuid, jsonb, text, uuid), public.job_disposal_totals(uuid), public.job_financials(uuid),
  public.pdos_retry(uuid), public.pdos_status(uuid) to authenticated;
grant execute on function public.pdos_claim(integer), public.pdos_folder_progress(uuid, jsonb, boolean, text), public.pdos_file_result(uuid, integer, text, text, text),
  public.pdos_retry(uuid) to service_role;

select private.fold_member_checks('public.cost_documents');
select private.fold_member_checks('public.cost_document_events');
select private.fold_member_checks('public.disposal_tickets');
select private.fold_member_checks('public.pdos_files');

notify pgrst, 'reload schema';
