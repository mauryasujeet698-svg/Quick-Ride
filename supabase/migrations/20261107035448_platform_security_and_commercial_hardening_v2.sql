-- Hardening pass: explicit deny policies for server-only data, FK indexes,
-- and atomic effective-dated pincode commercial configuration changes.

do $$
declare t text;
begin
  foreach t in array array[
    'admin_audit_logs',
    'ride_commissions',
    'ride_safety_events',
    'service_area_commercial_configs',
    'service_area_dispatch_configs'
  ] loop
    if not exists (
      select 1 from pg_policies
      where schemaname='public' and tablename=t and policyname=t || '_deny_client_access'
    ) then
      execute format(
        'create policy %I on public.%I for all to anon, authenticated using (false) with check (false)',
        t || '_deny_client_access', t
      );
    end if;
  end loop;
end $$;

create index if not exists driver_documents_reviewed_by_idx on public.driver_documents(reviewed_by);
create index if not exists driver_subscriptions_commercial_config_idx on public.driver_subscriptions(commercial_config_id);
create index if not exists driver_subscriptions_pincode_idx on public.driver_subscriptions(pincode_id);
create index if not exists ledger_entries_payment_record_idx on public.ledger_entries(payment_record_id);
create index if not exists ledger_entries_ride_idx on public.ledger_entries(ride_id);
create index if not exists payment_records_subscription_idx on public.payment_records(driver_subscription_id);
create index if not exists payment_records_payee_idx on public.payment_records(payee_user_id);
create index if not exists ride_commissions_commercial_config_idx on public.ride_commissions(commercial_config_id);
create index if not exists ride_commissions_pincode_idx on public.ride_commissions(pincode_id);
create index if not exists ride_safety_events_actor_idx on public.ride_safety_events(actor_user_id);
create index if not exists ride_support_tickets_assigned_to_idx on public.ride_support_tickets(assigned_to);
create index if not exists ride_support_tickets_ride_idx on public.ride_support_tickets(ride_id);
create index if not exists rides_chain_from_ride_idx on public.rides(chain_from_ride_id);
create index if not exists rides_commercial_config_idx on public.rides(commercial_config_id);
create index if not exists rides_fare_config_idx on public.rides(fare_config_id);
create index if not exists rides_pincode_idx on public.rides(pincode_id);
create index if not exists commercial_configs_created_by_idx on public.service_area_commercial_configs(created_by);

create or replace function public.admin_set_pincode_commercial_config(
  p_actor uuid,
  p_pincode_id bigint,
  p_business_model text,
  p_subscription_amount numeric default null,
  p_subscription_period text default null,
  p_commission_percent numeric default null,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pincode public.service_area_pincodes%rowtype;
  v_effective_at timestamptz;
  v_config public.service_area_commercial_configs%rowtype;
  v_before jsonb;
begin
  if p_actor is null then
    raise exception 'Actor is required' using errcode='22023';
  end if;

  if not exists (
    select 1 from public.user_roles ur
    join public.profiles pr on pr.id=ur.user_id
    where ur.user_id=p_actor and ur.role in ('admin','operations')
      and pr.account_status='active'
  ) then
    raise exception 'Administrator access is required' using errcode='42501';
  end if;

  if p_business_model not in ('subscription','commission','hybrid') then
    raise exception 'Unsupported business model' using errcode='22023';
  end if;

  if p_business_model in ('subscription','hybrid') then
    if p_subscription_amount is null or p_subscription_amount < 0
       or p_subscription_period not in ('day','week','month','year') then
      raise exception 'Subscription amount and billing period are required' using errcode='22023';
    end if;
  elsif p_subscription_amount is not null or p_subscription_period is not null then
    raise exception 'Subscription fields are not allowed for commission-only model' using errcode='22023';
  end if;

  if p_business_model in ('commission','hybrid') then
    if p_commission_percent is null or p_commission_percent < 0 or p_commission_percent > 100 then
      raise exception 'Commission percentage must be between 0 and 100' using errcode='22023';
    end if;
  elsif p_commission_percent is not null then
    raise exception 'Commission is not allowed for subscription-only model' using errcode='22023';
  end if;

  if p_valid_until is not null and p_valid_until <= coalesce(p_valid_from, now()) then
    raise exception 'Validity end must be after validity start' using errcode='22023';
  end if;

  select * into v_pincode
  from public.service_area_pincodes
  where id=p_pincode_id
  for update;

  if not found then
    raise exception 'Pincode not found' using errcode='P0002';
  end if;

  v_effective_at := greatest(coalesce(p_valid_from, clock_timestamp()), clock_timestamp());

  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_before
  from public.service_area_commercial_configs c
  where c.pincode_id=p_pincode_id and c.is_active
    and c.valid_from < v_effective_at
    and (c.valid_until is null or c.valid_until > v_effective_at);

  update public.service_area_commercial_configs
  set valid_until=v_effective_at
  where pincode_id=p_pincode_id and is_active
    and valid_from < v_effective_at
    and (valid_until is null or valid_until > v_effective_at);

  insert into public.service_area_commercial_configs(
    pincode_id,business_model,subscription_amount,subscription_period,
    commission_percent,currency,valid_from,valid_until,is_active,created_by
  )
  values (
    p_pincode_id,p_business_model,p_subscription_amount,p_subscription_period,
    p_commission_percent,'INR',v_effective_at,p_valid_until,true,p_actor
  )
  returning * into v_config;

  insert into public.admin_audit_logs(
    actor_user_id,action,target_table,target_id,before_data,after_data
  )
  values (
    p_actor,'commercial_config.created','service_area_commercial_configs',
    v_config.id::text,v_before,to_jsonb(v_config)
  );

  return jsonb_build_object(
    'commercial_config',to_jsonb(v_config),
    'previous_configs_closed',jsonb_array_length(v_before)
  );
end;
$$;

revoke all on function public.admin_set_pincode_commercial_config(uuid,bigint,text,numeric,text,numeric,timestamptz,timestamptz)
from public,anon,authenticated;
grant execute on function public.admin_set_pincode_commercial_config(uuid,bigint,text,numeric,text,numeric,timestamptz,timestamptz)
to service_role;

-- Older rides must keep the commercial snapshot taken at booking even when
-- their originating configuration is later superseded.
create or replace function public.accept_ride_offer(
  p_offer_id uuid,
  p_driver_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer public.ride_offers%rowtype;
  v_ride public.rides%rowtype;
  v_driver public.driver_profiles%rowtype;
  v_previous_status text;
  v_business_model text;
begin
  select * into v_offer from public.ride_offers where id=p_offer_id for update;
  if not found or v_offer.driver_id<>p_driver_id
     or v_offer.status<>'pending' or v_offer.expires_at<=now() then
    raise exception 'Ride offer is unavailable or expired' using errcode='P0001';
  end if;

  select * into v_ride from public.rides where id=v_offer.ride_id for update;
  if not found or v_ride.driver_id is not null
     or v_ride.status not in ('requested','searching','offered') then
    raise exception 'Ride has already been assigned or is no longer available' using errcode='P0001';
  end if;
  v_previous_status := v_ride.status;

  select * into v_driver from public.driver_profiles where user_id=p_driver_id for update;
  if not found or v_driver.verification_status<>'approved'
     or v_driver.availability_status<>'online'
     or v_driver.vehicle_category_id<>v_ride.vehicle_category_id then
    raise exception 'Driver is not eligible for this ride' using errcode='P0001';
  end if;

  if exists (
    select 1 from public.rides r
    where r.driver_id=p_driver_id
      and r.status in ('accepted','driver_arriving','arrived','in_progress')
  ) then
    raise exception 'Driver already has an active ride' using errcode='P0001';
  end if;

  v_business_model := v_ride.commercial_model_snapshot;
  if v_business_model is null and v_ride.commercial_config_id is not null then
    select cc.business_model into v_business_model
    from public.service_area_commercial_configs cc
    where cc.id=v_ride.commercial_config_id;
  end if;

  if v_business_model in ('subscription','hybrid') and not exists (
    select 1 from public.driver_subscriptions ds
    where ds.driver_id=p_driver_id and ds.pincode_id=v_ride.pincode_id
      and ds.status='active' and ds.period_start<=now() and ds.period_end>now()
  ) then
    raise exception 'Driver subscription is not active for this service pincode' using errcode='P0001';
  end if;

  update public.rides
  set driver_id=p_driver_id,status='accepted',accepted_at=now()
  where id=v_ride.id and driver_id is null
  returning * into v_ride;

  if v_ride.driver_id is distinct from p_driver_id then
    raise exception 'Ride assignment lost a concurrency race' using errcode='40001';
  end if;

  update public.ride_offers
  set status=case when id=p_offer_id then 'accepted' else 'withdrawn' end,
      responded_at=now()
  where ride_id=v_ride.id and status='pending';

  update public.driver_profiles set availability_status='busy' where user_id=p_driver_id;

  insert into public.ride_events(ride_id,actor_user_id,event_type,previous_status,new_status)
  values(v_ride.id,p_driver_id,'driver_accepted',v_previous_status,'accepted');

  return jsonb_build_object('ride_id',v_ride.id,'driver_id',p_driver_id,'status','accepted');
end;
$$;

revoke all on function public.accept_ride_offer(uuid,uuid) from public,anon,authenticated;
grant execute on function public.accept_ride_offer(uuid,uuid) to service_role;

