-- Planet Ops Phase 1e: a job made from the exact signed revision, once
-- (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3 "Creating a job from a customer document", §6 folder timing).
--
-- 1. Converting a signed quote or proposal links the job to its customer and property (as before),
--    the request it came from (jobs.request_id, new) and the exact version the customer signed
--    (jobs.quote_version_id, new: the version the signature recorded, never the latest edit). The
--    customer's signature on that version, and a required countersignature, are still checked as
--    it's converted (20261120000100, 20261120000200); the link is guarded below. Linking an internal
--    estimate is deferred to Phase 3;
--    nothing here invents one.
-- 2. Converting again opens the job it made: a repeated click, a retried request, or two at once
--    (the quote is locked while it's converted; the second waits, then finds the job). A quote has
--    one job: a unique index holds it to that.
-- 3. The job-created handoff for folders (Phase 4's Drive work): one provisioning record per job,
--    pending, made as the job is created, whether by Create Job or by converting a document, so both
--    go through the same workflow. Creating or sending an estimate or quote, or signing one, makes
--    none: only a job does. No folders are made here.

alter table public.jobs add column request_id uuid;
alter table public.jobs add constraint jobs_request_fkey foreign key (company_id, request_id)
  references public.requests (company_id, id) on delete set null (request_id);
alter table public.jobs add column quote_version_id uuid;
alter table public.jobs add constraint jobs_quote_version_fkey foreign key (company_id, quote_version_id)
  references public.quote_versions (company_id, id) on delete set null (quote_version_id);
comment on column public.jobs.request_id is 'Planet Ops: the request the job''s quote came from, set as it''s converted.';
comment on column public.jobs.quote_version_id is 'Planet Ops: the exact version of the quote, proposal or change order the customer signed, which the job was made from.';

-- The signed version a job was made from is set only by converting the signed document, once, and
-- is never another quote's version, an unsigned one, or a version the signature didn't record:
--   - convert_quote_to_job (below) is the one way it's set: that function runs as its owner, marks
--     the quote it's converting for the rest of its transaction, and inserts the job with the
--     version. Anything else that sets it (signed-in staff, the API, an assistant, the server's
--     service role, even with the right quote and version, or the marker) isn't the function's
--     owner and is refused. It's also checked to be the exact version the job's own quote was signed
--     on (quotes.approval ->> 'version_id', signed_at set), in the job's company, while that quote
--     is signed and not yet converted.
--   - afterwards nobody sets, clears or replaces it, nor moves the job to another quote under it. A
--     job without one (Create Job, or made before versions were kept) stays without one: no signed
--     history is invented for it.
--   - only when the version itself is gone (its quote or company deleted) does the link go with it.
-- Whether a version or quote still exists, whatever its reader may see.
create function private.signed_link_target_exists(p_version uuid, p_quote uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when p_version is not null then exists (select 1 from public.quote_versions where id = p_version)
              else exists (select 1 from public.quotes where id = p_quote) end
$$;
-- Runs as whoever is writing (not as its owner), so it can tell the conversion from anyone else.
create function private.job_signed_version_stays() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare q public.quotes; v public.quote_versions; v_converter name;
begin
  if tg_op = 'UPDATE' then
    if old.quote_version_id is not null then
      if new.quote_version_id is distinct from old.quote_version_id
         and not (new.quote_version_id is null and not private.signed_link_target_exists(old.quote_version_id, null)) then
        raise exception 'A job keeps the signed version it was made from.' using errcode = '22023';
      end if;
      if new.quote_id is distinct from old.quote_id
         and not (new.quote_id is null and not private.signed_link_target_exists(null, old.quote_id)) then
        raise exception 'A job made from a signed version stays with the quote it was signed on.' using errcode = '22023';
      end if;
      return new;
    end if;
    if new.quote_version_id is not null then
      raise exception 'A job''s signed version is set only as a signed document is converted.' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.quote_version_id is null then
    return new;
  end if;
  select pg_get_userbyid(p.proowner) into v_converter from pg_proc p where p.oid = 'public.convert_quote_to_job(uuid)'::regprocedure;
  if current_user is distinct from v_converter or new.quote_id is null
     or current_setting('planet_ops.converting_quote', true) is distinct from new.quote_id::text then
    raise exception 'A job''s signed version is set only as a signed document is converted.' using errcode = '22023';
  end if;
  select * into q from public.quotes where id = new.quote_id and company_id = new.company_id;
  select * into v from public.quote_versions where id = new.quote_version_id and company_id = new.company_id;
  if q.id is null or v.id is null or v.quote_id <> q.id then
    raise exception 'A job''s signed version must be a version of its own quote.' using errcode = '22023';
  end if;
  if v.signed_at is null or q.status <> 'approved' or (q.approval ->> 'version_id') is distinct from v.id::text then
    raise exception 'A job''s signed version must be the exact version its quote was signed on.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger jobs_signed_version_stays before insert or update of quote_version_id, quote_id on public.jobs
  for each row execute function private.job_signed_version_stays();
revoke execute on function private.signed_link_target_exists(uuid, uuid) from public;
grant execute on function private.signed_link_target_exists(uuid, uuid) to authenticated, service_role;

-- One job per quote, where that already holds (it does, as convert_quote_to_job makes one); a
-- database with an old duplicate keeps working and is told so.
do $$
begin
  if exists (select 1 from public.jobs where quote_id is not null group by quote_id having count(*) > 1) then
    raise notice 'Some quotes have more than one job already; jobs_one_per_quote is not created.';
  else
    create unique index jobs_one_per_quote on public.jobs (quote_id) where quote_id is not null;
  end if;
end $$;

-- As in 20261101000400_quote_schedule.sql, and: converting again returns the job it made; the job
-- records the request and the signed version. It now runs as its owner, the only one allowed to
-- link a job to its signed version (above), and checks for itself who may convert: the same people
-- its quote and job rules let convert before (owners, admins, office and estimators with the sales
-- area; the server). Anyone else is told the quote isn't found, as before.
create or replace function public.convert_quote_to_job(p_quote uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v_job uuid; v_label text; v_today date; v_repeats boolean; v_version uuid;
begin
  -- Locked while it's converted: a second click or request waits here, then finds the job.
  select * into q from public.quotes where id = p_quote for update;
  if not found or ((select auth.uid()) is not null
                   and not (private.has_role(q.company_id, '{owner,admin,office,estimator}') and private.has_perm(q.company_id, 'sales'))) then
    raise exception 'Quote not found' using errcode = 'P0002';
  end if;
  if q.status = 'converted' then
    v_job := case when q.change_order_for is not null then q.change_order_for
                  else (select j.id from public.jobs j where j.company_id = q.company_id and j.quote_id = q.id order by j.created_at limit 1) end;
    if v_job is not null then
      return v_job;
    end if;
    raise exception 'This quote is already converted' using errcode = '22023';
  end if;
  if q.status in ('lost', 'archived') then
    raise exception 'This quote is already %', q.status using errcode = '22023';
  end if;
  if q.status <> 'approved' and exists (select 1 from public.quote_options where quote_id = q.id) then
    raise exception 'This estimate offers options. Mark it approved with the option they chose first.' using errcode = '22023';
  end if;
  if q.change_order_for is not null then
    return private.apply_change_order(q.id);
  end if;

  -- The version the customer signed (signed before versions were kept: none to link).
  select v.id into v_version from public.quote_versions v
   where v.company_id = q.company_id and v.quote_id = q.id and v.id = nullif(q.approval ->> 'version_id', '')::uuid and v.signed_at is not null;

  v_repeats := q.recurrence_rule is not null;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date into v_today from public.companies c where c.id = q.company_id;
  -- Marks this quote as the one being converted, for the guard on the job's signed version.
  perform set_config('planet_ops.converting_quote', q.id::text, true);
  insert into public.jobs (company_id, client_id, property_id, quote_id, request_id, quote_version_id, title, instructions, kind, recurrence_rule, active_months, starts_on, ends_on, billing_mode)
  values (
    q.company_id, q.client_id, q.property_id, q.id, q.request_id, v_version, q.title, q.message,
    case when v_repeats then 'recurring' else 'one_off' end,
    q.recurrence_rule,
    case when v_repeats then q.active_months end,
    case when v_repeats then greatest(coalesce(q.starts_on, v_today), v_today) end,
    case when v_repeats then q.ends_on end,
    case when v_repeats then 'per_visit' else 'on_completion' end
  )
  returning id into v_job;
  perform set_config('planet_ops.converting_quote', '', true);

  insert into public.job_line_items (company_id, job_id, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, sort)
  select company_id, v_job, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, sort
  from public.quote_line_items where quote_id = q.id and selected;
  select coalesce('Promo code ' || p.code, 'Discount') into v_label from public.promo_codes p where p.id = q.promo_code_id;
  perform private.carry_quote_discount(q.id, v_job, coalesce(v_label, 'Discount'));

  update public.quotes set status = 'converted', converted_at = now() where id = q.id;
  if q.request_id is not null then
    update public.requests set status = 'converted' where id = q.request_id;
  end if;
  update public.clients set status = 'active' where id = q.client_id and status = 'lead';
  return v_job;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. The job-created handoff for its folders (Phase 4 does the Drive work)
-- ---------------------------------------------------------------------------------------------

create table public.job_folder_provisioning (
  job_id uuid primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  -- How the job came to be: Create Job, or a signed document converted.
  source text not null check (source in ('direct', 'converted')),
  status text not null default 'pending' check (status in ('pending', 'in_progress', 'done', 'failed')),
  attempts integer not null default 0,
  last_error text,
  folder_name text,
  folder_id text,
  media_folder_id text,
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade
);
comment on table public.job_folder_provisioning is 'Planet Ops: one record per job, made as the job is created (Create Job or a conversion alike), for the Jobs Awarded folders Phase 4 provisions. Quotes, estimates and signatures make none.';
alter table public.job_folder_provisioning enable row level security;
create policy job_folder_provisioning_read on public.job_folder_provisioning for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
grant select on public.job_folder_provisioning to authenticated;

create function private.job_created_handoff() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.job_folder_provisioning (job_id, company_id, source)
  values (new.id, new.company_id, case when new.quote_id is not null then 'converted' else 'direct' end)
  on conflict (job_id) do nothing;
  return null;
end $$;
create trigger job_created_handoff after insert on public.jobs
  for each row execute function private.job_created_handoff();

revoke execute on function private.job_created_handoff() from public;
select private.fold_member_checks('public.job_folder_provisioning');

notify pgrst, 'reload schema';
