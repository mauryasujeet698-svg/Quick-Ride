-- Initial Quick-Ride schema; deployed to Supabase project czbelhtemzklcmssumpc.
create extension if not exists postgis with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at = now(); return new; end; $$;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text, avatar_url text, phone_e164 text,
 account_status text not null default 'active' check (account_status in ('active','restricted','suspended','deleted')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.user_roles (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check (role in ('customer','driver','admin','operations')),
 assigned_at timestamptz not null default now(), assigned_by uuid references auth.users(id) on delete set null,
 unique(user_id,role)
);
create table public.driver_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 verification_status text not null default 'pending' check (verification_status in ('pending','under_review','approved','rejected','suspended')),
 availability_status text not null default 'offline' check (availability_status in ('offline','online','busy')),
 vehicle_category_id bigint, vehicle_registration text, vehicle_make text, vehicle_model text, vehicle_color text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.service_areas (
 id bigint generated always as identity primary key, name text not null, city text not null, state text not null,
 country_code char(2) not null default 'IN', timezone text not null default 'Asia/Kolkata',
 boundary extensions.geography(MultiPolygon,4326), is_active boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.vehicle_categories (
 id bigint generated always as identity primary key, code text not null unique, name text not null,
 description text, is_active boolean not null default false, sort_order integer not null default 0,
 created_at timestamptz not null default now()
);
alter table public.driver_profiles add constraint driver_profiles_vehicle_category_id_fkey
 foreign key(vehicle_category_id) references public.vehicle_categories(id) on delete set null;
create table public.fare_configs (
 id bigint generated always as identity primary key,
 service_area_id bigint not null references public.service_areas(id) on delete restrict,
 vehicle_category_id bigint not null references public.vehicle_categories(id) on delete restrict,
 currency char(3) not null default 'INR', base_fare numeric(12,2) not null check(base_fare>=0),
 per_km_rate numeric(12,2) not null check(per_km_rate>=0), per_minute_rate numeric(12,2) not null default 0 check(per_minute_rate>=0),
 minimum_fare numeric(12,2) not null check(minimum_fare>=0), booking_fee numeric(12,2) not null default 0 check(booking_fee>=0),
 multiplier numeric(6,3) not null default 1 check(multiplier between 0.1 and 10),
 valid_from timestamptz not null default now(), valid_until timestamptz, is_active boolean not null default false,
 created_at timestamptz not null default now(), check(valid_until is null or valid_until>valid_from)
);
create table public.rides (
 id uuid primary key default gen_random_uuid(), customer_id uuid not null references auth.users(id) on delete restrict,
 driver_id uuid references auth.users(id) on delete restrict,
 service_area_id bigint references public.service_areas(id) on delete restrict,
 vehicle_category_id bigint not null references public.vehicle_categories(id) on delete restrict,
 status text not null default 'requested' check(status in ('requested','searching','offered','accepted','driver_arriving','arrived','in_progress','completed','cancelled','no_driver_found')),
 pickup_location extensions.geography(Point,4326) not null, destination_location extensions.geography(Point,4326) not null,
 pickup_address text not null, destination_address text not null,
 estimated_distance_m integer check(estimated_distance_m is null or estimated_distance_m>=0),
 estimated_duration_s integer check(estimated_duration_s is null or estimated_duration_s>=0),
 estimated_fare numeric(12,2) check(estimated_fare is null or estimated_fare>=0),
 final_fare numeric(12,2) check(final_fare is null or final_fare>=0), currency char(3) not null default 'INR',
 requested_at timestamptz not null default now(), accepted_at timestamptz, started_at timestamptz, completed_at timestamptz,
 cancelled_at timestamptz, cancellation_reason text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.ride_offers (
 id uuid primary key default gen_random_uuid(), ride_id uuid not null references public.rides(id) on delete cascade,
 driver_id uuid not null references auth.users(id) on delete cascade,
 status text not null default 'pending' check(status in ('pending','accepted','rejected','expired','withdrawn')),
 offered_at timestamptz not null default now(), expires_at timestamptz not null, responded_at timestamptz,
 unique(ride_id,driver_id), check(expires_at>offered_at)
);
create table public.driver_locations (
 driver_id uuid primary key references auth.users(id) on delete cascade,
 location extensions.geography(Point,4326) not null,
 heading_degrees numeric(6,2) check(heading_degrees is null or (heading_degrees>=0 and heading_degrees<360)),
 speed_mps numeric(8,2) check(speed_mps is null or speed_mps>=0),
 accuracy_m numeric(8,2) check(accuracy_m is null or accuracy_m>=0),
 recorded_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.ride_events (
 id bigint generated always as identity primary key, ride_id uuid not null references public.rides(id) on delete cascade,
 actor_user_id uuid references auth.users(id) on delete set null, event_type text not null,
 previous_status text, new_status text, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create index service_areas_boundary_gix on public.service_areas using gist(boundary);
create index fare_configs_lookup_idx on public.fare_configs(service_area_id,vehicle_category_id,is_active,valid_from desc);
create index rides_customer_created_idx on public.rides(customer_id,created_at desc);
create index rides_driver_status_idx on public.rides(driver_id,status,created_at desc);
create index rides_status_requested_idx on public.rides(status,requested_at);
create index rides_pickup_gix on public.rides using gist(pickup_location);
create index rides_destination_gix on public.rides using gist(destination_location);
create index ride_offers_driver_status_idx on public.ride_offers(driver_id,status,expires_at);
create index ride_offers_ride_status_idx on public.ride_offers(ride_id,status);
create index driver_locations_location_gix on public.driver_locations using gist(location);
create index driver_locations_recorded_idx on public.driver_locations(recorded_at desc);
create index ride_events_ride_created_idx on public.ride_events(ride_id,created_at);

create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger driver_profiles_set_updated_at before update on public.driver_profiles for each row execute function public.set_updated_at();
create trigger service_areas_set_updated_at before update on public.service_areas for each row execute function public.set_updated_at();
create trigger rides_set_updated_at before update on public.rides for each row execute function public.set_updated_at();
create trigger driver_locations_set_updated_at before update on public.driver_locations for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.driver_profiles enable row level security;
alter table public.service_areas enable row level security;
alter table public.vehicle_categories enable row level security;
alter table public.fare_configs enable row level security;
alter table public.rides enable row level security;
alter table public.ride_offers enable row level security;
alter table public.driver_locations enable row level security;
alter table public.ride_events enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated using((select auth.uid())=id);
create policy profiles_insert_own on public.profiles for insert to authenticated with check((select auth.uid())=id);
create policy user_roles_select_own on public.user_roles for select to authenticated using((select auth.uid())=user_id);
create policy driver_profiles_select_own on public.driver_profiles for select to authenticated using((select auth.uid())=user_id);
create policy driver_profiles_insert_own_pending on public.driver_profiles for insert to authenticated with check((select auth.uid())=user_id and verification_status='pending' and availability_status='offline');
create policy service_areas_read_active on public.service_areas for select to anon,authenticated using(is_active=true);
create policy vehicle_categories_read_active on public.vehicle_categories for select to anon,authenticated using(is_active=true);
create policy fare_configs_read_active on public.fare_configs for select to anon,authenticated using(is_active=true and valid_from<=now() and (valid_until is null or valid_until>now()));
create policy rides_customer_insert_requested on public.rides for insert to authenticated with check((select auth.uid())=customer_id and driver_id is null and status='requested' and final_fare is null);
create policy rides_customer_or_assigned_driver_read on public.rides for select to authenticated using((select auth.uid())=customer_id or (select auth.uid())=driver_id);
create policy ride_offers_driver_read_own on public.ride_offers for select to authenticated using((select auth.uid())=driver_id);
create policy driver_locations_driver_insert_own on public.driver_locations for insert to authenticated with check((select auth.uid())=driver_id and exists(select 1 from public.driver_profiles dp where dp.user_id=(select auth.uid()) and dp.verification_status='approved'));
create policy driver_locations_driver_update_own on public.driver_locations for update to authenticated using((select auth.uid())=driver_id and exists(select 1 from public.driver_profiles dp where dp.user_id=(select auth.uid()) and dp.verification_status='approved')) with check((select auth.uid())=driver_id and exists(select 1 from public.driver_profiles dp where dp.user_id=(select auth.uid()) and dp.verification_status='approved'));
create policy driver_locations_customer_read_active_ride on public.driver_locations for select to authenticated using(exists(select 1 from public.rides r where r.driver_id=driver_locations.driver_id and r.customer_id=(select auth.uid()) and r.status in ('accepted','driver_arriving','arrived','in_progress')));
-- ride_events receives an explicit deny-all policy in migration 003.
