-- Planet Ops Phase 2 follow-ups (after 20261122000100_planet_ops_pipeline.sql):
--
-- 1. Resuming a request's follow-ups restores the current stage's unfinished cadence reminders,
--    once: those its pause closed are reopened (due when they were, or today if that's passed); a
--    step never made (the stage was entered while paused) is made, due as it would have been, or
--    today. Completed reminders stay completed, and reminders from an earlier stage stay closed.
--    Repeated resumes and retries make nothing twice. A decided request (Won, Lost, Unqualified) and
--    a customer who opted out of messages can't be resumed by hand.
-- 2. Follow-ups keep their identity when snoozed or rescheduled (never to a past day, on the
--    business's own date), and the request's history says what happened to each: created, done,
--    cancelled (why), reopened, rescheduled. A follow-up can be the request's next action
--    (requests.next_action_task_id): moving it moves the next action's date, and doing it clears
--    the next action; a next action typed by hand stands on its own.
-- 3. Won without a job: someone in sales may mark a request won with a note saying why. A sales
--    classification only: no job, invoice, payment, signature, deposit or folder handoff is made,
--    and no agreement changes. Converting a signed agreement still links its request and job once.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

alter table public.request_pipeline_events drop constraint request_pipeline_events_kind_check;
alter table public.request_pipeline_events add constraint request_pipeline_events_kind_check
  check (kind in ('stage', 'owner', 'estimator', 'next_action', 'outcome', 'paused', 'resumed', 'contact', 'follow_up'));
comment on column public.request_pipeline_events.from_value is 'As it read before; for a follow_up event, what happened to it: created, done, cancelled:<reason>, reopened, rescheduled.';

alter table public.requests add column next_action_task_id uuid;
alter table public.requests add constraint requests_next_action_task_fkey foreign key (company_id, next_action_task_id)
  references public.follow_up_tasks (company_id, id) on delete set null (next_action_task_id);
comment on column public.requests.next_action_task_id is 'Planet Ops: the open follow-up the next action is, kept in step with it; null when the next action was typed by hand.';

-- ---------------------------------------------------------------------------------------------
-- The request's rules (as in 20261122000100, and: Won with a note; resuming; the linked next action)
-- ---------------------------------------------------------------------------------------------

create or replace function private.pipeline_request() returns trigger
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
      or new.service is distinct from old.service or new.next_action_task_id is distinct from old.next_action_task_id;
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
    -- Won: a job made from it, or a sales call someone in sales makes with a note saying why (no job,
    -- no signature, no deposit: a classification only, kept in the history).
    if v_new.kind = 'won' and new.status is distinct from 'converted'
       and not exists (select 1 from public.jobs j where j.company_id = new.company_id and j.request_id = new.id)
       and nullif(btrim(coalesce(new.outcome_reason, '')), '') is null then
      raise exception 'Say why it''s won (a note). Marking it won is a sales call only: it makes no job, signature or payment.' using errcode = '23514';
    end if;
    if v_new.kind in ('lost', 'unqualified') then
      if nullif(btrim(coalesce(new.outcome_reason, '')), '') is null then
        raise exception 'Say why it was % (the outcome reason).', lower(v_new.label) using errcode = '23514';
      end if;
    elsif v_new.kind = 'won' then
      null; -- a won note stays with it
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
  elsif new.follow_up_paused_at is null then
    new.follow_up_paused_reason := null;
  end if;
  -- Resuming by hand (the stage unchanged): never a decided request, and never over an opt-out.
  if tg_op = 'UPDATE' and old.follow_up_paused_at is not null and new.follow_up_paused_at is null and new.stage_id is not distinct from old.stage_id then
    if v_old.kind in ('won', 'lost', 'unqualified') then
      raise exception 'This request is decided (%). Move it back into the pipeline to follow it up again.', v_old.label using errcode = '22023';
    end if;
    if exists (select 1 from public.clients c where c.id = new.client_id and (c.marketing_opt_out or c.sms_opt_out_at is not null)) then
      raise exception 'The customer opted out of messages, so their follow-ups stay paused.' using errcode = '22023';
    end if;
  end if;
  -- A next action typed or changed by hand (not kept in step with its follow-up) stands on its own.
  if tg_op = 'UPDATE' and new.next_action_task_id is not distinct from old.next_action_task_id and pg_trigger_depth() = 1
     and (new.next_action is distinct from old.next_action or new.next_action_on is distinct from old.next_action_on) then
    new.next_action_task_id := null;
  end if;
  if tg_op = 'UPDATE' and new.next_action_task_id is distinct from old.next_action_task_id and new.next_action_task_id is not null
     and not exists (select 1 from public.follow_up_tasks t where t.id = new.next_action_task_id and t.related_type = 'request' and t.related_id = new.id and t.done_at is null) then
    raise exception 'The next action can only be one of this request''s open follow-ups.' using errcode = '22023';
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

-- The current stage's cadence, restored on resume: reopens what the pause closed, makes what the
-- pause kept from being made, leaves done and earlier-stage reminders alone. Idempotent.
create function private.restore_follow_ups(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_event uuid; v_entered timestamptz; v_today date; v_entry_day date; v_on boolean; v_tz text;
begin
  select * into r from public.requests where id = p_request;
  if not found or r.stage_id is null or r.follow_up_paused_at is not null or r.status in ('converted', 'archived') then return; end if;
  select coalesce(c.timezone, 'UTC'), coalesce((c.settings -> 'pipeline' ->> 'reminders')::boolean, true) into v_tz, v_on from public.companies c where c.id = r.company_id;
  if not v_on then return; end if;
  v_today := (now() at time zone v_tz)::date;
  select e.id, e.created_at into v_event, v_entered from public.request_pipeline_events e
   where e.request_id = r.id and e.kind = 'stage' and e.to_stage_id = r.stage_id order by e.created_at desc, e.id desc limit 1;
  if v_event is null then return; end if;
  v_entry_day := (v_entered at time zone v_tz)::date;
  -- What the pause closed: open again, due as before or today.
  update public.follow_up_tasks t set done_at = null, done_by = null, closed_reason = null, due_on = greatest(coalesce(t.due_on, v_today), v_today)
    from public.pipeline_cadence_steps s
   where s.company_id = r.company_id and s.stage_id = r.stage_id and s.active
     and t.source = 'cadence' and t.source_id = md5(v_event::text || s.id::text)::uuid
     and t.done_at is not null and t.closed_reason in ('paused', 'customer_replied', 'opted_out');
  -- What the pause kept from being made.
  insert into public.follow_up_tasks (company_id, assigned_to, title, body, link, related_type, related_id, source, source_id, due_on)
  select r.company_id, r.assigned_to, s.title || ': ' || r.title,
         case when t.id is not null then 'Use the "' || t.name || '" ' || case s.channel when 'sms' then 'text' else s.channel end || ' template.' end,
         '/requests/' || r.id, 'request', r.id, 'cadence', md5(v_event::text || s.id::text)::uuid, greatest(v_entry_day + s.after_days, v_today)
    from public.pipeline_cadence_steps s
    left join public.pipeline_templates t on t.id = s.template_id and t.active
   where s.company_id = r.company_id and s.stage_id = r.stage_id and s.active
  on conflict (source, source_id) do nothing;
end $$;

create or replace function private.pipeline_request_history() returns trigger
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
    perform private.restore_follow_ups(new.id);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Follow-ups: rescheduling, their history, the next action that is one
-- ---------------------------------------------------------------------------------------------

-- Runs as whoever is writing: the app's own functions (restoring, closing) are trusted; a person
-- writing straight to the table (the screens, the API) is held to these.
create function private.follow_up_rules() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare v_today date;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.due_on is distinct from old.due_on then
    if old.done_at is not null then
      raise exception 'That follow-up is closed. Add a new one instead.' using errcode = '22023';
    end if;
    v_today := private.company_today(new.company_id);
    if new.due_on is null or new.due_on < v_today then
      raise exception 'Move it to today or a later day.' using errcode = '22023';
    end if;
  end if;
  if (new.title, new.source, new.source_id, new.related_type, new.related_id, new.company_id)
     is distinct from (old.title, old.source, old.source_id, old.related_type, old.related_id, old.company_id) then
    raise exception 'A follow-up keeps what it is; add a new one for something else.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger follow_up_rules before update on public.follow_up_tasks
  for each row execute function private.follow_up_rules();

create function private.follow_up_history() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_what text; v_detail text;
begin
  if new.related_type is distinct from 'request' or new.related_id is null then return null; end if;
  if tg_op = 'INSERT' then
    v_what := 'created';
    v_detail := new.title || coalesce(' · due ' || new.due_on::text, '');
  elsif old.done_at is null and new.done_at is not null then
    v_what := case when new.closed_reason is null then 'done' else 'cancelled:' || new.closed_reason end;
    v_detail := new.title;
  elsif old.done_at is not null and new.done_at is null then
    v_what := 'reopened';
    v_detail := new.title || coalesce(' · due ' || new.due_on::text, '');
  elsif new.due_on is distinct from old.due_on then
    v_what := 'rescheduled';
    v_detail := new.title || ' · ' || coalesce(old.due_on::text, 'no date') || ' → ' || coalesce(new.due_on::text, 'no date');
  else
    return null;
  end if;
  insert into public.request_pipeline_events (company_id, request_id, kind, from_value, to_value, actor_id)
  values (new.company_id, new.related_id, 'follow_up', v_what, left(v_detail, 600), (select auth.uid()));
  -- The next action that is this follow-up moves with it, and is cleared once it's done or closed.
  if tg_op = 'UPDATE' then
    if new.done_at is not null then
      update public.requests set next_action_task_id = null,
             next_action = case when new.closed_reason is null then null else next_action end,
             next_action_on = case when new.closed_reason is null then null else next_action_on end
       where id = new.related_id and next_action_task_id = new.id;
    elsif new.due_on is distinct from old.due_on then
      update public.requests set next_action_on = new.due_on where id = new.related_id and next_action_task_id = new.id;
    end if;
  end if;
  return null;
end $$;
create trigger follow_up_history after insert or update on public.follow_up_tasks
  for each row execute function private.follow_up_history();

-- As in 20261122000100, and: it can be made the request's next action.
drop function public.add_request_follow_up(uuid, text, date, uuid);
create function public.add_request_follow_up(p_request uuid, p_title text, p_due_on date default null, p_assigned_to uuid default null, p_next_action boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.requests; v_id uuid := gen_random_uuid(); v_today date;
begin
  select * into r from public.requests where id = p_request;
  if not found or ((select auth.uid()) is not null and not (private.has_role(r.company_id, '{owner,admin,office,estimator}') and private.has_perm(r.company_id, 'sales'))) then
    raise exception 'Request not found.' using errcode = 'P0002';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null or char_length(p_title) > 300 then
    raise exception 'Say what the follow-up is.' using errcode = '22023';
  end if;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date into v_today from public.companies c where c.id = r.company_id;
  if p_due_on is not null and p_due_on < v_today then
    raise exception 'Pick today or a later day.' using errcode = '22023';
  end if;
  if p_assigned_to is not null and not exists (select 1 from public.memberships m where m.company_id = r.company_id and m.user_id = p_assigned_to and m.active) then
    raise exception 'Pick someone on the team.' using errcode = '22023';
  end if;
  insert into public.follow_up_tasks (id, company_id, assigned_to, title, link, related_type, related_id, source, source_id, due_on, created_by)
  values (v_id, r.company_id, coalesce(p_assigned_to, r.assigned_to), btrim(p_title), '/requests/' || r.id, 'request', r.id, 'manual', v_id, p_due_on, (select auth.uid()));
  if p_next_action then
    update public.requests set next_action = btrim(p_title), next_action_on = p_due_on, next_action_task_id = v_id where id = r.id;
  end if;
  return v_id;
end $$;
revoke execute on function public.add_request_follow_up(uuid, text, date, uuid, boolean) from public, anon;
grant execute on function public.add_request_follow_up(uuid, text, date, uuid, boolean) to authenticated;

revoke execute on function private.restore_follow_ups(uuid), private.follow_up_rules(), private.follow_up_history() from public;

notify pgrst, 'reload schema';
