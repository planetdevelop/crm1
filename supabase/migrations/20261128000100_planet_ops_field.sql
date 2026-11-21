-- Planet Ops Phase 5: tailgate meetings and machine checks on jobs (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §7).
-- Builds on Crewtavo's crews, visits (private.my_visits), equipment and its bookings, the schedule area
-- (delegated scheduling without payroll: a role with "schedule" and not "timesheets") and
-- equipment_conflicts. Time recording is untouched: a missing or failed check never blocks the clock.
--
-- 1. Tailgate meetings: a template, a meeting for a job (and visit), date, crew and leader, with its
--    topic, discussion, hazards, controls and attachments. Attendees are assigned, then marked attended
--    or absent; each person signs their own acknowledgment (who, when, the content version and its
--    hash, a drawn signature). Nobody signs for someone else. A signature is frozen; changing the
--    content after anyone signed makes the next version (kept in tailgate_versions), and everyone
--    attending must sign that version. A late attendee is added and signs the current version.
-- 2. Machines on a job: an assignment names the machine, the job (and visit), the dates, and the one
--    responsible operator; others may be authorized. Changing the operator ends the assignment and
--    starts another that needs a handover check by the new operator.
-- 3. Machine checklists: versioned templates per machine or machine type (items with yes/no/n.a.,
--    which are critical); a daily (or handover) check answers every item fresh (nothing carried from
--    yesterday), with notes, photos, a meter reading and the operator's signature, against the version
--    it used. A critical "no" puts the machine out of service (status in_shop), opens a defect and
--    tells the people who manage equipment; only they release it, with what was done and who.
-- 4. What's missing: machine_checks_due (assignments without today's check, handovers waiting),
--    tailgate_status (assigned / attended / signed which version), and my_field_day for the employee.

-- ---------------------------------------------------------------------------------------------
-- Who may: run meetings and assign machines (the schedule area, or a crew lead for their crew);
-- manage machines (the equipment area).
-- ---------------------------------------------------------------------------------------------

create function private.runs_field(p_company uuid, p_crew uuid default null) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is null or private.schedules_crew(p_company, p_crew)
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Tailgate meetings
-- ---------------------------------------------------------------------------------------------

create table public.tailgate_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 200),
  topic text check (char_length(topic) <= 4000),
  hazards text check (char_length(hazards) <= 4000),
  controls text check (char_length(controls) <= 4000),
  active boolean not null default true,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (company_id, id)
);

create table public.tailgate_meetings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  job_id uuid not null,
  visit_id uuid,
  crew_id uuid,
  leader_id uuid references auth.users (id) on delete set null,
  meeting_on date not null,
  starts_at timestamptz,
  template_id uuid,
  version integer not null default 1,
  title text not null check (char_length(btrim(title)) between 1 and 200),
  topic text check (char_length(topic) <= 4000),
  discussion text check (char_length(discussion) <= 8000),
  hazards text check (char_length(hazards) <= 4000),
  controls text check (char_length(controls) <= 4000),
  attachments jsonb not null default '[]' check (jsonb_typeof(attachments) = 'array'),
  request_key uuid not null,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, request_key),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  foreign key (company_id, visit_id) references public.visits (company_id, id) on delete set null (visit_id),
  foreign key (company_id, crew_id) references public.crews (company_id, id) on delete set null (crew_id),
  foreign key (company_id, template_id) references public.tailgate_templates (company_id, id) on delete set null (template_id)
);
comment on table public.tailgate_meetings is 'Planet Ops: a tailgate briefing for a job and date. Each version''s content is in tailgate_versions; signatures acknowledge one version.';
create index tailgate_meetings_job_idx on public.tailgate_meetings (company_id, job_id, meeting_on);

create table public.tailgate_versions (
  meeting_id uuid not null,
  company_id uuid not null,
  version integer not null,
  content jsonb not null,
  content_hash text not null,
  reason text check (char_length(reason) <= 500),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (meeting_id, version),
  foreign key (company_id, meeting_id) references public.tailgate_meetings (company_id, id) on delete cascade
);

create table public.tailgate_attendees (
  meeting_id uuid not null,
  company_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'assigned' check (status in ('assigned', 'attended', 'absent')),
  added_late boolean not null default false,
  added_at timestamptz not null default now(),
  primary key (meeting_id, user_id),
  foreign key (company_id, meeting_id) references public.tailgate_meetings (company_id, id) on delete cascade
);

create table public.tailgate_signatures (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  meeting_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  version integer not null,
  content_hash text not null,
  signature text not null check (signature like 'data:image/%' and char_length(signature) between 200 and 500000),
  signed_at timestamptz not null default now(),
  request_key uuid not null,
  unique (meeting_id, user_id, version),
  unique (company_id, request_key),
  foreign key (company_id, meeting_id) references public.tailgate_meetings (company_id, id) on delete cascade,
  foreign key (meeting_id, version) references public.tailgate_versions (meeting_id, version)
);
comment on table public.tailgate_signatures is 'Planet Ops: one person''s own acknowledgment of one version of a tailgate briefing. Frozen.';

-- Signatures and versions are kept as they were.
create function private.tailgate_record_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  raise exception 'Signed tailgate records and their versions are kept as they were.' using errcode = '22023';
end $$;
create trigger tailgate_signature_stays before update or delete on public.tailgate_signatures for each row execute function private.tailgate_record_stays();
create trigger tailgate_version_stays before update or delete on public.tailgate_versions for each row execute function private.tailgate_record_stays();

alter table public.tailgate_templates enable row level security;
alter table public.tailgate_meetings enable row level security;
alter table public.tailgate_versions enable row level security;
alter table public.tailgate_attendees enable row level security;
alter table public.tailgate_signatures enable row level security;
-- The office and crew leads see their company's; an employee sees the meetings they're on.
create function private.sees_tailgate(p_company uuid, p_meeting uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_role(p_company, '{owner,admin,office,estimator,crew_lead}')
      or exists (select 1 from public.tailgate_attendees a where a.meeting_id = p_meeting and a.user_id = (select auth.uid()))
$$;
create policy tailgate_templates_read on public.tailgate_templates for select to authenticated using (private.is_member(company_id));
create policy tailgate_meetings_read on public.tailgate_meetings for select to authenticated using (private.is_member(company_id) and private.sees_tailgate(company_id, id));
create policy tailgate_versions_read on public.tailgate_versions for select to authenticated using (private.is_member(company_id) and private.sees_tailgate(company_id, meeting_id));
create policy tailgate_attendees_read on public.tailgate_attendees for select to authenticated using (private.is_member(company_id) and private.sees_tailgate(company_id, meeting_id));
create policy tailgate_signatures_read on public.tailgate_signatures for select to authenticated using (private.is_member(company_id) and private.sees_tailgate(company_id, meeting_id));
revoke all on public.tailgate_templates, public.tailgate_meetings, public.tailgate_versions, public.tailgate_attendees, public.tailgate_signatures from anon, authenticated;
grant select on public.tailgate_templates, public.tailgate_meetings, public.tailgate_versions, public.tailgate_attendees, public.tailgate_signatures to authenticated;

create function private.tailgate_content(m public.tailgate_meetings) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('title', m.title, 'topic', m.topic, 'discussion', m.discussion, 'hazards', m.hazards, 'controls', m.controls, 'attachments', m.attachments,
                            'meeting_on', m.meeting_on, 'job_id', m.job_id)
$$;

create function public.save_tailgate_template(p_company uuid, p_title text, p_topic text default null, p_hazards text default null, p_controls text default null, p_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.runs_field(p_company) then raise exception 'Tailgate templates are for people who schedule.' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.tailgate_templates (company_id, title, topic, hazards, controls) values (p_company, btrim(p_title), p_topic, p_hazards, p_controls) returning id into v_id;
  else
    update public.tailgate_templates set title = btrim(p_title), topic = p_topic, hazards = p_hazards, controls = p_controls where id = p_id and company_id = p_company returning id into v_id;
    if v_id is null then raise exception 'Template not found.' using errcode = 'P0002'; end if;
  end if;
  return v_id;
end $$;

-- A meeting for a job (a retry with the same key returns it), with its attendees: the crew's members
-- (and lead) when a crew is given, plus anyone named.
create function public.create_tailgate(p_company uuid, p_request_key uuid, p_job uuid, p_meeting_on date, p_content jsonb, p_crew uuid default null,
  p_leader uuid default null, p_attendees uuid[] default '{}', p_visit uuid default null, p_template uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare m public.tailgate_meetings; t public.tailgate_templates; v_user uuid;
begin
  if not private.runs_field(p_company, p_crew) then raise exception 'Assigning a tailgate needs the Schedule area (or leading that crew).' using errcode = '42501'; end if;
  select * into m from public.tailgate_meetings where company_id = p_company and request_key = p_request_key;
  if m.id is not null then return m.id; end if;
  if not exists (select 1 from public.jobs j where j.id = p_job and j.company_id = p_company) then raise exception 'Job not found.' using errcode = 'P0002'; end if;
  if p_visit is not null and not exists (select 1 from public.visits v where v.id = p_visit and v.company_id = p_company and v.job_id = p_job) then
    raise exception 'That visit isn''t on this job.' using errcode = '22023';
  end if;
  if p_template is not null then select * into t from public.tailgate_templates where id = p_template and company_id = p_company; end if;
  insert into public.tailgate_meetings (company_id, job_id, visit_id, crew_id, leader_id, meeting_on, template_id, title, topic, discussion, hazards, controls, attachments, request_key)
  values (p_company, p_job, p_visit, p_crew, coalesce(p_leader, (select auth.uid())), p_meeting_on, t.id,
          coalesce(nullif(btrim(p_content ->> 'title'), ''), t.title, 'Tailgate meeting'), coalesce(p_content ->> 'topic', t.topic), p_content ->> 'discussion',
          coalesce(p_content ->> 'hazards', t.hazards), coalesce(p_content ->> 'controls', t.controls), coalesce(p_content -> 'attachments', '[]'), p_request_key)
  returning * into m;
  insert into public.tailgate_versions (meeting_id, company_id, version, content, content_hash) values (m.id, p_company, 1, private.tailgate_content(m), md5(private.tailgate_content(m)::text));
  for v_user in
    select x from unnest(p_attendees) x
    union select cm.user_id from public.crew_members cm where cm.crew_id = p_crew
    union select c.lead_user_id from public.crews c where c.id = p_crew and c.lead_user_id is not null
  loop
    if exists (select 1 from public.memberships mm where mm.company_id = p_company and mm.user_id = v_user and mm.active) then
      insert into public.tailgate_attendees (meeting_id, company_id, user_id) values (m.id, p_company, v_user) on conflict do nothing;
    end if;
  end loop;
  return m.id;
end $$;

-- Changes the briefing's content: before anyone signs, in place; after, as the next version, which
-- everyone attending signs again (their earlier signatures stay with the version they signed).
create function public.amend_tailgate(p_meeting uuid, p_content jsonb, p_reason text default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare m public.tailgate_meetings; v_signed boolean;
begin
  select * into m from public.tailgate_meetings where id = p_meeting for update;
  if not found or not private.runs_field(m.company_id, m.crew_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  v_signed := exists (select 1 from public.tailgate_signatures s where s.meeting_id = m.id and s.version = m.version);
  if v_signed and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'People have signed this briefing: say what changed (they''ll sign the amended one).' using errcode = '22023';
  end if;
  update public.tailgate_meetings set
    title = coalesce(nullif(btrim(p_content ->> 'title'), ''), title), topic = coalesce(p_content ->> 'topic', topic), discussion = coalesce(p_content ->> 'discussion', discussion),
    hazards = coalesce(p_content ->> 'hazards', hazards), controls = coalesce(p_content ->> 'controls', controls), attachments = coalesce(p_content -> 'attachments', attachments),
    version = case when v_signed then version + 1 else version end, updated_at = now()
  where id = m.id returning * into m;
  if v_signed then
    insert into public.tailgate_versions (meeting_id, company_id, version, content, content_hash, reason) values (m.id, m.company_id, m.version, private.tailgate_content(m), md5(private.tailgate_content(m)::text), btrim(p_reason));
  else
    -- Not signed yet: the version's content is still being written (its row is rewritten by the owner of the table only).
    perform set_config('planet_ops.tailgate_rewrite', 'on', true);
    delete from public.tailgate_versions where meeting_id = m.id and version = m.version;
    insert into public.tailgate_versions (meeting_id, company_id, version, content, content_hash) values (m.id, m.company_id, m.version, private.tailgate_content(m), md5(private.tailgate_content(m)::text));
  end if;
  return m.version;
end $$;

-- Who attended, who was absent; adding a late attendee (they sign the current version).
create function public.set_tailgate_attendance(p_meeting uuid, p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.tailgate_meetings;
begin
  select * into m from public.tailgate_meetings where id = p_meeting;
  if not found or not private.runs_field(m.company_id, m.crew_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if p_status not in ('assigned', 'attended', 'absent') then raise exception 'Assigned, attended or absent.' using errcode = '22023'; end if;
  if not exists (select 1 from public.memberships mm where mm.company_id = m.company_id and mm.user_id = p_user and mm.active) then raise exception 'They aren''t on the team.' using errcode = '22023'; end if;
  insert into public.tailgate_attendees (meeting_id, company_id, user_id, status, added_late)
  values (m.id, m.company_id, p_user, p_status, exists (select 1 from public.tailgate_signatures s where s.meeting_id = m.id))
  on conflict (meeting_id, user_id) do update set status = excluded.status;
end $$;

-- The person signs their own acknowledgment of the version they were shown (a retry with the same key
-- is the same signature).
create function public.sign_tailgate(p_meeting uuid, p_version integer, p_signature text, p_request_key uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m public.tailgate_meetings; v public.tailgate_versions; s public.tailgate_signatures;
begin
  if (select auth.uid()) is null then raise exception 'Each person signs for themselves, signed in.' using errcode = '42501'; end if;
  select * into m from public.tailgate_meetings where id = p_meeting;
  if not found or not exists (select 1 from public.tailgate_attendees a where a.meeting_id = m.id and a.user_id = (select auth.uid()) and a.status <> 'absent') then
    raise exception 'You aren''t on this tailgate meeting. Ask your lead to add you.' using errcode = '42501';
  end if;
  select * into s from public.tailgate_signatures where company_id = m.company_id and request_key = p_request_key;
  if s.id is not null then return jsonb_build_object('signed', true, 'version', s.version); end if;
  if p_version is distinct from m.version then
    raise exception 'This briefing was amended since you opened it. Read the new version, then sign.' using errcode = '40001';
  end if;
  select * into v from public.tailgate_versions where meeting_id = m.id and version = m.version;
  begin
    insert into public.tailgate_signatures (company_id, meeting_id, user_id, version, content_hash, signature, request_key)
    values (m.company_id, m.id, (select auth.uid()), m.version, v.content_hash, p_signature, p_request_key) returning * into s;
  exception
    when unique_violation then return jsonb_build_object('signed', true, 'version', m.version);
    when check_violation then raise exception 'Sign with your finger or a stylus (a drawn signature).' using errcode = '22023';
  end;
  update public.tailgate_attendees set status = 'attended' where meeting_id = m.id and user_id = (select auth.uid());
  return jsonb_build_object('signed', true, 'version', s.version);
end $$;

-- Who still needs to sign: everyone attending or assigned without a signature on the current version.
create function public.tailgate_status(p_meeting uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m public.tailgate_meetings;
begin
  select * into m from public.tailgate_meetings where id = p_meeting;
  if not found or not (private.is_member(m.company_id) and private.sees_tailgate(m.company_id, m.id)) and (select auth.uid()) is not null then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return jsonb_build_object('meeting_id', m.id, 'version', m.version, 'title', m.title, 'meeting_on', m.meeting_on, 'job_id', m.job_id,
    'attendees', (select coalesce(jsonb_agg(jsonb_build_object('user_id', a.user_id, 'name', p.full_name, 'status', a.status, 'added_late', a.added_late,
        'signed_version', (select max(s.version) from public.tailgate_signatures s where s.meeting_id = m.id and s.user_id = a.user_id),
        'signed_at', (select max(s.signed_at) from public.tailgate_signatures s where s.meeting_id = m.id and s.user_id = a.user_id and s.version = m.version),
        'needs_signature', a.status <> 'absent' and not exists (select 1 from public.tailgate_signatures s where s.meeting_id = m.id and s.user_id = a.user_id and s.version = m.version)) order by p.full_name), '[]')
      from public.tailgate_attendees a left join public.profiles p on p.user_id = a.user_id where a.meeting_id = m.id),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('version', v.version, 'reason', v.reason, 'created_at', v.created_at, 'content', v.content) order by v.version), '[]')
      from public.tailgate_versions v where v.meeting_id = m.id));
end $$;

-- The version rows are rewritten only before anyone signed (amend_tailgate's own step).
create or replace function private.tailgate_record_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  if tg_table_name = 'tailgate_versions' and tg_op = 'DELETE' and current_setting('planet_ops.tailgate_rewrite', true) = 'on'
     and not exists (select 1 from public.tailgate_signatures s where s.meeting_id = old.meeting_id and s.version = old.version) then
    return old;
  end if;
  raise exception 'Signed tailgate records and their versions are kept as they were.' using errcode = '22023';
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2–3. Machines on jobs, their checklists and checks
-- ---------------------------------------------------------------------------------------------

create table public.machine_checklists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The same checklist across versions.
  family_id uuid not null,
  version integer not null default 1,
  name text not null check (char_length(btrim(name)) between 1 and 200),
  -- For one machine, or a machine kind (truck, trailer, machine, tool...).
  equipment_id uuid,
  equipment_kind text,
  -- [{key, label, critical (a "no" takes it out of service), meter (asks for a reading)}]
  items jsonb not null check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 100),
  current boolean not null default true,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (family_id, version),
  foreign key (company_id, equipment_id) references public.equipment (company_id, id) on delete cascade,
  check (equipment_id is not null or equipment_kind is not null)
);
create unique index machine_checklists_current on public.machine_checklists (family_id) where current;
comment on table public.machine_checklists is 'Planet Ops: a machine''s (or a machine kind''s) daily checklist, versioned: a check keeps the version it answered. No procedure is preset.';

create table public.machine_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  equipment_id uuid not null,
  job_id uuid not null,
  visit_id uuid,
  operator_id uuid not null references auth.users (id) on delete cascade,
  -- Others allowed to run it (the operator is responsible for the checks).
  authorized_ids uuid[] not null default '{}',
  starts_on date not null,
  ends_on date not null,
  shift text check (char_length(shift) <= 60),
  -- The assignment this one took over from (an operator change): a handover check is required.
  handover_from uuid,
  handover_notes text check (char_length(handover_notes) <= 2000),
  ended_at timestamptz,
  request_key uuid not null,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, request_key),
  check (ends_on >= starts_on),
  foreign key (company_id, equipment_id) references public.equipment (company_id, id) on delete cascade,
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  foreign key (company_id, visit_id) references public.visits (company_id, id) on delete set null (visit_id),
  foreign key (company_id, handover_from) references public.machine_assignments (company_id, id)
);
create index machine_assignments_equipment_idx on public.machine_assignments (company_id, equipment_id, starts_on);
create index machine_assignments_operator_idx on public.machine_assignments (operator_id, starts_on);

create table public.machine_checks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  assignment_id uuid not null,
  equipment_id uuid not null,
  checklist_id uuid not null,
  checklist_version integer not null,
  kind text not null default 'daily' check (kind in ('daily', 'handover')),
  check_on date not null,
  -- [{key, answer yes|no|na, note, photo}], one per checklist item.
  responses jsonb not null check (jsonb_typeof(responses) = 'array'),
  meter_reading numeric(12, 1) check (meter_reading >= 0),
  operator_id uuid not null references auth.users (id) on delete cascade,
  signature text not null check (signature like 'data:image/%' and char_length(signature) between 200 and 500000),
  critical_failure boolean not null default false,
  signed_at timestamptz not null default now(),
  request_key uuid not null,
  unique (company_id, id),
  unique (company_id, request_key),
  foreign key (company_id, assignment_id) references public.machine_assignments (company_id, id) on delete cascade,
  foreign key (company_id, equipment_id) references public.equipment (company_id, id) on delete cascade,
  foreign key (company_id, checklist_id) references public.machine_checklists (company_id, id)
);
comment on table public.machine_checks is 'Planet Ops: one operator''s signed check of a machine for a day (or a handover), against the checklist version it answered. Frozen.';
create unique index machine_checks_one_daily on public.machine_checks (assignment_id, check_on, kind) where kind = 'daily';

create table public.machine_defects (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  equipment_id uuid not null,
  check_id uuid,
  job_id uuid,
  reported_by uuid references auth.users (id) on delete set null default auth.uid(),
  reported_at timestamptz not null default now(),
  description text not null check (char_length(btrim(description)) between 1 and 2000),
  critical boolean not null default false,
  status text not null default 'open' check (status in ('open', 'resolved')),
  resolved_by uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  resolution text check (char_length(resolution) <= 2000),
  evidence jsonb not null default '[]',
  unique (company_id, id),
  foreign key (company_id, equipment_id) references public.equipment (company_id, id) on delete cascade,
  foreign key (company_id, check_id) references public.machine_checks (company_id, id)
);

create trigger machine_check_stays before update or delete on public.machine_checks for each row execute function private.tailgate_record_stays();

alter table public.machine_checklists enable row level security;
alter table public.machine_assignments enable row level security;
alter table public.machine_checks enable row level security;
alter table public.machine_defects enable row level security;
create policy machine_checklists_read on public.machine_checklists for select to authenticated using (private.is_member(company_id));
create policy machine_assignments_read on public.machine_assignments for select to authenticated
  using (private.is_member(company_id) and (operator_id = (select auth.uid()) or (select auth.uid()) = any (authorized_ids) or private.has_role(company_id, '{owner,admin,office,estimator,crew_lead}')));
create policy machine_checks_read on public.machine_checks for select to authenticated
  using (private.is_member(company_id) and (operator_id = (select auth.uid()) or private.has_role(company_id, '{owner,admin,office,estimator,crew_lead}')));
create policy machine_defects_read on public.machine_defects for select to authenticated using (private.is_member(company_id));
revoke all on public.machine_checklists, public.machine_assignments, public.machine_checks, public.machine_defects from anon, authenticated;
grant select on public.machine_checklists, public.machine_assignments, public.machine_checks, public.machine_defects to authenticated;

-- Saves a checklist: a new one, or the next version of one (earlier checks keep theirs).
create function public.save_machine_checklist(p_company uuid, p_name text, p_items jsonb, p_equipment uuid default null, p_kind text default null, p_family uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_family uuid := coalesce(p_family, gen_random_uuid()); v_version integer; v_id uuid; i jsonb;
begin
  if not ((select auth.uid()) is null or private.manages_equipment(p_company)) then raise exception 'Machine checklists are for people who manage equipment.' using errcode = '42501'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'A checklist needs its items.' using errcode = '22023'; end if;
  for i in select * from jsonb_array_elements(p_items) loop
    if nullif(btrim(coalesce(i ->> 'key', '')), '') is null or nullif(btrim(coalesce(i ->> 'label', '')), '') is null then
      raise exception 'Each item needs a key and a label.' using errcode = '22023';
    end if;
  end loop;
  if (select count(distinct x ->> 'key') from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then raise exception 'Each item''s key is its own.' using errcode = '22023'; end if;
  select coalesce(max(version), 0) + 1 into v_version from public.machine_checklists where family_id = v_family and company_id = p_company;
  if p_family is not null and v_version = 1 then raise exception 'Checklist not found.' using errcode = 'P0002'; end if;
  update public.machine_checklists set current = false where family_id = v_family and current;
  insert into public.machine_checklists (company_id, family_id, version, name, equipment_id, equipment_kind, items)
  values (p_company, v_family, v_version, btrim(p_name), p_equipment, p_kind, p_items) returning id into v_id;
  return v_id;
end $$;

-- The current checklist for a machine: its own, else its kind's.
create function private.machine_checklist_for(p_equipment uuid) returns public.machine_checklists
language sql stable security definer set search_path = '' as $$
  select c.* from public.equipment e join public.machine_checklists c on c.company_id = e.company_id and c.current
           and (c.equipment_id = e.id or (c.equipment_id is null and c.equipment_kind = e.kind))
   where e.id = p_equipment order by (c.equipment_id is not null) desc limit 1
$$;

-- Assigns a machine to a job and its responsible operator (a retry with the same key returns it). A
-- machine out of service, or another assignment overlapping, is refused unless p_allow_overlap (the
-- screen warns first, as equipment_conflicts does for visits).
create function public.assign_machine(p_company uuid, p_request_key uuid, p_equipment uuid, p_job uuid, p_operator uuid, p_starts date, p_ends date,
  p_visit uuid default null, p_authorized uuid[] default '{}', p_shift text default null, p_allow_overlap boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a public.machine_assignments; e public.equipment;
begin
  if not private.runs_field(p_company) then raise exception 'Assigning machines needs the Schedule area.' using errcode = '42501'; end if;
  select * into a from public.machine_assignments where company_id = p_company and request_key = p_request_key;
  if a.id is not null then return a.id; end if;
  select * into e from public.equipment where id = p_equipment and company_id = p_company;
  if not found then raise exception 'Machine not found.' using errcode = 'P0002'; end if;
  if e.status <> 'active' then raise exception '% is out of service (%). Release it first.', e.name, e.status using errcode = '22023'; end if;
  if not exists (select 1 from public.jobs j where j.id = p_job and j.company_id = p_company) then raise exception 'Job not found.' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.memberships m where m.company_id = p_company and m.user_id = p_operator and m.active) then raise exception 'The operator must be on the team.' using errcode = '22023'; end if;
  if not p_allow_overlap and exists (select 1 from public.machine_assignments x where x.equipment_id = p_equipment and x.ended_at is null and x.starts_on <= p_ends and x.ends_on >= p_starts) then
    raise exception '% is already assigned on those days. Check the schedule, or assign it anyway.', e.name using errcode = '22023';
  end if;
  insert into public.machine_assignments (company_id, equipment_id, job_id, visit_id, operator_id, authorized_ids, starts_on, ends_on, shift, request_key)
  values (p_company, p_equipment, p_job, p_visit, p_operator, coalesce(p_authorized, '{}'), p_starts, p_ends, p_shift, p_request_key) returning * into a;
  return a.id;
end $$;

-- Changes the responsible operator from a day on: the old assignment ends the day before, the new one
-- needs a handover check by the new operator. Completed checks stay with the assignment they were for.
create function public.hand_over_machine(p_assignment uuid, p_new_operator uuid, p_from date, p_notes text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a public.machine_assignments; v_id uuid;
begin
  select * into a from public.machine_assignments where id = p_assignment for update;
  if not found or not private.runs_field(a.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  if a.ended_at is not null then raise exception 'That assignment already ended.' using errcode = '22023'; end if;
  if p_new_operator = a.operator_id then raise exception 'That''s the current operator.' using errcode = '22023'; end if;
  if not exists (select 1 from public.memberships m where m.company_id = a.company_id and m.user_id = p_new_operator and m.active) then raise exception 'The operator must be on the team.' using errcode = '22023'; end if;
  if p_from < a.starts_on or p_from > a.ends_on then raise exception 'Hand over within the assignment''s days.' using errcode = '22023'; end if;
  update public.machine_assignments set ends_on = greatest(p_from - 1, starts_on), ended_at = now() where id = a.id;
  insert into public.machine_assignments (company_id, equipment_id, job_id, visit_id, operator_id, authorized_ids, starts_on, ends_on, shift, handover_from, handover_notes, request_key)
  values (a.company_id, a.equipment_id, a.job_id, a.visit_id, p_new_operator, a.authorized_ids, p_from, a.ends_on, a.shift, a.id, nullif(btrim(coalesce(p_notes, '')), ''), gen_random_uuid())
  returning id into v_id;
  return v_id;
end $$;

-- The operator records the day's (or the handover's) check: every item answered now, signed. A
-- critical "no" takes the machine out of service, opens a defect and tells those who manage equipment.
create function public.record_machine_check(p_assignment uuid, p_request_key uuid, p_check_on date, p_responses jsonb, p_signature text,
  p_meter numeric default null, p_kind text default 'daily', p_checklist uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.machine_assignments; c public.machine_checklists; x public.machine_checks; e public.equipment; i jsonb; r jsonb; v_critical boolean := false; v_failed text[] := '{}';
begin
  if (select auth.uid()) is null then raise exception 'The operator signs their own check, signed in.' using errcode = '42501'; end if;
  select * into a from public.machine_assignments where id = p_assignment;
  if not found or a.operator_id <> (select auth.uid()) then raise exception 'Only the responsible operator records this machine''s check.' using errcode = '42501'; end if;
  select * into x from public.machine_checks where company_id = a.company_id and request_key = p_request_key;
  if x.id is not null then return jsonb_build_object('id', x.id, 'critical_failure', x.critical_failure); end if;
  if p_kind not in ('daily', 'handover') then raise exception 'Daily or handover.' using errcode = '22023'; end if;
  if p_check_on < a.starts_on or p_check_on > a.ends_on then raise exception 'That day isn''t in the assignment.' using errcode = '22023'; end if;
  if p_checklist is not null then select * into c from public.machine_checklists where id = p_checklist and company_id = a.company_id;
  else c := private.machine_checklist_for(a.equipment_id); end if;
  if c.id is null then raise exception 'This machine has no checklist yet. Ask whoever manages equipment to add one.' using errcode = '22023'; end if;
  if jsonb_typeof(p_responses) is distinct from 'array' then raise exception 'Answer each item.' using errcode = '22023'; end if;
  for i in select * from jsonb_array_elements(c.items) loop
    select y into r from jsonb_array_elements(p_responses) y where y ->> 'key' = i ->> 'key' limit 1;
    if r is null or coalesce(r ->> 'answer', '') not in ('yes', 'no', 'na') then
      raise exception 'Answer "%" (yes, no or not applicable): nothing is carried over from an earlier check.', i ->> 'label' using errcode = '22023';
    end if;
    if (r ->> 'answer') = 'no' and coalesce((i ->> 'critical')::boolean, false) then v_critical := true; v_failed := v_failed || (i ->> 'label'); end if;
    if coalesce((i ->> 'meter')::boolean, false) and p_meter is null then raise exception 'Enter the meter reading.' using errcode = '22023'; end if;
  end loop;
  begin
    insert into public.machine_checks (company_id, assignment_id, equipment_id, checklist_id, checklist_version, kind, check_on, responses, meter_reading, operator_id, signature, critical_failure, request_key)
    values (a.company_id, a.id, a.equipment_id, c.id, c.version, p_kind, p_check_on, p_responses, p_meter, (select auth.uid()), p_signature, v_critical, p_request_key) returning * into x;
  exception
    when unique_violation then raise exception 'Today''s check for this machine is already recorded.' using errcode = '22023';
    when check_violation then raise exception 'Sign the check with your finger or a stylus.' using errcode = '22023';
  end;
  if v_critical then
    select * into e from public.equipment where id = a.equipment_id;
    update public.equipment set status = 'in_shop', updated_at = now() where id = a.equipment_id;
    insert into public.machine_defects (company_id, equipment_id, check_id, job_id, description, critical)
    values (a.company_id, a.equipment_id, x.id, a.job_id, 'Failed on the ' || p_check_on || ' check: ' || array_to_string(v_failed, ', '), true);
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select a.company_id, m.user_id, 'equipment', e.name || ' is out of service', 'Failed its check: ' || array_to_string(v_failed, ', '), '/equipment/' || e.id
      from public.memberships m left join public.company_roles cr on cr.id = m.role_id
     where m.company_id = a.company_id and m.active and m.role in ('owner', 'admin', 'office', 'estimator', 'crew_lead')
       and 'equipment' = any (coalesce(cr.permissions, private.level_permissions(m.role)));
  end if;
  if p_meter is not null then
    update public.equipment set meter_reading = greatest(coalesce(meter_reading, 0), p_meter), meter_read_on = p_check_on where id = a.equipment_id;
  end if;
  return jsonb_build_object('id', x.id, 'critical_failure', v_critical);
end $$;

-- Anyone on the team reports a defect (critical takes it out of service and tells the managers).
create function public.report_machine_defect(p_equipment uuid, p_description text, p_critical boolean default false, p_job uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare e public.equipment; v_id uuid;
begin
  select * into e from public.equipment where id = p_equipment;
  if not found or not private.is_member(e.company_id) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  insert into public.machine_defects (company_id, equipment_id, job_id, description, critical) values (e.company_id, e.id, p_job, p_description, p_critical) returning id into v_id;
  if p_critical then
    update public.equipment set status = 'in_shop', updated_at = now() where id = e.id;
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select e.company_id, m.user_id, 'equipment', e.name || ' is out of service', p_description, '/equipment/' || e.id
      from public.memberships m left join public.company_roles cr on cr.id = m.role_id
     where m.company_id = e.company_id and m.active and m.role in ('owner', 'admin', 'office', 'estimator', 'crew_lead')
       and 'equipment' = any (coalesce(cr.permissions, private.level_permissions(m.role)));
  end if;
  return v_id;
end $$;

-- People who manage equipment resolve a defect with what was done; the machine is back in service
-- once no critical defect is open.
create function public.resolve_machine_defect(p_defect uuid, p_resolution text, p_evidence jsonb default '[]') returns void
language plpgsql security definer set search_path = '' as $$
declare d public.machine_defects;
begin
  select * into d from public.machine_defects where id = p_defect for update;
  if not found or not private.manages_equipment(d.company_id) then raise exception 'Releasing a machine is for people who manage equipment.' using errcode = '42501'; end if;
  if d.status = 'resolved' then return; end if;
  if nullif(btrim(coalesce(p_resolution, '')), '') is null then raise exception 'Say what was done (repair, check) before releasing it.' using errcode = '22023'; end if;
  update public.machine_defects set status = 'resolved', resolved_by = (select auth.uid()), resolved_at = now(), resolution = btrim(p_resolution), evidence = coalesce(p_evidence, '[]') where id = d.id;
  if not exists (select 1 from public.machine_defects x where x.equipment_id = d.equipment_id and x.status = 'open' and x.critical) then
    update public.equipment set status = 'active', updated_at = now() where id = d.equipment_id and status = 'in_shop';
  end if;
end $$;

-- What's missing on a day: each active assignment without its operator's check, and handovers waiting.
create function public.machine_checks_due(p_company uuid, p_on date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_on date := coalesce(p_on, private.company_today(p_company));
begin
  if not ((select auth.uid()) is null or private.is_member(p_company)) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('assignment_id', a.id, 'equipment_id', a.equipment_id, 'equipment', e.name, 'equipment_status', e.status, 'job_id', a.job_id,
      'operator_id', a.operator_id, 'operator', p.full_name,
      'daily_done', exists (select 1 from public.machine_checks c where c.assignment_id = a.id and c.check_on = v_on and c.kind = 'daily'),
      'handover_needed', a.handover_from is not null and not exists (select 1 from public.machine_checks c where c.assignment_id = a.id and c.kind = 'handover'),
      'open_defects', (select count(*) from public.machine_defects d where d.equipment_id = a.equipment_id and d.status = 'open')) order by e.name), '[]')
    from public.machine_assignments a join public.equipment e on e.id = a.equipment_id left join public.profiles p on p.user_id = a.operator_id
   where a.company_id = p_company and a.starts_on <= v_on and a.ends_on >= v_on
     -- Handed over: from that day on, the new operator's assignment is the one due.
     and not exists (select 1 from public.machine_assignments n where n.handover_from = a.id and n.starts_on <= v_on)
     and ((select auth.uid()) is null or private.has_role(p_company, '{owner,admin,office,estimator,crew_lead}') or a.operator_id = (select auth.uid())));
end $$;

-- An employee's day: their visits, the tailgates they need to sign, their machines and checks.
create function public.my_field_day(p_company uuid, p_on date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_on date := coalesce(p_on, private.company_today(p_company));
begin
  if not private.is_member(p_company) then raise exception 'Not found.' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'on', v_on,
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'title', v.title, 'job_id', v.job_id, 'status', v.status) order by v.starts_at nulls last), '[]')
               from private.my_visits() v where v.company_id = p_company and (v.scheduled_on = v_on or (v.starts_at at time zone coalesce((select timezone from public.companies where id = p_company), 'UTC'))::date = v_on)),
    'tailgates', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title, 'job_id', m.job_id, 'version', m.version,
                    'signed', exists (select 1 from public.tailgate_signatures s where s.meeting_id = m.id and s.user_id = (select auth.uid()) and s.version = m.version))), '[]')
                  from public.tailgate_meetings m join public.tailgate_attendees a on a.meeting_id = m.id and a.user_id = (select auth.uid()) and a.status <> 'absent'
                 where m.company_id = p_company and m.meeting_on = v_on),
    'machines', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(public.machine_checks_due(p_company, v_on)) x where (x ->> 'operator_id')::uuid = (select auth.uid())));
end $$;

-- The tailgate record goes to the job's Documents & Permits in the PDOS Drive (Phase 4's queue).
alter table public.pdos_files drop constraint pdos_files_source_kind_check;
alter table public.pdos_files add constraint pdos_files_source_kind_check check (source_kind in ('estimate_summary', 'cost_document', 'disposal_ticket', 'signed_document', 'job_record', 'tailgate'));
create function private.pdos_queue_tailgate() returns trigger
language plpgsql security definer set search_path = '' as $$
declare m public.tailgate_meetings;
begin
  select * into m from public.tailgate_meetings where id = coalesce(new.meeting_id, new.id);
  insert into public.pdos_files (company_id, source_kind, source_id, job_id, destination, file_name)
  values (m.company_id, 'tailgate', m.id, m.job_id, 'job_documents', 'Tailgate ' || m.meeting_on || ' - ' || left(regexp_replace(m.title, '[\\/:*?"<>|]+', ' ', 'g'), 120) || '.html')
  on conflict (company_id, source_kind, source_id) do update set version = public.pdos_files.version + 1, status = 'pending', attempts = 0, next_attempt_at = now(), updated_at = now();
  return null;
end $$;
create trigger pdos_queue_tailgate after insert on public.tailgate_signatures for each row execute function private.pdos_queue_tailgate();

revoke execute on function private.runs_field(uuid, uuid), private.tailgate_record_stays(), private.sees_tailgate(uuid, uuid), private.tailgate_content(public.tailgate_meetings),
  private.machine_checklist_for(uuid), private.pdos_queue_tailgate() from public;
grant execute on function private.sees_tailgate(uuid, uuid) to authenticated;
revoke execute on function public.save_tailgate_template(uuid, text, text, text, text, uuid), public.create_tailgate(uuid, uuid, uuid, date, jsonb, uuid, uuid, uuid[], uuid, uuid),
  public.amend_tailgate(uuid, jsonb, text), public.set_tailgate_attendance(uuid, uuid, text), public.sign_tailgate(uuid, integer, text, uuid), public.tailgate_status(uuid),
  public.save_machine_checklist(uuid, text, jsonb, uuid, text, uuid), public.assign_machine(uuid, uuid, uuid, uuid, uuid, date, date, uuid, uuid[], text, boolean),
  public.hand_over_machine(uuid, uuid, date, text), public.record_machine_check(uuid, uuid, date, jsonb, text, numeric, text, uuid),
  public.report_machine_defect(uuid, text, boolean, uuid), public.resolve_machine_defect(uuid, text, jsonb), public.machine_checks_due(uuid, date), public.my_field_day(uuid, date) from public, anon;
grant execute on function public.save_tailgate_template(uuid, text, text, text, text, uuid), public.create_tailgate(uuid, uuid, uuid, date, jsonb, uuid, uuid, uuid[], uuid, uuid),
  public.amend_tailgate(uuid, jsonb, text), public.set_tailgate_attendance(uuid, uuid, text), public.sign_tailgate(uuid, integer, text, uuid), public.tailgate_status(uuid),
  public.save_machine_checklist(uuid, text, jsonb, uuid, text, uuid), public.assign_machine(uuid, uuid, uuid, uuid, uuid, date, date, uuid, uuid[], text, boolean),
  public.hand_over_machine(uuid, uuid, date, text), public.record_machine_check(uuid, uuid, date, jsonb, text, numeric, text, uuid),
  public.report_machine_defect(uuid, text, boolean, uuid), public.resolve_machine_defect(uuid, text, jsonb), public.machine_checks_due(uuid, date), public.my_field_day(uuid, date) to authenticated;

select private.fold_member_checks('public.tailgate_templates');
select private.fold_member_checks('public.tailgate_meetings');
select private.fold_member_checks('public.tailgate_versions');
select private.fold_member_checks('public.tailgate_attendees');
select private.fold_member_checks('public.tailgate_signatures');
select private.fold_member_checks('public.machine_checklists');
select private.fold_member_checks('public.machine_assignments');
select private.fold_member_checks('public.machine_checks');
select private.fold_member_checks('public.machine_defects');

notify pgrst, 'reload schema';
