-- Quick-Ride platform operations v2.
-- Adds location-scoped business models, pincode activation, dispatch policy,
-- driver subscriptions, financial records, ride chaining, support and auditability.
create extension if not exists btree_gist with schema extensions;

create table if not exists public.service_area_pincodes (
  id bigint generated always as identity primary key,
  service_area_id bigint not null references public.service_areas(id) on delete restrict,
  pincode text not null unique check (pincode ~ '^[1-9][0-9]{5}$'),
  label text,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.service_area_commercial_configs (
  id uuid primary key default gen_random_uuid(),
  pincode_id bigint not null references public.service_area_pincodes(id) on delete restrict,
  business_model text not null check (business_model in ('subscription','commission','hybrid')),
  subscription_amount numeric(12,2),
  subscription_period text check (subscription_period in ('day','week','month','year')),
  commission_percent numeric(6,3),
  currency char(3) not null default 'INR',
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint commercial_config_valid_window check (valid_until is null or valid_until > valid_from),
  constraint commercial_config_shape check (
    (business_model = 'subscription'
      and subscription_amount is not null and subscription_amount >= 0
      and subscription_period is not null and commission_percent is null)
    or
    (business_model = 'commission'
      and subscription_amount is null and subscription_period is null
      and commission_percent is not null and commission_percent between 0 and 100)
    or
    (business_model = 'hybrid'
      and subscription_amount is not null and subscription_amount >= 0
      and subscription_period is not null
      and commission_percent is not null and commission_percent between 0 and 100)
  )
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'commercial_config_no_active_overlap'
      and conrelid = 'public.service_area_commercial_configs'::regclass
  ) then
    alter table public.service_area_commercial_configs
      add constraint commercial_config_no_active_overlap
      exclude using gist (
        pincode_id with =,
        tstzrange(valid_from, coalesce(valid_until, 'infinity'::timestamptz), '[)') with &&
      ) where (is_active);
  end if;
end $$;

create index if not exists service_area_pincodes_area_idx
  on public.service_area_pincodes(service_area_id, is_active);
create index if not exists commercial_configs_current_idx
  on public.service_area_commercial_configs(pincode_id, valid_from desc)
  where is_active;

create table if not exists public.service_area_dispatch_configs (
  id bigint generated always as identity primary key,
  pincode_id bigint not null unique references public.service_area_pincodes(id) on delete cascade,
  initial_radius_m integer not null default 2000 check (initial_radius_m between 100 and 50000),
  max_radius_m integer not null default 15000 check (max_radius_m between 100 and 100000),
  radius_step_m integer not null default 2000 check (radius_step_m between 100 and 25000),
  offer_batch_size integer not null default 5 check (offer_batch_size between 1 and 50),
  offer_ttl_seconds integer not null default 15 check (offer_ttl_seconds between 5 and 180),
  location_max_age_seconds integer not null default 45 check (location_max_age_seconds between 5 and 600),
  chain_pickup_distance_m integer not null default 1500 check (chain_pickup_distance_m between 100 and 15000),
  chain_offer_ttl_seconds integer not null default 90 check (chain_offer_ttl_seconds between 10 and 600),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dispatch_radius_order check (max_radius_m >= initial_radius_m)
);

create table if not exists public.driver_subscriptions (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references auth.users(id) on delete restrict,
  pincode_id bigint not null references public.service_area_pincodes(id) on delete restrict,
  commercial_config_id uuid not null references public.service_area_commercial_configs(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','active','past_due','cancelled','expired','refunded')),
  period_start timestamptz not null,
  period_end timestamptz not null,
  amount numeric(12,2) not null check (amount >= 0),
  currency char(3) not null default 'INR',
  payment_record_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint driver_subscription_period check (period_end > period_start)
);
create index if not exists driver_subscriptions_eligibility_idx
  on public.driver_subscriptions(driver_id, pincode_id, status, period_end desc);

create table if not exists public.payment_records (
  id uuid primary key default gen_random_uuid(),
  payer_user_id uuid references auth.users(id) on delete restrict,
  payee_user_id uuid references auth.users(id) on delete restrict,
  ride_id uuid references public.rides(id) on delete restrict,
  driver_subscription_id uuid references public.driver_subscriptions(id) on delete restrict,
  payment_purpose text not null check (payment_purpose in ('ride_fare','driver_subscription','platform_fee','refund','adjustment')),
  payment_method text not null check (payment_method in ('cash','upi_direct','upi_platform','gateway','bank_transfer','other')),
  provider text,
  provider_reference text,
  idempotency_key text not null unique,
  status text not null default 'created' check (status in ('created','pending','authorized','captured','failed','cancelled','refunded','partially_refunded','disputed')),
  amount numeric(12,2) not null check (amount >= 0),
  currency char(3) not null default 'INR',
  captured_at timestamptz,
  refunded_amount numeric(12,2) not null default 0 check (refunded_amount >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_reference_unique unique(provider, provider_reference),
  constraint payment_refund_lte_amount check (refunded_amount <= amount)
);
create index if not exists payment_records_payer_idx on public.payment_records(payer_user_id, created_at desc);
create index if not exists payment_records_ride_idx on public.payment_records(ride_id, created_at desc);

create table if not exists public.ride_commissions (
  ride_id uuid primary key references public.rides(id) on delete restrict,
  driver_id uuid not null references auth.users(id) on delete restrict,
  pincode_id bigint not null references public.service_area_pincodes(id) on delete restrict,
  commercial_config_id uuid not null references public.service_area_commercial_configs(id) on delete restrict,
  business_model_snapshot text not null check (business_model_snapshot in ('subscription','commission','hybrid')),
  commission_percent_snapshot numeric(6,3) not null check (commission_percent_snapshot between 0 and 100),
  fare_amount numeric(12,2) not null check (fare_amount >= 0),
  commission_amount numeric(12,2) not null check (commission_amount >= 0),
  currency char(3) not null default 'INR',
  settlement_status text not null default 'pending' check (settlement_status in ('pending','due','settled','waived','reversed')),
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists ride_commissions_driver_status_idx
  on public.ride_commissions(driver_id, settlement_status, created_at desc);

create table if not exists public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  ride_id uuid references public.rides(id) on delete restrict,
  payment_record_id uuid references public.payment_records(id) on delete restrict,
  entry_type text not null check (entry_type in ('ride_fare','commission','subscription_charge','settlement','refund','adjustment')),
  direction text not null check (direction in ('debit','credit')),
  amount numeric(12,2) not null check (amount >= 0),
  currency char(3) not null default 'INR',
  status text not null default 'pending' check (status in ('pending','posted','reversed')),
  idempotency_key text not null unique,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ledger_entries_owner_idx on public.ledger_entries(owner_user_id, created_at desc);

create table if not exists public.driver_documents (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references auth.users(id) on delete cascade,
  document_type text not null check (document_type in ('driving_license','vehicle_rc','insurance','permit','identity','address_proof','profile_photo','other')),
  storage_bucket text not null default 'driver-documents',
  object_path text not null,
  verification_status text not null default 'pending' check (verification_status in ('pending','under_review','approved','rejected','expired')),
  document_number_last4 text,
  issued_at date,
  expires_at date,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(driver_id, document_type, object_path)
);
create index if not exists driver_documents_review_idx on public.driver_documents(verification_status, created_at);

create table if not exists public.ride_chain_offers (
  id uuid primary key default gen_random_uuid(),
  next_ride_id uuid not null references public.rides(id) on delete cascade,
  current_ride_id uuid not null references public.rides(id) on delete cascade,
  driver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'offered' check (status in ('offered','preaccepted','rejected','expired','activated','withdrawn')),
  estimated_remaining_distance_m integer check (estimated_remaining_distance_m is null or estimated_remaining_distance_m >= 0),
  distance_from_current_destination_m integer not null check (distance_from_current_destination_m >= 0),
  estimated_seconds_to_destination integer check (estimated_seconds_to_destination is null or estimated_seconds_to_destination >= 0),
  offered_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  unique(next_ride_id, driver_id),
  constraint chain_offer_expiry check (expires_at > offered_at),
  constraint chain_offer_distinct_rides check (next_ride_id <> current_ride_id)
);
create index if not exists ride_chain_offers_driver_status_idx
  on public.ride_chain_offers(driver_id, status, expires_at);
create index if not exists ride_chain_offers_current_ride_idx
  on public.ride_chain_offers(current_ride_id, status);

create table if not exists public.ride_support_tickets (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid references public.rides(id) on delete set null,
  submitted_by uuid not null references auth.users(id) on delete restrict,
  category text not null,
  subject text not null,
  description text not null,
  status text not null default 'open' check (status in ('open','in_progress','waiting_for_customer','resolved','closed')),
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  assigned_to uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ride_support_tickets_owner_idx on public.ride_support_tickets(submitted_by, created_at desc);

create table if not exists public.ride_safety_events (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete restrict,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  event_type text not null check (event_type in ('sos_triggered','emergency_contact_notified','trip_shared','safety_check_in','incident_reported','safety_resolved')),
  location extensions.geography(Point,4326),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ride_safety_events_ride_idx on public.ride_safety_events(ride_id, created_at desc);

create table if not exists public.admin_audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_table text not null,
  target_id text,
  before_data jsonb,
  after_data jsonb,
  request_id text,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_logs_actor_idx on public.admin_audit_logs(actor_user_id, created_at desc);
create index if not exists admin_audit_logs_target_idx on public.admin_audit_logs(target_table, target_id, created_at desc);

alter table public.rides
  add column if not exists pincode_id bigint references public.service_area_pincodes(id) on delete restrict,
  add column if not exists commercial_config_id uuid references public.service_area_commercial_configs(id) on delete restrict,
  add column if not exists commercial_model_snapshot text,
  add column if not exists commercial_terms_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists fare_config_id bigint references public.fare_configs(id) on delete restrict,
  add column if not exists fare_breakdown jsonb not null default '{}'::jsonb,
  add column if not exists booking_idempotency_key text,
  add column if not exists pickup_otp_hash text,
  add column if not exists chain_from_ride_id uuid references public.rides(id) on delete set null;

create unique index if not exists rides_customer_idempotency_idx
  on public.rides(customer_id, booking_idempotency_key)
  where booking_idempotency_key is not null;

alter table public.driver_locations
  add column if not exists geohash_7 text generated always as (
    extensions.st_geohash(location::extensions.geometry, 7)
  ) stored;
create index if not exists driver_locations_geohash_7_idx
  on public.driver_locations(geohash_7);

-- All new application tables use RLS. Writes to finance/config/dispatch/audit data
-- are performed by trusted Edge Functions with the server-side key only.
alter table public.service_area_pincodes enable row level security;
alter table public.service_area_commercial_configs enable row level security;
alter table public.service_area_dispatch_configs enable row level security;
alter table public.driver_subscriptions enable row level security;
alter table public.payment_records enable row level security;
alter table public.ride_commissions enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.driver_documents enable row level security;
alter table public.ride_chain_offers enable row level security;
alter table public.ride_support_tickets enable row level security;
alter table public.ride_safety_events enable row level security;
alter table public.admin_audit_logs enable row level security;

drop policy if exists service_area_pincodes_read_active on public.service_area_pincodes;
create policy service_area_pincodes_read_active
  on public.service_area_pincodes for select to anon, authenticated
  using (is_active and exists (
    select 1 from public.service_areas a
    where a.id = service_area_id and a.is_active
  ));

drop policy if exists driver_subscriptions_read_own on public.driver_subscriptions;
create policy driver_subscriptions_read_own
  on public.driver_subscriptions for select to authenticated
  using ((select auth.uid()) = driver_id);

drop policy if exists payment_records_read_participant on public.payment_records;
create policy payment_records_read_participant
  on public.payment_records for select to authenticated
  using ((select auth.uid()) = payer_user_id or (select auth.uid()) = payee_user_id);

drop policy if exists ledger_entries_read_own on public.ledger_entries;
create policy ledger_entries_read_own
  on public.ledger_entries for select to authenticated
  using ((select auth.uid()) = owner_user_id);

drop policy if exists driver_documents_read_own on public.driver_documents;
create policy driver_documents_read_own
  on public.driver_documents for select to authenticated
  using ((select auth.uid()) = driver_id);

drop policy if exists ride_chain_offers_read_own on public.ride_chain_offers;
create policy ride_chain_offers_read_own
  on public.ride_chain_offers for select to authenticated
  using ((select auth.uid()) = driver_id);

drop policy if exists ride_support_tickets_read_own on public.ride_support_tickets;
create policy ride_support_tickets_read_own
  on public.ride_support_tickets for select to authenticated
  using ((select auth.uid()) = submitted_by);

drop policy if exists ride_support_tickets_insert_own on public.ride_support_tickets;
create policy ride_support_tickets_insert_own
  on public.ride_support_tickets for insert to authenticated
  with check ((select auth.uid()) = submitted_by and status = 'open' and assigned_to is null);

revoke all on public.service_area_pincodes from anon, authenticated;
revoke all on public.service_area_commercial_configs from anon, authenticated;
revoke all on public.service_area_dispatch_configs from anon, authenticated;
revoke all on public.driver_subscriptions from anon, authenticated;
revoke all on public.payment_records from anon, authenticated;
revoke all on public.ride_commissions from anon, authenticated;
revoke all on public.ledger_entries from anon, authenticated;
revoke all on public.driver_documents from anon, authenticated;
revoke all on public.ride_chain_offers from anon, authenticated;
revoke all on public.ride_support_tickets from anon, authenticated;
revoke all on public.ride_safety_events from anon, authenticated;
revoke all on public.admin_audit_logs from anon, authenticated;

grant select on public.service_area_pincodes to anon, authenticated;
grant select on public.driver_subscriptions to authenticated;
grant select on public.payment_records to authenticated;
grant select on public.ledger_entries to authenticated;
grant select on public.driver_documents to authenticated;
grant select on public.ride_chain_offers to authenticated;
grant select, insert on public.ride_support_tickets to authenticated;

-- Booking must go through the trusted booking Edge Function. Client inserts allowed
-- in the initial foundation are removed before any customer application is released.
revoke insert on public.rides from authenticated;

comment on table public.service_area_pincodes is 'Admin-managed serviceable Indian PIN codes mapped to operating areas.';
comment on table public.service_area_commercial_configs is 'Effective-dated subscription, commission or hybrid pricing rules per service pincode.';
comment on table public.ride_chain_offers is 'Provisional next-ride offers; these do not assign a busy driver until the current trip is completed.';
comment on column public.driver_locations.geohash_7 is 'Generated geohash cell for locality bucketing; PostGIS geography indexes remain authoritative for radius matching.';
comment on column public.rides.commercial_terms_snapshot is 'Immutable terms captured when the customer books; later admin changes do not reprice existing rides.';

