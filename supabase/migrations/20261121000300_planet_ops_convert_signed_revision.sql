-- Planet Ops Phase 1e: a job made from the exact signed revision, once
-- (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3 "Creating a job from a customer document", §6 folder timing).
--
-- 1. Converting a signed quote or proposal links the job to its customer and property (as before),
--    the request it came from (jobs.request_id, new) and the exact version the customer signed
--    (jobs.quote_version_id, new: the version the signature recorded, never the latest edit). The
--    customer's signature on that version, and a required countersignature, are still checked as
--    it's converted (20261120000100, 20261120000200). An internal estimate record arrives in Phase 3;
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
-- records the request and the signed version.
create or replace function public.convert_quote_to_job(p_quote uuid) returns uuid
language plpgsql security invoker set search_path = '' as $$
declare q public.quotes; v_job uuid; v_label text; v_today date; v_repeats boolean; v_version uuid;
begin
  -- Locked while it's converted: a second click or request waits here, then finds the job.
  select * into q from public.quotes where id = p_quote for update;
  if not found then
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
