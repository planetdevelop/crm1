-- Planet Ops Phase 1: a change order is finalized only with the customer's signature on its exact
-- current version (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3, "Change orders for active jobs").
--
-- Finalizing a change order is moving it to 'approved' or 'converted': the change_order_approved
-- trigger then adds its lines to the job (private.apply_change_order), so it counts in the revised
-- contract and what can be invoiced. Until now that also happened from the office's "Mark approved"
-- and from "Convert" on an unsigned change order (services/sales.ts convertQuote keeps a "manual"
-- approval first). Now the database refuses both, whoever asks (signed in, an assistant, the server
-- or an automation), for added charges, credits and $0 changes alike.
--
-- A customer signature is an approval the customer made: on the client hub (approve_hub_quote) or
-- signed in person (sign_quote, method 'in_person'), each with the signer's name, the time and the
-- amounts they signed for. One the office kept without a signature says method 'manual'. "Exact
-- version": the total signed for must still be the change order's total, and once finalized its
-- lines can't change, so what was signed is what was added. A change after signing needs a new one.
--
-- Change orders already approved or converted keep their state: this only checks a change order as
-- it's finalized from now on. Packages/core/src/changeOrders.ts has the same rule for the interface.

create function private.change_order_customer_signed(p_approval jsonb, p_total numeric) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_approval) = 'object'
    and coalesce(p_approval ->> 'method', '') <> 'manual'
    and length(trim(coalesce(p_approval ->> 'name', ''))) > 0
    and coalesce(p_approval ->> 'signed_at', '') <> ''
    and (p_approval ->> 'total') ~ '^-?[0-9]+(\.[0-9]+)?$'
    and round((p_approval ->> 'total')::numeric, 2) = round(p_total, 2),
    false)
$$;

create function private.change_order_needs_signature() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.change_order_customer_signed(new.approval, new.total) then
    if jsonb_typeof(new.approval) = 'object' and coalesce(new.approval ->> 'method', '') <> 'manual'
       and coalesce(new.approval ->> 'signed_at', '') <> '' then
      raise exception 'This change order changed after the customer signed it, so it needs their signature again before it''s added to the job.'
        using errcode = '22023';
    end if;
    raise exception 'A change order is added to the job only once the customer signs this exact version. Send it to them to sign, or have them sign it in person.'
      using errcode = '22023';
  end if;
  return new;
end $$;

-- Checked as it's finalized: inserted finalized, or moving from an open state to a finalized one. A
-- change order already approved or converted (before this migration too) isn't checked again.
create trigger change_order_needs_signature before insert on public.quotes
  for each row
  when (new.change_order_for is not null and new.status in ('approved', 'converted'))
  execute function private.change_order_needs_signature();
create trigger change_order_needs_signature_update before update of status, change_order_for on public.quotes
  for each row
  when (new.change_order_for is not null and new.status in ('approved', 'converted')
        and (old.status not in ('approved', 'converted') or old.change_order_for is null))
  execute function private.change_order_needs_signature();


-- Once finalized, the signed version's lines don't change: a different scope or price is a new
-- change order (or the job's own lines), signed again.
create function private.signed_change_order_lines_stay() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_quote uuid;
begin
  -- A delete cascading from the quote or the company (a trigger deeper than this one) goes ahead.
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    v_quote := old.quote_id;
  elsif tg_op = 'UPDATE' then
    -- Only what was signed is locked: the scope and the price. A price-list service deleted (its
    -- link set to null) or a cost noted for job costing changes neither.
    if (new.quote_id, new.name, new.description, new.quantity, new.unit, new.unit_price, new.taxable, new.selected, new.optional, new.option_id)
       is not distinct from
       (old.quote_id, old.name, old.description, old.quantity, old.unit, old.unit_price, old.taxable, old.selected, old.optional, old.option_id) then
      return new;
    end if;
    v_quote := old.quote_id;
  else
    v_quote := new.quote_id;
  end if;
  if exists (select 1 from public.quotes q
              where q.id = v_quote and q.change_order_for is not null and q.status in ('approved', 'converted')) then
    raise exception 'This change order was signed by the customer and added to the job, so its lines can''t change. Make a new change order for anything else.'
      using errcode = '22023';
  end if;
  return coalesce(new, old);
end $$;

create trigger signed_change_order_lines_stay before insert or update or delete on public.quote_line_items
  for each row execute function private.signed_change_order_lines_stay();

revoke execute on function private.change_order_customer_signed(jsonb, numeric) from public;
revoke execute on function private.change_order_needs_signature() from public;
revoke execute on function private.signed_change_order_lines_stay() from public;
