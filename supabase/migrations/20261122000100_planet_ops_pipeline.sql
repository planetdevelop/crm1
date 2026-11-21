-- Planet Ops Phase 2: a real sales pipeline (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §4).
--
-- 1. public.pipeline_stages: each business's stages, editable (label, order, the next action a
--    request gets on entering one), from the plan's starter list: New inquiry → Contacting → Site
--    visit scheduled → Site visit complete → Estimating → Quote/proposal sent → Follow-up → Won, and
--    the separate outcomes Nurture/on hold, Lost and Unqualified/spam. Custom open stages can be
--    added. "Viewed" and "overdue" stay badges, not stages.
-- 2. Every request in the pipeline: its stage (requests.stage_id), its owner (the existing
--    requests.assigned_to: the zip code's salesperson as before, else the pipeline's default owner;
--    with neither it's flagged "No owner" until someone takes it), the assigned estimator, its next
--    action and date, the last contact and first response, campaign and requested service, and its
--    outcome with a reason. Sales stage stays apart from the request's existing status and from the
--    job's production status; the existing flows (a site visit booked or finished, a quote sent)
--    move a request forward, never back, and never out of an outcome someone chose; a job made from
--    it makes it Won, whatever it was (the customer came back).
-- 3. public.request_pipeline_events: what happened to a request in the pipeline (stage, owner,
--    estimator, next action, outcome, follow-ups paused or resumed, contacts), kept as it happened.
-- 4. Contacts (calls, texts, emails, notes) are logged against the request and its client in the
--    existing messages table (public.log_request_contact), never as a new lead, and never sent: this
--    records what happened. An inbound one, an opt-out, a win or a loss pauses the request's
--    follow-ups; staff can pause and resume them.
-- 5. Follow-ups: internal reminders (public.follow_up_tasks, from Phase 1c) made by each stage's
--    cadence steps (public.pipeline_cadence_steps) as a request enters it, once per entry, and by
--    hand (public.add_request_follow_up). Reusable call/text/email templates
--    (public.pipeline_templates) are drafts for staff to use. Nothing here sends a customer message
--    on its own: automatic sending needs an approved channel, text, recipients and timing, and
--    arrives with the communication integrations (Phase 7).
-- 6. public.pipeline_report and public.pipeline_pricing_history: request counts, aging, response
--    time, conversion, source and won/lost value on defined dates; and quoted prices by service,
--    location, date, estimator and outcome. Lost and no-response prices are sales evidence, never
--    actual costs or production benchmarks.
--
-- Who: the pipeline is the sales area's (owners, admins, office and estimators with sales);
-- stages, cadence, templates and the pipeline settings are Settings'. Enforced here for anyone
-- signed in (the office's screens, the API, connected assistants).

-- ---------------------------------------------------------------------------------------------
-- 1. Stages
-- ---------------------------------------------------------------------------------------------

create table public.pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The starter stages the app's own flows move requests into; null for one the business added.
  system_key text check (system_key in ('new_inquiry', 'contacting', 'site_visit_scheduled', 'site_visit_complete', 'estimating', 'quote_sent', 'follow_up', 'won', 'nurture', 'lost', 'unqualified')),
  label text not null check (char_length(btrim(label)) between 1 and 60),
  -- open: a step on the way; won; and the outcomes kept apart from the steps.
  kind text not null check (kind in ('open', 'won', 'nurture', 'lost', 'unqualified')),
  sort integer not null,
  -- What a request entering it is to do next, and in how many days (open stages and nurture).
  default_next_action text check (char_length(default_next_action) <= 200),
  default_due_days integer check (default_due_days between 0 and 365),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, system_key),
  check (system_key is not null or kind = 'open'),
  check (kind in ('open', 'nurture') or (default_next_action is null and default_due_days is null))
);
comment on table public.pipeline_stages is 'Planet Ops: the sales pipeline''s stages per business, editable. Outcomes (nurture, lost, unqualified) are kept apart from the open steps.';
create index pipeline_stages_order_idx on public.pipeline_stages (company_id, sort);
alter table public.pipeline_stages enable row level security;
create policy pipeline_stages_read on public.pipeline_stages for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator,crew_lead}'));
create policy pipeline_stages_insert on public.pipeline_stages for insert to authenticated
  with check (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'));
create policy pipeline_stages_update on public.pipeline_stages for update to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'))
  with check (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'));
create policy pipeline_stages_delete on public.pipeline_stages for delete to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings') and system_key is null);
grant select, insert, delete on public.pipeline_stages to authenticated;
grant update (label, sort, default_next_action, default_due_days, active) on public.pipeline_stages to authenticated;

-- A starter stage keeps what the app relies on: its key and kind, and the outcomes and the first
-- and won stages stay switched on.
create function private.pipeline_stage_rules() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.system_key is distinct from old.system_key or new.kind is distinct from old.kind or new.company_id is distinct from old.company_id then
      raise exception 'A stage''s kind stays as it is. Add a new stage instead.' using errcode = '22023';
    end if;
    if not new.active and new.system_key in ('new_inquiry', 'won', 'nurture', 'lost', 'unqualified') then
      raise exception 'The New inquiry, Won, Nurture, Lost and Unqualified stages stay on. You can rename them.' using errcode = '22023';
    end if;
    if not new.active and old.active and exists (select 1 from public.requests r where r.company_id = new.company_id and r.stage_id = new.id and r.status not in ('converted', 'archived')) then
      raise exception 'Move the requests in this stage first.' using errcode = '22023';
    end if;
    new.updated_at := now();
  end if;
  new.label := btrim(new.label);
  return new;
end $$;
create trigger pipeline_stage_rules before insert or update on public.pipeline_stages
  for each row execute function private.pipeline_stage_rules();

-- The plan's starter stages for a business (labels, order and next actions are its to change).
create function private.install_pipeline_stages(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.pipeline_stages (company_id, system_key, label, kind, sort, default_next_action, default_due_days) values
    (p_company, 'new_inquiry', 'New inquiry', 'open', 10, 'Make first contact', 0),
    (p_company, 'contacting', 'Contacting', 'open', 20, 'Reach the customer', 1),
    (p_company, 'site_visit_scheduled', 'Site visit scheduled', 'open', 30, 'Complete the site visit', 7),
    (p_company, 'site_visit_complete', 'Site visit complete', 'open', 40, 'Start the estimate', 1),
    (p_company, 'estimating', 'Estimating', 'open', 50, 'Finish the estimate and the quote/proposal', 3),
    (p_company, 'quote_sent', 'Quote/proposal sent', 'open', 60, 'Follow up on the quote/proposal', 3),
    (p_company, 'follow_up', 'Follow-up', 'open', 70, 'Follow up with the customer', 7),
    (p_company, 'won', 'Won', 'won', 80, null, null),
    (p_company, 'nurture', 'Nurture/on hold', 'nurture', 90, 'Check back in', 30),
    (p_company, 'lost', 'Lost', 'lost', 100, null, null),
    (p_company, 'unqualified', 'Unqualified/spam', 'unqualified', 110, null, null)
  on conflict (company_id, system_key) do nothing
$$;
create function private.company_pipeline_defaults() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.install_pipeline_stages(new.id);
  perform private.install_pipeline_cadence(new.id);
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 5 (tables first). Cadence steps and templates
-- ---------------------------------------------------------------------------------------------

-- Reusable call, text and email wording for staff to use (drafts; nothing is sent from here). The
-- business writes its own: none come preset.
create table public.pipeline_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  channel text not null check (channel in ('call', 'sms', 'email')),
  subject text check (char_length(subject) <= 200),
  body text not null check (char_length(body) between 1 and 4000),
  active boolean not null default true,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id)
);
comment on table public.pipeline_templates is 'Planet Ops: reusable call scripts and text/email drafts for following up a request. Staff use them; nothing sends them automatically.';
alter table public.pipeline_templates enable row level security;
create policy pipeline_templates_read on public.pipeline_templates for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
create policy pipeline_templates_write on public.pipeline_templates for all to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'))
  with check (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'));
grant select, insert, delete on public.pipeline_templates to authenticated;
grant update (name, channel, subject, body, active) on public.pipeline_templates to authenticated;
create trigger touch_updated_at before update on public.pipeline_templates
  for each row execute function private.touch_updated_at();

-- What to do, and when, after a request enters a stage: each step makes one internal follow-up for
-- the request's owner, due that many days after it entered.
create table public.pipeline_cadence_steps (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  stage_id uuid not null,
  after_days integer not null default 0 check (after_days between 0 and 365),
  title text not null check (char_length(btrim(title)) between 1 and 200),
  channel text not null default 'call' check (channel in ('call', 'sms', 'email', 'task')),
  template_id uuid,
  sort integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, stage_id) references public.pipeline_stages (company_id, id) on delete cascade,
  foreign key (company_id, template_id) references public.pipeline_templates (company_id, id) on delete set null (template_id)
);
comment on table public.pipeline_cadence_steps is 'Planet Ops: the follow-up cadence: internal reminders a request gets as it enters a stage. Reminders only; no customer message is sent.';
create index pipeline_cadence_steps_stage_idx on public.pipeline_cadence_steps (company_id, stage_id);
alter table public.pipeline_cadence_steps enable row level security;
create policy pipeline_cadence_steps_read on public.pipeline_cadence_steps for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
create policy pipeline_cadence_steps_write on public.pipeline_cadence_steps for all to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'))
  with check (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'settings'));
grant select, insert, delete on public.pipeline_cadence_steps to authenticated;
grant update (stage_id, after_days, title, channel, template_id, sort, active) on public.pipeline_cadence_steps to authenticated;

-- The plan's suggested starter cadence: first response, post-site-visit check-in, post-proposal
-- follow-up, later nurture. Reminders for staff, each changeable or removable.
create function private.install_pipeline_cadence(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.pipeline_cadence_steps (company_id, stage_id, after_days, title, channel, sort)
  select p_company, s.id, x.after_days, x.title, x.channel, x.sort
  from (values ('new_inquiry', 0, 'First response', 'call', 10),
               ('site_visit_complete', 2, 'Post-site-visit check-in', 'call', 20),
               ('quote_sent', 3, 'Post-proposal follow-up', 'call', 30),
               ('nurture', 30, 'Nurture check-in', 'email', 40)) as x (stage_key, after_days, title, channel, sort)
  join public.pipeline_stages s on s.company_id = p_company and s.system_key = x.stage_key
  where not exists (select 1 from public.pipeline_cadence_steps c where c.company_id = p_company)
$$;

create trigger install_pipeline after insert on public.companies
  for each row execute function private.company_pipeline_defaults();
select private.install_pipeline_stages(id) from public.companies;
select private.install_pipeline_cadence(id) from public.companies;

-- Follow-up tasks (20261121000100) also come from the cadence and by hand, and say why one was
-- closed without being done (its request moved on, was paused, won or lost).
alter table public.follow_up_tasks drop constraint follow_up_tasks_source_check;
alter table public.follow_up_tasks add constraint follow_up_tasks_source_check check (source in ('change_request', 'cadence', 'manual'));
alter table public.follow_up_tasks add column created_by uuid references auth.users (id) on delete set null;
alter table public.follow_up_tasks add column closed_reason text check (closed_reason in ('stage_changed', 'paused', 'won', 'lost', 'unqualified', 'customer_replied', 'opted_out'));
grant update (due_on, assigned_to) on public.follow_up_tasks to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. The request in the pipeline
-- ---------------------------------------------------------------------------------------------

alter table public.requests
  add column stage_id uuid,
  add column stage_entered_at timestamptz,
  add column estimator_id uuid references auth.users (id) on delete set null,
  add column next_action text check (char_length(next_action) <= 200),
  add column next_action_on date,
  add column last_contact_at timestamptz,
  add column first_response_at timestamptz,
  add column campaign text check (char_length(campaign) <= 120),
  add column service text check (char_length(service) <= 120),
  add column outcome_reason text check (char_length(outcome_reason) <= 500),
  add column outcome_at timestamptz,
  add column follow_up_paused_at timestamptz,
  add column follow_up_paused_reason text check (follow_up_paused_reason in ('customer_replied', 'won', 'lost', 'unqualified', 'opted_out', 'staff')),
  add constraint requests_stage_fkey foreign key (company_id, stage_id) references public.pipeline_stages (company_id, id),
  add constraint requests_paused_check check ((follow_up_paused_at is null) = (follow_up_paused_reason is null));
comment on column public.requests.stage_id is 'Planet Ops: the request''s sales pipeline stage (apart from its status and any job''s production status).';
comment on column public.requests.assigned_to is 'The request''s owner: the salesperson responsible for it.';
comment on column public.requests.estimator_id is 'Planet Ops: the estimator assigned to the request.';
comment on column public.requests.last_contact_at is 'Planet Ops: the last call, text, email or meeting with the customer logged on the request.';
comment on column public.requests.first_response_at is 'Planet Ops: the first contact made with the customer after the request came in.';
create index requests_stage_idx on public.requests (company_id, stage_id);
create index requests_next_action_idx on public.requests (company_id, next_action_on) where status not in ('converted', 'archived');

-- The stage a status means (the existing flows), and a stage by its key.
create function private.pipeline_stage(p_company uuid, p_key text) returns public.pipeline_stages
language sql stable security definer set search_path = '' as $$
  select * from public.pipeline_stages where company_id = p_company and system_key = p_key
$$;
create function private.status_stage_key(p_status text) returns text
language sql immutable set search_path = '' as $$
  select case p_status
    when 'new' then 'new_inquiry'
    when 'assessment_scheduled' then 'site_visit_scheduled'
    when 'assessment_complete' then 'site_visit_complete'
    when 'quoted' then 'estimating'
    when 'converted' then 'won'
  end
$$;

-- Whoever the request is for when nobody covers its zip: the pipeline's default owner (Settings →
-- Pipeline) while they're on the team. With none chosen, it stays unassigned, as before, and the
-- pipeline flags it ("No owner") until someone takes it.
create function private.pipeline_default_owner(p_company uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select m.user_id from public.companies c join public.memberships m on m.company_id = c.id and m.active
   where c.id = p_company and m.user_id::text = c.settings -> 'pipeline' ->> 'default_owner'
$$;

-- Sets a request's pipeline fields as it comes in and as it moves (runs after assign_salesperson).
create function private.pipeline_request() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old public.pipeline_stages;
  v_new public.pipeline_stages;
  v_auto public.pipeline_stages;
  v_today date;
  v_staff_moved boolean;
begin
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date into v_today from public.companies c where c.id = new.company_id;

  if tg_op = 'UPDATE' then
    -- The pipeline is the sales area's: someone signed in without it can't move a request in it.
    v_staff_moved := new.stage_id is distinct from old.stage_id or new.assigned_to is distinct from old.assigned_to
      or new.estimator_id is distinct from old.estimator_id or new.next_action is distinct from old.next_action
      or new.next_action_on is distinct from old.next_action_on or new.outcome_reason is distinct from old.outcome_reason
      or new.follow_up_paused_at is distinct from old.follow_up_paused_at or new.campaign is distinct from old.campaign
      or new.service is distinct from old.service;
    if v_staff_moved and (select auth.uid()) is not null and not private.has_perm(new.company_id, 'sales') then
      raise exception 'The sales pipeline needs the Sales area.' using errcode = '42501';
    end if;
    -- Kept by the app: when a stage was entered, and the contact times.
    if new.stage_id is not distinct from old.stage_id then new.stage_entered_at := old.stage_entered_at; end if;
    if new.outcome_at is distinct from old.outcome_at and new.stage_id is not distinct from old.stage_id then new.outcome_at := old.outcome_at; end if;
    select * into v_old from public.pipeline_stages where id = old.stage_id;
  else
    if new.assigned_to is null then
      new.assigned_to := private.pipeline_default_owner(new.company_id);
    end if;
    new.outcome_at := null;
  end if;

  -- The existing flows move a request forward: a site visit booked or done, quoted. Never back, and
  -- never out of an outcome someone chose (nurture, lost, unqualified). A job made from it: Won.
  if (tg_op = 'INSERT' and new.stage_id is null)
     or (tg_op = 'UPDATE' and new.status is distinct from old.status and new.stage_id is not distinct from old.stage_id) then
    v_auto := private.pipeline_stage(new.company_id, private.status_stage_key(new.status));
    if v_auto.id is not null then
      if tg_op = 'INSERT' then
        new.stage_id := v_auto.id;
      elsif v_old.id is null or (v_old.kind = 'open' and v_auto.kind = 'open' and v_auto.sort > v_old.sort) or (v_auto.kind = 'won' and v_old.kind <> 'won') then
        new.stage_id := v_auto.id;
      end if;
    end if;
  end if;

  if tg_op = 'INSERT' or new.stage_id is distinct from old.stage_id then
    select * into v_new from public.pipeline_stages where id = new.stage_id and company_id = new.company_id;
    if new.stage_id is not null and v_new.id is null then
      raise exception 'Pick one of this business''s pipeline stages.' using errcode = '22023';
    end if;
    if v_new.id is not null and not v_new.active then
      raise exception 'That stage is switched off.' using errcode = '22023';
    end if;
    new.stage_entered_at := now();
    -- Won is a job made from it, not a status someone sets: no win is made up.
    if v_new.kind = 'won' and new.status is distinct from 'converted'
       and not exists (select 1 from public.jobs j where j.company_id = new.company_id and j.request_id = new.id) then
      raise exception 'A request is won when its job is made: convert its signed quote or proposal, or create the job from it.' using errcode = '22023';
    end if;
    if v_new.kind in ('lost', 'unqualified') then
      if nullif(btrim(coalesce(new.outcome_reason, '')), '') is null then
        raise exception 'Say why it was % (the outcome reason).', lower(v_new.label) using errcode = '23514';
      end if;
    elsif tg_op = 'UPDATE' and v_old.kind in ('lost', 'unqualified', 'won') and new.outcome_reason is not distinct from old.outcome_reason then
      -- Back in the pipeline: the old outcome stays in the history, not on the request.
      new.outcome_reason := null;
    end if;
    new.outcome_at := case when v_new.kind in ('won', 'lost', 'unqualified') then now() end;
    if v_new.kind in ('won', 'lost', 'unqualified') then
      -- Decided: nothing left to do in sales, and its follow-ups stop.
      new.next_action := null;
      new.next_action_on := null;
      if new.follow_up_paused_at is null then
        new.follow_up_paused_at := now();
        new.follow_up_paused_reason := v_new.kind;
      end if;
    else
      -- An open stage or nurture: its next action, unless one was given with the move.
      if tg_op = 'INSERT' and new.next_action is null or tg_op = 'UPDATE' and new.next_action is not distinct from old.next_action and new.next_action_on is not distinct from old.next_action_on then
        if v_new.default_next_action is not null then
          new.next_action := v_new.default_next_action;
          new.next_action_on := v_today + coalesce(v_new.default_due_days, 0);
        end if;
      end if;
      -- Out of an outcome that paused it: its follow-ups start again.
      if tg_op = 'UPDATE' and old.follow_up_paused_reason in ('won', 'lost', 'unqualified') and new.follow_up_paused_reason is not distinct from old.follow_up_paused_reason then
        new.follow_up_paused_at := null;
        new.follow_up_paused_reason := null;
      end if;
    end if;
  end if;

  if new.follow_up_paused_at is not null and new.follow_up_paused_reason is null then
    new.follow_up_paused_reason := 'staff';
  end if;
  if new.estimator_id is not null and (tg_op = 'INSERT' or new.estimator_id is distinct from old.estimator_id)
     and not exists (select 1 from public.memberships m where m.company_id = new.company_id and m.user_id = new.estimator_id and m.active) then
    raise exception 'The estimator must be on the team.' using errcode = '22023';
  end if;
  if new.assigned_to is not null and (tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to)
     and not exists (select 1 from public.memberships m where m.company_id = new.company_id and m.user_id = new.assigned_to and m.active) then
    raise exception 'The request''s owner must be on the team.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger pipeline_request before insert or update on public.requests
  for each row execute function private.pipeline_request();

-- The contact times come from logged contacts (log_request_contact, which runs as its owner) and the
-- server, never from a signed-in person writing them. Runs as whoever is writing, before the above.
create function private.pipeline_contact_times() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.last_contact_at := null;
      new.first_response_at := null;
    else
      new.last_contact_at := old.last_contact_at;
      new.first_response_at := old.first_response_at;
    end if;
  end if;
  return new;
end $$;
create trigger pipeline_contact_times before insert or update on public.requests
  for each row execute function private.pipeline_contact_times();

-- Existing requests join the pipeline at the stage their status means (archived ones stay out:
-- nothing about why they were archived is invented). Their next action comes from the stage.
alter table public.requests disable trigger pipeline_request;
update public.requests r
   set stage_id = s.id,
       stage_entered_at = coalesce(r.updated_at, r.created_at),
       next_action = case when s.kind in ('open', 'nurture') then s.default_next_action end,
       next_action_on = case when s.kind in ('open', 'nurture') then (now() at time zone coalesce(c.timezone, 'UTC'))::date + coalesce(s.default_due_days, 0) end,
       outcome_at = case when s.kind = 'won' then r.updated_at end
  from public.pipeline_stages s, public.companies c
 where s.company_id = r.company_id and c.id = r.company_id and s.system_key = private.status_stage_key(r.status) and r.stage_id is null;
alter table public.requests enable trigger pipeline_request;

-- ---------------------------------------------------------------------------------------------
-- 3. What happened in the pipeline
-- ---------------------------------------------------------------------------------------------

create table public.request_pipeline_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  request_id uuid not null,
  kind text not null check (kind in ('stage', 'owner', 'estimator', 'next_action', 'outcome', 'paused', 'resumed', 'contact')),
  from_stage_id uuid,
  to_stage_id uuid,
  -- As it read then (a stage's label, a person's id, the next action and its date, the reason).
  from_value text check (char_length(from_value) <= 600),
  to_value text check (char_length(to_value) <= 600),
  actor_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (company_id, request_id) references public.requests (company_id, id) on delete cascade
);
comment on table public.request_pipeline_events is 'Planet Ops: a request''s pipeline history (stage, owner, estimator, next action, outcome, pauses, contacts), kept as it happened.';
create index request_pipeline_events_request_idx on public.request_pipeline_events (company_id, request_id, created_at);
alter table public.request_pipeline_events enable row level security;
create policy request_pipeline_events_read on public.request_pipeline_events for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}') and private.has_perm(company_id, 'sales'));
grant select on public.request_pipeline_events to authenticated;

create function private.pipeline_event_stays() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  raise exception 'A request''s pipeline history is kept as it happened.' using errcode = '22023';
end $$;
create trigger pipeline_event_stays before update or delete on public.request_pipeline_events
  for each row execute function private.pipeline_event_stays();

-- The follow-ups a request's stage cadence makes as it enters a stage: once per entry (the entry's
-- event and the step make the task's source id), for its owner, unless its follow-ups are paused or
-- the business switched reminders off.
create function private.pipeline_cadence_tasks(p_request uuid, p_event uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_today date; v_on boolean;
begin
  select * into r from public.requests where id = p_request;
  if not found or r.stage_id is null or r.follow_up_paused_at is not null or r.status in ('converted', 'archived') then return; end if;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date, coalesce((c.settings -> 'pipeline' ->> 'reminders')::boolean, true)
    into v_today, v_on from public.companies c where c.id = r.company_id;
  if not v_on then return; end if;
  insert into public.follow_up_tasks (company_id, assigned_to, title, body, link, related_type, related_id, source, source_id, due_on)
  select r.company_id, r.assigned_to, s.title || ': ' || r.title,
         case when t.id is not null then 'Use the "' || t.name || '" ' || case s.channel when 'sms' then 'text' else s.channel end || ' template.' end,
         '/requests/' || r.id, 'request', r.id, 'cadence', md5(p_event::text || s.id::text)::uuid, v_today + s.after_days
    from public.pipeline_cadence_steps s
    left join public.pipeline_templates t on t.id = s.template_id and t.active
   where s.company_id = r.company_id and s.stage_id = r.stage_id and s.active
  on conflict (source, source_id) do nothing;
end $$;

-- Closes a request's open reminders from its cadence (or all of them) without calling them done.
create function private.close_request_follow_ups(p_request uuid, p_reason text, p_cadence_only boolean) returns void
language sql security definer set search_path = '' as $$
  update public.follow_up_tasks set done_at = now(), closed_reason = p_reason
   where related_type = 'request' and related_id = p_request and done_at is null
     and (source = 'cadence' or not p_cadence_only)
$$;

create function private.pipeline_request_history() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := (select auth.uid()); v_from text; v_to text; v_event uuid;
begin
  if tg_op = 'INSERT' then
    if new.stage_id is not null then
      insert into public.request_pipeline_events (company_id, request_id, kind, to_stage_id, to_value, actor_id)
      values (new.company_id, new.id, 'stage', new.stage_id, (select label from public.pipeline_stages where id = new.stage_id), v_actor)
      returning id into v_event;
      perform private.pipeline_cadence_tasks(new.id, v_event);
    end if;
    return null;
  end if;

  if new.stage_id is distinct from old.stage_id then
    select label into v_from from public.pipeline_stages where id = old.stage_id;
    select label into v_to from public.pipeline_stages where id = new.stage_id;
    insert into public.request_pipeline_events (company_id, request_id, kind, from_stage_id, to_stage_id, from_value, to_value, actor_id)
    values (new.company_id, new.id, 'stage', old.stage_id, new.stage_id, v_from, v_to, v_actor)
    returning id into v_event;
    -- The last stage's reminders are left behind; the new stage's begin.
    perform private.close_request_follow_ups(new.id, 'stage_changed', true);
    perform private.pipeline_cadence_tasks(new.id, v_event);
  end if;
  if new.outcome_reason is distinct from old.outcome_reason and new.outcome_reason is not null then
    insert into public.request_pipeline_events (company_id, request_id, kind, from_value, to_value, actor_id)
    values (new.company_id, new.id, 'outcome', old.outcome_reason, new.outcome_reason, v_actor);
  end if;
  if new.assigned_to is distinct from old.assigned_to then
    insert into public.request_pipeline_events (company_id, request_id, kind, from_value, to_value, actor_id)
    values (new.company_id, new.id, 'owner', old.assigned_to::text, new.assigned_to::text, v_actor);
    -- The open reminders go with the request to its new owner.
    update public.follow_up_tasks set assigned_to = new.assigned_to
     where related_type = 'request' and related_id = new.id and done_at is null and assigned_to is not distinct from old.assigned_to;
  end if;
  if new.estimator_id is distinct from old.estimator_id then
    insert into public.request_pipeline_events (company_id, request_id, kind, from_value, to_value, actor_id)
    values (new.company_id, new.id, 'estimator', old.estimator_id::text, new.estimator_id::text, v_actor);
  end if;
  if (new.next_action is distinct from old.next_action or new.next_action_on is distinct from old.next_action_on) and new.stage_id is not distinct from old.stage_id then
    insert into public.request_pipeline_events (company_id, request_id, kind, from_value, to_value, actor_id)
    values (new.company_id, new.id, 'next_action',
            nullif(concat_ws(' · ', old.next_action, old.next_action_on::text), ''), nullif(concat_ws(' · ', new.next_action, new.next_action_on::text), ''), v_actor);
  end if;
  if new.follow_up_paused_at is not null and old.follow_up_paused_at is null then
    insert into public.request_pipeline_events (company_id, request_id, kind, to_value, actor_id)
    values (new.company_id, new.id, 'paused', new.follow_up_paused_reason, v_actor);
    perform private.close_request_follow_ups(new.id, case when new.follow_up_paused_reason = 'staff' then 'paused' else new.follow_up_paused_reason end, true);
  elsif new.follow_up_paused_at is null and old.follow_up_paused_at is not null then
    insert into public.request_pipeline_events (company_id, request_id, kind, from_value, actor_id)
    values (new.company_id, new.id, 'resumed', old.follow_up_paused_reason, v_actor);
  end if;
  return null;
end $$;
create trigger pipeline_request_history after insert or update on public.requests
  for each row execute function private.pipeline_request_history();

-- A quote or proposal sent for a request moves it to "Quote/proposal sent" (forward only, as above).
create function private.pipeline_quote_sent() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_to public.pipeline_stages; v_at public.pipeline_stages;
begin
  if new.request_id is null or new.change_order_for is not null or new.is_template then return null; end if;
  v_to := private.pipeline_stage(new.company_id, 'quote_sent');
  select s.* into v_at from public.requests r join public.pipeline_stages s on s.id = r.stage_id where r.id = new.request_id;
  if v_to.id is not null and (v_at.id is null or (v_at.kind = 'open' and v_at.sort < v_to.sort)) then
    update public.requests set stage_id = v_to.id where id = new.request_id and company_id = new.company_id and status not in ('converted', 'archived');
  end if;
  return null;
end $$;
create trigger pipeline_quote_sent after update of status on public.quotes
  for each row when (new.status = 'sent' and old.status is distinct from 'sent')
  execute function private.pipeline_quote_sent();

-- ---------------------------------------------------------------------------------------------
-- 4. Contacts, pauses
-- ---------------------------------------------------------------------------------------------

-- A call, text, email, meeting or note logged on a request: kept in the client's messages, on the
-- request, by whoever logged it. Recorded, never sent. A contact with the customer updates the
-- request's last contact (and first response); an inbound one pauses its follow-ups.
create function public.log_request_contact(p_request uuid, p_channel text, p_direction text, p_body text, p_subject text default null, p_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_id uuid; v_at timestamptz := least(coalesce(p_at, now()), now());
begin
  select * into r from public.requests where id = p_request;
  if not found or ((select auth.uid()) is not null and not (private.has_role(r.company_id, '{owner,admin,office,estimator}') and private.has_perm(r.company_id, 'sales'))) then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if p_channel not in ('call', 'sms', 'email', 'note') or p_direction not in ('in', 'out', 'internal') or (p_channel = 'note') <> (p_direction = 'internal') then
    raise exception 'Log a call, text or email to or from the customer, or an internal note.' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null or char_length(p_body) > 4000 then
    raise exception 'Say what was said (up to 4,000 characters).' using errcode = '22023';
  end if;
  if v_at < r.created_at - interval '1 day' then
    raise exception 'That''s from before the request came in.' using errcode = '22023';
  end if;
  insert into public.messages (company_id, client_id, channel, direction, subject, body, status, related_type, related_id, sent_by, created_at)
  values (r.company_id, r.client_id, p_channel, p_direction, nullif(btrim(coalesce(p_subject, '')), ''), btrim(p_body),
          case when p_direction = 'in' then 'received' else 'sent' end, 'request', r.id, (select auth.uid()), v_at)
  returning id into v_id;
  insert into public.request_pipeline_events (company_id, request_id, kind, to_value, actor_id)
  values (r.company_id, r.id, 'contact', p_channel || ' ' || p_direction, (select auth.uid()));
  if p_direction <> 'internal' then
    update public.requests
       set last_contact_at = greatest(coalesce(last_contact_at, v_at), v_at),
           first_response_at = case when first_response_at is null and p_direction = 'out' then v_at else first_response_at end
     where id = r.id;
  end if;
  if p_direction = 'in' then
    perform private.pause_follow_ups(r.id, 'customer_replied');
  end if;
  return v_id;
end $$;
revoke execute on function public.log_request_contact(uuid, text, text, text, text, timestamptz) from public, anon;
grant execute on function public.log_request_contact(uuid, text, text, text, text, timestamptz) to authenticated;

-- Pauses a request's follow-ups for a reason, unless they're paused already.
create function private.pause_follow_ups(p_request uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$
  update public.requests set follow_up_paused_at = now(), follow_up_paused_reason = p_reason
   where id = p_request and follow_up_paused_at is null and status not in ('converted', 'archived')
$$;

-- An inbound message from the customer anywhere (not only one logged on a request) pauses the
-- follow-ups of their open requests; so does opting out of messages.
create function private.pipeline_customer_replied() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.client_id is not null and new.direction = 'in' and new.related_type is distinct from 'request' then
    update public.requests set follow_up_paused_at = now(), follow_up_paused_reason = 'customer_replied'
     where company_id = new.company_id and client_id = new.client_id and follow_up_paused_at is null and status not in ('converted', 'archived');
  end if;
  return null;
end $$;
create trigger pipeline_customer_replied after insert on public.messages
  for each row when (new.direction = 'in') execute function private.pipeline_customer_replied();

create function private.pipeline_opted_out() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.requests set follow_up_paused_at = now(), follow_up_paused_reason = 'opted_out'
   where company_id = new.company_id and client_id = new.id and follow_up_paused_at is null and status not in ('converted', 'archived');
  return null;
end $$;
create trigger pipeline_opted_out after update of marketing_opt_out, sms_opt_out_at on public.clients
  for each row when ((new.marketing_opt_out and not coalesce(old.marketing_opt_out, false)) or (new.sms_opt_out_at is not null and old.sms_opt_out_at is null))
  execute function private.pipeline_opted_out();

-- A follow-up added by hand: for the request's owner unless someone else is named, due when given.
create function public.add_request_follow_up(p_request uuid, p_title text, p_due_on date default null, p_assigned_to uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_id uuid := gen_random_uuid();
begin
  select * into r from public.requests where id = p_request;
  if not found or ((select auth.uid()) is not null and not (private.has_role(r.company_id, '{owner,admin,office,estimator}') and private.has_perm(r.company_id, 'sales'))) then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null or char_length(p_title) > 300 then
    raise exception 'Say what the follow-up is.' using errcode = '22023';
  end if;
  if p_assigned_to is not null and not exists (select 1 from public.memberships m where m.company_id = r.company_id and m.user_id = p_assigned_to and m.active) then
    raise exception 'Pick someone on the team.' using errcode = '22023';
  end if;
  insert into public.follow_up_tasks (id, company_id, assigned_to, title, link, related_type, related_id, source, source_id, due_on, created_by)
  values (v_id, r.company_id, coalesce(p_assigned_to, r.assigned_to), btrim(p_title), '/requests/' || r.id, 'request', r.id, 'manual', v_id, p_due_on, (select auth.uid()));
  return v_id;
end $$;
revoke execute on function public.add_request_follow_up(uuid, text, date, uuid) from public, anon;
grant execute on function public.add_request_follow_up(uuid, text, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 6. Reports and pricing history
-- ---------------------------------------------------------------------------------------------

-- What a request was quoted: its latest sent quote or proposal (not a change order), the signed
-- price once signed.
create function private.request_quoted_amount(p_request uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((q.approval -> 'choices' ->> 'total')::numeric, (q.approval ->> 'total')::numeric, q.total)
    from public.quotes q
   where q.request_id = p_request and q.change_order_for is null and not q.is_template and q.sent_at is not null
   order by (q.status in ('approved', 'converted')) desc, q.sent_at desc
   limit 1
$$;

-- The pipeline report for the requests that came in between two dates (the business's own days),
-- and the outcomes decided between them. Defined dates:
--   requests        came in (created_at) in the period; counted by source, and by their stage now
--   aging           open requests now: days since they came in, days in their stage
--   response        hours from coming in to the first contact logged (requests in the period)
--   conversion      decided in the period (outcome_at): won ÷ (won + lost); unqualified apart
--   won/lost value  the quoted amount (signed, else the latest sent) of those decided in the period
create function public.pipeline_report(p_company uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_tz text; v_start timestamptz; v_end timestamptz; v_result jsonb;
begin
  if (select auth.uid()) is not null and not (private.has_role(p_company, '{owner,admin,office,estimator}') and private.has_perm(p_company, 'sales')) then
    raise exception 'Reports need the Sales area.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3660 then
    raise exception 'Pick a period of up to ten years.' using errcode = '22023';
  end if;
  select coalesce(timezone, 'UTC') into v_tz from public.companies where id = p_company;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;

  with came as (
    select r.*, s.kind, s.label, s.sort from public.requests r left join public.pipeline_stages s on s.id = r.stage_id
     where r.company_id = p_company and r.created_at >= v_start and r.created_at < v_end
  ), decided as (
    select r.id, s.kind, r.source, private.request_quoted_amount(r.id) as amount
      from public.requests r join public.pipeline_stages s on s.id = r.stage_id
     where r.company_id = p_company and r.outcome_at >= v_start and r.outcome_at < v_end and s.kind in ('won', 'lost', 'unqualified')
  ), open_now as (
    select r.*, s.label from public.requests r join public.pipeline_stages s on s.id = r.stage_id
     where r.company_id = p_company and s.kind in ('open', 'nurture') and r.status not in ('converted', 'archived')
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'requests', (select count(*) from came),
    'by_source', (select coalesce(jsonb_object_agg(source, n), '{}') from (select coalesce(source, 'unknown') as source, count(*) as n from came group by 1) x),
    'by_stage', (select coalesce(jsonb_agg(jsonb_build_object('label', coalesce(label, 'Archived'), 'count', n) order by sort nulls last), '[]')
                   from (select label, sort, count(*) as n from came group by label, sort) x),
    'open', (select count(*) from open_now),
    'aging', jsonb_build_object(
      'average_days', (select round(avg(extract(epoch from now() - created_at) / 86400)::numeric, 1) from open_now),
      'oldest_days', (select floor(max(extract(epoch from now() - created_at) / 86400)) from open_now),
      'average_days_in_stage', (select round(avg(extract(epoch from now() - stage_entered_at) / 86400)::numeric, 1) from open_now),
      'over_30_days', (select count(*) from open_now where created_at < now() - interval '30 days')),
    'response', jsonb_build_object(
      'responded', (select count(*) from came where first_response_at is not null),
      'not_yet', (select count(*) from came where first_response_at is null),
      'median_hours', (select round((percentile_cont(0.5) within group (order by extract(epoch from first_response_at - created_at) / 3600))::numeric, 1) from came where first_response_at is not null)),
    'won', (select count(*) from decided where kind = 'won'),
    'lost', (select count(*) from decided where kind = 'lost'),
    'unqualified', (select count(*) from decided where kind = 'unqualified'),
    'conversion', (select case when count(*) filter (where kind in ('won', 'lost')) > 0
                                then round(count(*) filter (where kind = 'won')::numeric / count(*) filter (where kind in ('won', 'lost')), 3) end from decided),
    'conversion_by_source', (select coalesce(jsonb_object_agg(src, rate), '{}') from (
        select coalesce(source, 'unknown') as src, round(count(*) filter (where kind = 'won')::numeric / nullif(count(*) filter (where kind in ('won', 'lost')), 0), 3) as rate
          from decided group by 1) x where rate is not null),
    'won_value', (select coalesce(sum(amount), 0) from decided where kind = 'won'),
    'lost_value', (select coalesce(sum(amount), 0) from decided where kind = 'lost')
  ) into v_result;
  return v_result;
end $$;
revoke execute on function public.pipeline_report(uuid, date, date) from public, anon;
grant execute on function public.pipeline_report(uuid, date, date) to authenticated;

-- Prices quoted to customers, for estimating and sales: each sent quote or proposal for a request
-- (not change orders), with the request's service, location, estimator and outcome. Filters are
-- optional. A lost or unanswered price is sales evidence, not an actual cost or a benchmark.
create function public.pipeline_pricing_history(p_company uuid, p_service text default null, p_location text default null,
  p_from date default null, p_to date default null, p_estimator uuid default null, p_outcome text default null)
returns table (request_id uuid, request_number bigint, request_title text, service text, city text, region text, postal_code text,
               quote_id uuid, quote_number bigint, presentation text, amount numeric, sent_at timestamptz, estimator_id uuid,
               outcome text, outcome_at timestamptz, outcome_reason text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and not (private.has_role(p_company, '{owner,admin,office,estimator}') and private.has_perm(p_company, 'sales')) then
    raise exception 'Pricing history needs the Sales area.' using errcode = '42501';
  end if;
  if p_outcome is not null and p_outcome not in ('won', 'lost', 'unqualified', 'nurture', 'open') then
    raise exception 'Unknown outcome.' using errcode = '22023';
  end if;
  return query
    select r.id, r.number, r.title, r.service, p.city, p.region, p.postal_code,
           q.id, q.number, q.presentation,
           coalesce((q.approval -> 'choices' ->> 'total')::numeric, (q.approval ->> 'total')::numeric, q.total),
           q.sent_at, r.estimator_id, coalesce(s.kind, 'open'), r.outcome_at, r.outcome_reason
      from public.quotes q
      join public.requests r on r.id = q.request_id and r.company_id = q.company_id
      left join public.pipeline_stages s on s.id = r.stage_id
      left join public.properties p on p.id = coalesce(q.property_id, r.property_id)
     where q.company_id = p_company and q.change_order_for is null and not q.is_template and q.sent_at is not null
       and (p_service is null or r.service ilike '%' || p_service || '%' or r.title ilike '%' || p_service || '%')
       and (p_location is null or concat_ws(' ', p.city, p.region, p.postal_code) ilike '%' || p_location || '%')
       and (p_from is null or q.sent_at >= p_from::timestamptz)
       and (p_to is null or q.sent_at < (p_to + 1)::timestamptz)
       and (p_estimator is null or r.estimator_id = p_estimator)
       and (p_outcome is null or coalesce(s.kind, 'open') = p_outcome)
     order by q.sent_at desc
     limit 500;
end $$;
revoke execute on function public.pipeline_pricing_history(uuid, text, text, date, date, uuid, text) from public, anon;
grant execute on function public.pipeline_pricing_history(uuid, text, text, date, date, uuid, text) to authenticated;

revoke execute on function private.pipeline_stage_rules(), private.install_pipeline_stages(uuid), private.company_pipeline_defaults(),
  private.install_pipeline_cadence(uuid), private.pipeline_stage(uuid, text), private.pipeline_default_owner(uuid),
  private.pipeline_request(), private.pipeline_contact_times(), private.pipeline_event_stays(), private.pipeline_cadence_tasks(uuid, uuid),
  private.close_request_follow_ups(uuid, text, boolean), private.pipeline_request_history(), private.pipeline_quote_sent(),
  private.pause_follow_ups(uuid, text), private.pipeline_customer_replied(), private.pipeline_opted_out(),
  private.request_quoted_amount(uuid) from public;

select private.fold_member_checks('public.pipeline_stages');
select private.fold_member_checks('public.pipeline_templates');
select private.fold_member_checks('public.pipeline_cadence_steps');
select private.fold_member_checks('public.request_pipeline_events');

notify pgrst, 'reload schema';
