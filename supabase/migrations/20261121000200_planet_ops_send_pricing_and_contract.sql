-- Planet Ops Phase 1d: preparing pricing apart from sending it, and the job's contract summary
-- (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §2 Permissions, §3; docs/planet-ops/PERMISSIONS.md gap 1).
--
-- 1. A new area, send_pricing ("Send pricing to customers"). The sales area builds quotes,
--    proposals and change orders; sending one to the customer (or sending it again, its exact
--    price, its range, or making it available to sign again) needs send_pricing too. Owners, admins,
--    office and estimators have it by default, and every existing custom role that sells keeps it,
--    so nobody loses what they do today. A custom role can now prepare pricing without sending it.
--    Enforced here for anyone signed in (the office's screens, the API, connected assistants); the
--    API checks it first and says so.
-- 2. public.job_contract_summary: a job's original signed agreement, each change order with its
--    state, the finalized changes (credits included), the revised contract total, and the invoiced,
--    paid and outstanding amounts and what's left to invoice, each kept to its own meaning. A revised
--    total is never an invoice, a payment or a balance; only finalized change orders count, once.

-- ---------------------------------------------------------------------------------------------
-- 1. send_pricing
-- ---------------------------------------------------------------------------------------------

-- As in 20261028000100_careers.sql, with send_pricing (mirrors LEVEL_PERMISSIONS in packages/core/src/roles.ts).
create or replace function private.level_permissions(p_level public.member_role) returns text[]
language sql immutable parallel safe set search_path = '' as $$
  select case p_level
    when 'owner' then array['sales','send_pricing','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','apps','equipment','subs','hiring']
    when 'admin' then array['sales','send_pricing','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','apps','equipment','subs','hiring']
    when 'office' then array['sales','send_pricing','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','equipment','subs','hiring']
    when 'estimator' then array['sales','send_pricing','schedule','equipment']
    when 'crew_lead' then array['schedule','timesheets','equipment']
    else array[]::text[]
  end
$$;

-- Custom roles that sell keep sending: nobody loses what they do today.
update public.company_roles set permissions = permissions || array['send_pricing']
 where 'sales' = any (permissions) and not ('send_pricing' = any (permissions)) and base_role in ('admin', 'office', 'estimator');

-- A new business's roles, as in 20261028000100_careers.sql: those that sell send too.
create or replace function private.install_default_roles(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.company_roles (company_id, name, description, base_role, permissions) values
    (p_company, 'General manager', 'Runs the business day to day.', 'admin',
     array['sales','send_pricing','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','team','equipment','subs','hiring']),
    (p_company, 'Office manager', 'Books work, schedules crews, sends quotes and invoices, and approves time.', 'office',
     array['sales','send_pricing','invoices','job_costs','reports','marketing','automations','schedule','timesheets','settings','kb_edit','equipment','subs','hiring']),
    (p_company, 'Operations manager', 'Schedules crews and keeps jobs on track.', 'office',
     array['sales','send_pricing','job_costs','reports','schedule','timesheets','kb_edit','equipment','subs']),
    (p_company, 'Foreman', 'Runs their crew: schedules its visits, assigns its people and sees its time. No prices.', 'crew_lead', array['equipment']),
    (p_company, 'Employee', 'Works their own visits.', 'field_crew', array[]::text[])
  on conflict do nothing
$$;

-- Whether whoever is asking may send pricing for this company: the server (no one signed in), or a
-- member who sells with the send_pricing area.
create function private.can_send_pricing(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is null
      or (private.has_role(p_company, '{owner,admin,office,estimator}') and private.has_perm(p_company, 'sales') and private.has_perm(p_company, 'send_pricing'))
$$;

-- For the API and assistants to ask first, before anything goes out to the customer.
create function public.can_send_pricing(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.can_send_pricing(p_company)
$$;
revoke execute on function public.can_send_pricing(uuid) from public, anon;
grant execute on function public.can_send_pricing(uuid) to authenticated, service_role;

-- Sending: into "sent", or sent again (its sent, exact-price or range time moving), by someone signed
-- in, needs send_pricing. Preparing (any other change to a draft or a sent document) doesn't.
create function private.sending_needs_send_pricing() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.can_send_pricing(new.company_id) then
    raise exception 'Sending pricing to the customer needs the "Send pricing to customers" area. Ask someone who can send it.'
      using errcode = '42501';
  end if;
  return new;
end $$;
create trigger a_sending_needs_send_pricing before update of status, sent_at, exact_sent_at, range_sent_at on public.quotes
  for each row
  when (new.is_template is not true and ((new.status = 'sent' and old.status is distinct from 'sent')
        or (new.sent_at is distinct from old.sent_at and new.sent_at is not null)
        or (new.exact_sent_at is distinct from old.exact_sent_at and new.exact_sent_at is not null)
        or (new.range_sent_at is distinct from old.range_sent_at and new.range_sent_at is not null)))
  execute function private.sending_needs_send_pricing();
create trigger a_sending_needs_send_pricing_insert before insert on public.quotes
  for each row when (new.status = 'sent' and new.is_template is not true)
  execute function private.sending_needs_send_pricing();

-- As in 20261121000100, and issuing (resending, making available to sign again) needs send_pricing.
create or replace function public.issue_quote_version(p_quote uuid, p_via text default 'sent') returns uuid
language plpgsql security definer set search_path = '' as $$
declare q public.quotes; v_id uuid;
begin
  select * into q from public.quotes where id = p_quote for update;
  if not found then raise exception 'Quote not found.' using errcode = 'P0002'; end if;
  if (select auth.uid()) is not null and not (private.has_role(q.company_id, '{owner,admin,office,estimator}') and private.has_perm(q.company_id, 'sales')) then
    raise exception 'Only people who sell can send a document to the customer.' using errcode = '42501';
  end if;
  if not private.can_send_pricing(q.company_id) then
    raise exception 'Sending pricing to the customer needs the "Send pricing to customers" area. Ask someone who can send it.' using errcode = '42501';
  end if;
  if q.status not in ('sent', 'changes_requested') or q.is_template then
    raise exception 'Only a document that''s with the customer can be issued again.' using errcode = '22023';
  end if;
  if p_via not in ('sent', 'site_price') then
    raise exception 'Unknown way to issue a version.' using errcode = '22023';
  end if;
  v_id := private.issue_version(p_quote, p_via);
  perform private.answer_change_requests(p_quote, v_id);
  if q.status = 'changes_requested' then
    update public.quotes set status = 'sent' where id = p_quote;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. The job's contract summary
-- ---------------------------------------------------------------------------------------------

-- A change order's state on the job, in words the office reads: finalized only once the customer
-- signed (and, when required, the company countersigned) and it joined the job.
create function private.change_order_state(q public.quotes) returns text
language sql stable set search_path = '' as $$
  select case
    when q.status = 'converted' then 'finalized'
    when q.status = 'approved' then 'awaiting_countersign'
    when q.status = 'changes_requested' then 'changes_requested'
    when q.status = 'sent' then 'awaiting_signature'
    when q.status = 'draft' then 'draft'
    when q.status = 'lost' then 'declined'
    when q.status = 'archived' then 'cancelled'
    else q.status
  end
$$;

-- A change order's amount as signed: its total, or for a credit (a total can't go below zero; its
-- subtotal keeps the credit) its subtotal. As drafted until it's signed.
create function private.change_order_amount(q public.quotes) returns numeric
language sql stable set search_path = '' as $$
  select case
    when coalesce((q.approval -> 'choices' ->> 'subtotal')::numeric, (q.approval ->> 'subtotal')::numeric, q.subtotal) < 0
      then coalesce((q.approval -> 'choices' ->> 'subtotal')::numeric, (q.approval ->> 'subtotal')::numeric, q.subtotal)
    else coalesce((q.approval -> 'choices' ->> 'total')::numeric, (q.approval ->> 'total')::numeric, q.total)
  end
$$;

-- The job's contract, each figure kept to its meaning (owners, admins, office and estimators; the
-- invoice figures only for those with the invoices area).
create function public.job_contract_summary(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  j public.jobs;
  v_original jsonb;
  v_orders jsonb;
  v_changes numeric;
  v_original_amount numeric;
  v_invoices boolean;
  v_invoiced numeric;
  v_paid numeric;
  v_outstanding numeric;
begin
  select * into j from public.jobs where id = p_job;
  if not found or not private.has_role(j.company_id, '{owner,admin,office,estimator}') then
    raise exception 'Job not found.' using errcode = 'P0002';
  end if;
  -- The agreement it was made from: what the customer signed for.
  select jsonb_build_object('quote_id', q.id, 'number', q.number, 'title', q.title,
                            'amount', coalesce((q.approval -> 'choices' ->> 'total')::numeric, (q.approval ->> 'total')::numeric, q.total),
                            'signed_at', q.approval ->> 'signed_at', 'version_number', (q.approval ->> 'version_number')::int)
    into v_original
    from public.quotes q where q.company_id = j.company_id and q.id = j.quote_id;
  v_original_amount := coalesce((v_original ->> 'amount')::numeric, 0);

  -- Each change order once, with its state; only finalized ones count, credits included.
  select coalesce(jsonb_agg(jsonb_build_object(
           'quote_id', q.id, 'number', q.number, 'title', q.title, 'state', private.change_order_state(q),
           'amount', private.change_order_amount(q),
           'finalized_at', case when q.status = 'converted' then coalesce(q.converted_at, q.approved_at) end)
           order by q.created_at, q.id), '[]'),
         coalesce(sum(private.change_order_amount(q)) filter (where q.status = 'converted'), 0)
    into v_orders, v_changes
    from public.quotes q where q.company_id = j.company_id and q.change_order_for = j.id;

  v_invoices := private.has_perm(j.company_id, 'invoices');
  if v_invoices then
    select coalesce(sum(i.total), 0), coalesce(sum(i.amount_paid), 0), coalesce(sum(i.balance_due), 0)
      into v_invoiced, v_paid, v_outstanding
      from public.invoices i where i.company_id = j.company_id and i.job_id = j.id and i.status not in ('draft', 'void');
  end if;

  return jsonb_build_object(
    'job_id', j.id,
    'original', v_original,
    'original_amount', v_original_amount,
    'change_orders', v_orders,
    'finalized_changes', v_changes,
    'revised_total', v_original_amount + v_changes,
    'invoices_visible', v_invoices,
    'invoiced', v_invoiced,
    'paid', v_paid,
    'outstanding', v_outstanding,
    'not_yet_invoiced', case when v_invoices then v_original_amount + v_changes - v_invoiced end
  );
end $$;
revoke execute on function public.job_contract_summary(uuid) from public, anon;
grant execute on function public.job_contract_summary(uuid) to authenticated;

-- The deposit asked for as a document was signed, and what its invoice's payments have paid so far:
-- the deposit's own record, never implied by the signature (people who sell; core agreementFacts).
create function public.quote_deposit_status(p_quote uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare q public.quotes; i public.invoices;
begin
  select * into q from public.quotes where id = p_quote;
  if not found or ((select auth.uid()) is not null and not (private.has_role(q.company_id, '{owner,admin,office,estimator}') and private.has_perm(q.company_id, 'sales'))) then
    raise exception 'Quote not found.' using errcode = 'P0002';
  end if;
  if q.deposit_invoice_id is not null then
    select * into i from public.invoices where company_id = q.company_id and id = q.deposit_invoice_id;
  end if;
  return jsonb_build_object(
    'asked', case when i.id is not null then i.total else q.deposit_amount end,
    'paid', case when i.id is not null and i.status not in ('void', 'draft') then i.amount_paid end,
    'invoice_status', i.status);
end $$;
revoke execute on function public.quote_deposit_status(uuid) from public, anon;
grant execute on function public.quote_deposit_status(uuid) to authenticated;

revoke execute on function private.can_send_pricing(uuid), private.sending_needs_send_pricing(), private.change_order_state(public.quotes), private.change_order_amount(public.quotes) from public;
