-- Auto-only shared rides. Existing private bookings remain unchanged by default.
-- Shared Auto is deliberately disabled per pincode until Admin enables it.

alter table public.rides
  add column if not exists ride_mode text not null default 'private'
    check (ride_mode in ('private','shared_auto')),
  add column if not exists passenger_count smallint not null default 1
    check (passenger_count between 1 and 3),
  add column if not exists shared_auto_trip_id uuid;

create table if not exists public.shared_auto_configs (
  pincode_id bigint primary key references public.service_area_pincodes(id) on delete restrict,
  is_enabled boolean not null default false,
  seat_capacity smallint not null default 3 check (seat_capacity between 1 and 3),
  max_detour_percent numeric(5,2) not null default 40 check (max_detour_percent between 0 and 100),
  max_extra_minutes smallint not null default 15 check (max_extra_minutes between 0 and 60),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists public.shared_auto_trips (
  id uuid primary key default gen_random_uuid(),
  pincode_id bigint not null references public.service_area_pincodes(id) on delete restrict,
  service_area_id bigint not null references public.service_areas(id) on delete restrict,
  vehicle_category_id bigint not null references public.vehicle_categories(id) on delete restrict,
  lead_ride_id uuid not null references public.rides(id) on delete restrict,
  driver_id uuid references auth.users(id) on delete restrict,
  status text not null default 'matching'
    check (status in ('matching','assigned','in_progress','completed','cancelled')),
  seat_capacity smallint not null default 3 check (seat_capacity between 1 and 3),
  reserved_seats smallint not null check (reserved_seats between 1 and 3),
  route_distance_m integer check (route_distance_m is null or route_distance_m >= 0),
  route_duration_s integer check (route_duration_s is null or route_duration_s >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.rides
  add constraint rides_shared_auto_trip_fk
  foreign key (shared_auto_trip_id) references public.shared_auto_trips(id) on delete restrict;

create table if not exists public.shared_auto_trip_bookings (
  id uuid primary key default gen_random_uuid(),
  shared_auto_trip_id uuid not null references public.shared_auto_trips(id) on delete restrict,
  ride_id uuid not null unique references public.rides(id) on delete restrict,
  customer_id uuid not null references auth.users(id) on delete restrict,
  passenger_count smallint not null check (passenger_count between 1 and 3),
  status text not null default 'confirmed'
    check (status in ('confirmed','cancelled','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shared_auto_trip_stops (
  id bigint generated always as identity primary key,
  shared_auto_trip_id uuid not null references public.shared_auto_trips(id) on delete restrict,
  ride_id uuid not null references public.rides(id) on delete restrict,
  stop_type text not null check (stop_type in ('pickup','dropoff')),
  sequence_index smallint not null check (sequence_index between 1 and 6),
  location extensions.geography(Point,4326) not null,
  address text not null,
  status text not null default 'pending'
    check (status in ('pending','arrived','completed','skipped')),
  created_at timestamptz not null default now(),
  unique (shared_auto_trip_id, sequence_index),
  unique (ride_id, stop_type)
);

create index if not exists shared_auto_trips_match_idx
  on public.shared_auto_trips(pincode_id, vehicle_category_id, status, created_at)
  where status in ('matching','assigned');
create index if not exists shared_auto_trip_bookings_trip_idx
  on public.shared_auto_trip_bookings(shared_auto_trip_id, status);
create index if not exists shared_auto_trip_bookings_customer_idx
  on public.shared_auto_trip_bookings(customer_id, created_at desc);
create index if not exists shared_auto_trip_stops_trip_idx
  on public.shared_auto_trip_stops(shared_auto_trip_id, sequence_index);

insert into public.shared_auto_configs(pincode_id)
select p.id from public.service_area_pincodes p
on conflict (pincode_id) do nothing;

alter table public.shared_auto_configs enable row level security;
alter table public.shared_auto_trips enable row level security;
alter table public.shared_auto_trip_bookings enable row level security;
alter table public.shared_auto_trip_stops enable row level security;

create policy shared_auto_trips_read_participants
on public.shared_auto_trips for select to authenticated
using (
  driver_id = (select auth.uid())
  or exists (
    select 1 from public.shared_auto_trip_bookings b
    where b.shared_auto_trip_id = id and b.customer_id = (select auth.uid())
  )
);

create policy shared_auto_bookings_read_participants
on public.shared_auto_trip_bookings for select to authenticated
using (
  customer_id = (select auth.uid())
  or exists (
    select 1 from public.shared_auto_trips t
    where t.id = shared_auto_trip_id and t.driver_id = (select auth.uid())
  )
);

-- Customers can see their own pickup/drop records. Only the assigned driver can
-- see the complete route; other passengers' addresses are not exposed to peers.
create policy shared_auto_stops_read_own_or_driver
on public.shared_auto_trip_stops for select to authenticated
using (
  exists (
    select 1 from public.shared_auto_trip_bookings b
    where b.ride_id = shared_auto_trip_stops.ride_id
      and b.customer_id = (select auth.uid())
  )
  or exists (
    select 1 from public.shared_auto_trips t
    where t.id = shared_auto_trip_stops.shared_auto_trip_id
      and t.driver_id = (select auth.uid())
  )
);

create or replace function public.create_shared_auto_trip(
  p_ride_id uuid,
  p_passenger_count smallint,
  p_route_distance_m integer default null,
  p_route_duration_s integer default null,
  p_route_plan jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.rides%rowtype;
  v_config public.shared_auto_configs%rowtype;
  v_category public.vehicle_categories%rowtype;
  v_trip public.shared_auto_trips%rowtype;
  v_stop jsonb;
  v_stop_count integer := 0;
begin
  if p_passenger_count not between 1 and 3 then
    raise exception 'Shared Auto supports one to three passengers per booking' using errcode='22023';
  end if;

  select * into v_ride from public.rides where id=p_ride_id for update;
  if not found or v_ride.driver_id is not null
     or v_ride.status not in ('requested','searching','offered') then
    raise exception 'A new unassigned ride is required' using errcode='P0001';
  end if;

  if v_ride.pincode_id is null then
    raise exception 'Ride does not belong to an active service pincode' using errcode='P0001';
  end if;
  select * into v_category from public.vehicle_categories where id=v_ride.vehicle_category_id;
  if not found or lower(regexp_replace(v_category.code,'[^a-z0-9]','','g')) not in ('auto','autorickshaw') then
    raise exception 'Shared rides are currently available for Auto only' using errcode='22023';
  end if;

  select * into v_config from public.shared_auto_configs
  where pincode_id=v_ride.pincode_id for share;
  if not found or not v_config.is_enabled then
    raise exception 'Shared Auto is not enabled for this pincode' using errcode='P0001';
  end if;
  if p_passenger_count > v_config.seat_capacity then
    raise exception 'Passenger count exceeds this Auto capacity' using errcode='22023';
  end if;

  select * into v_trip from public.shared_auto_trips where lead_ride_id=p_ride_id;
  if found then
    return jsonb_build_object('shared_auto_trip_id',v_trip.id,'status',v_trip.status,'created',false);
  end if;

  insert into public.shared_auto_trips(
    pincode_id,service_area_id,vehicle_category_id,lead_ride_id,
    seat_capacity,reserved_seats,route_distance_m,route_duration_s
  ) values (
    v_ride.pincode_id,v_ride.service_area_id,v_ride.vehicle_category_id,v_ride.id,
    v_config.seat_capacity,p_passenger_count,p_route_distance_m,p_route_duration_s
  ) returning * into v_trip;

  insert into public.shared_auto_trip_bookings(
    shared_auto_trip_id,ride_id,customer_id,passenger_count
  ) values (v_trip.id,v_ride.id,v_ride.customer_id,p_passenger_count);

  update public.rides set ride_mode='shared_auto',passenger_count=p_passenger_count,
    shared_auto_trip_id=v_trip.id where id=v_ride.id;

  if jsonb_typeof(p_route_plan)='array' then
    for v_stop in select value from jsonb_array_elements(p_route_plan)
    loop
      insert into public.shared_auto_trip_stops(
        shared_auto_trip_id,ride_id,stop_type,sequence_index,location,address
      ) values (
        v_trip.id,
        (v_stop->>'ride_id')::uuid,
        v_stop->>'stop_type',
        (v_stop->>'sequence_index')::smallint,
        extensions.st_setsrid(
          extensions.st_makepoint(
            (v_stop->>'longitude')::double precision,
            (v_stop->>'latitude')::double precision
          ),4326
        )::extensions.geography,
        left(coalesce(v_stop->>'address',''),500)
      );
      v_stop_count := v_stop_count + 1;
    end loop;
    if v_stop_count <> 2 then
      raise exception 'A new shared Auto route requires one pickup and one dropoff' using errcode='22023';
    end if;
  else
    insert into public.shared_auto_trip_stops(
      shared_auto_trip_id,ride_id,stop_type,sequence_index,location,address
    ) values
      (v_trip.id,v_ride.id,'pickup',1,v_ride.pickup_location,v_ride.pickup_address),
      (v_trip.id,v_ride.id,'dropoff',2,v_ride.destination_location,v_ride.destination_address);
  end if;

  insert into public.ride_events(ride_id,event_type,new_status,details)
  values(v_ride.id,'shared_auto_trip_created',v_ride.status,
    jsonb_build_object('shared_auto_trip_id',v_trip.id,'passenger_count',p_passenger_count));

  return jsonb_build_object('shared_auto_trip_id',v_trip.id,'status',v_trip.status,'created',true);
end;
$$;

create or replace function public.join_shared_auto_trip(
  p_shared_auto_trip_id uuid,
  p_ride_id uuid,
  p_passenger_count smallint,
  p_route_distance_m integer,
  p_route_duration_s integer,
  p_detour_percent numeric,
  p_extra_minutes numeric,
  p_route_plan jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.shared_auto_trips%rowtype;
  v_ride public.rides%rowtype;
  v_config public.shared_auto_configs%rowtype;
  v_category public.vehicle_categories%rowtype;
  v_reserved integer;
  v_stop jsonb;
  v_stop_count integer := 0;
begin
  if p_passenger_count not between 1 and 3
     or p_route_distance_m is null or p_route_distance_m <= 0
     or p_route_duration_s is null or p_route_duration_s <= 0
     or p_detour_percent is null or p_detour_percent < 0
     or p_extra_minutes is null or p_extra_minutes < 0
     or jsonb_typeof(p_route_plan) <> 'array' then
    raise exception 'Invalid shared Auto route or passenger count' using errcode='22023';
  end if;

  select * into v_trip from public.shared_auto_trips
  where id=p_shared_auto_trip_id for update;
  if not found or v_trip.status not in ('matching','assigned') then
    raise exception 'This shared Auto is no longer accepting passengers' using errcode='P0001';
  end if;

  select * into v_ride from public.rides where id=p_ride_id for update;
  if not found or v_ride.driver_id is not null
     or v_ride.status not in ('requested','searching','offered')
     or v_ride.pincode_id <> v_trip.pincode_id
     or v_ride.vehicle_category_id <> v_trip.vehicle_category_id then
    raise exception 'Ride is not compatible with this shared Auto' using errcode='P0001';
  end if;
  select * into v_category from public.vehicle_categories where id=v_ride.vehicle_category_id;
  if not found or lower(regexp_replace(v_category.code,'[^a-z0-9]','','g')) not in ('auto','autorickshaw') then
    raise exception 'Shared rides are currently available for Auto only' using errcode='22023';
  end if;

  select * into v_config from public.shared_auto_configs
  where pincode_id=v_ride.pincode_id for share;
  if not found or not v_config.is_enabled then
    raise exception 'Shared Auto is not enabled for this pincode' using errcode='P0001';
  end if;

  select coalesce(sum(passenger_count),0) into v_reserved
  from public.shared_auto_trip_bookings
  where shared_auto_trip_id=v_trip.id and status='confirmed';
  if v_reserved + p_passenger_count > least(v_trip.seat_capacity,v_config.seat_capacity,3) then
    raise exception 'Not enough seats remain in this shared Auto' using errcode='P0001';
  end if;
  if p_detour_percent > v_config.max_detour_percent or p_extra_minutes > v_config.max_extra_minutes then
    raise exception 'The requested route adds too much detour for this shared Auto' using errcode='P0001';
  end if;

  insert into public.shared_auto_trip_bookings(
    shared_auto_trip_id,ride_id,customer_id,passenger_count
  ) values (v_trip.id,v_ride.id,v_ride.customer_id,p_passenger_count);

  update public.rides set ride_mode='shared_auto',passenger_count=p_passenger_count,
    shared_auto_trip_id=v_trip.id,
    driver_id=v_trip.driver_id,
    status=case when v_trip.driver_id is null then 'requested' else 'accepted' end,
    accepted_at=case when v_trip.driver_id is null then null else coalesce(accepted_at,now()) end
  where id=v_ride.id;

  delete from public.shared_auto_trip_stops where shared_auto_trip_id=v_trip.id;
  for v_stop in select value from jsonb_array_elements(p_route_plan)
  loop
    insert into public.shared_auto_trip_stops(
      shared_auto_trip_id,ride_id,stop_type,sequence_index,location,address
    ) values (
      v_trip.id,
      (v_stop->>'ride_id')::uuid,
      v_stop->>'stop_type',
      (v_stop->>'sequence_index')::smallint,
      extensions.st_setsrid(
        extensions.st_makepoint(
          (v_stop->>'longitude')::double precision,
          (v_stop->>'latitude')::double precision
        ),4326
      )::extensions.geography,
      left(coalesce(v_stop->>'address',''),500)
    );
    v_stop_count := v_stop_count + 1;
  end loop;
  if v_stop_count <> (v_reserved + p_passenger_count) * 2 then
    -- A customer booking may contain two or three seats; stops are still one
    -- pickup and one dropoff per booking, not one stop per passenger.
    if v_stop_count < 4 or v_stop_count > 6 then
      raise exception 'Shared Auto route must contain one pickup and dropoff per booking' using errcode='22023';
    end if;
  end if;

  update public.shared_auto_trips set
    reserved_seats=v_reserved + p_passenger_count,
    route_distance_m=p_route_distance_m,
    route_duration_s=p_route_duration_s,
    updated_at=now()
  where id=v_trip.id;

  insert into public.ride_events(ride_id,event_type,new_status,details)
  values(v_ride.id,'shared_auto_joined',v_ride.status,
    jsonb_build_object('shared_auto_trip_id',v_trip.id,'passenger_count',p_passenger_count));

  return jsonb_build_object(
    'shared_auto_trip_id',v_trip.id,
    'status',v_trip.status,
    'driver_id',v_trip.driver_id,
    'reserved_seats',v_reserved + p_passenger_count,
    'available_seats',least(v_trip.seat_capacity,v_config.seat_capacity,3) - v_reserved - p_passenger_count,
    'ride_id',v_ride.id
  );
end;
$$;

create or replace function public.sync_shared_auto_trip_from_ride()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip_id uuid;
  v_active_count integer;
begin
  v_trip_id := coalesce(new.shared_auto_trip_id,old.shared_auto_trip_id);
  if v_trip_id is null then return new; end if;

  if new.driver_id is not null and old.driver_id is null then
    update public.shared_auto_trips
    set driver_id=new.driver_id,status='assigned',updated_at=now()
    where id=v_trip_id and driver_id is null and status='matching';

    if found then
      update public.rides
      set driver_id=new.driver_id,status='accepted',accepted_at=now()
      where shared_auto_trip_id=v_trip_id and id<>new.id
        and driver_id is null and status in ('requested','searching','offered');
      update public.ride_offers
      set status='withdrawn',responded_at=now()
      where ride_id in (
        select id from public.rides where shared_auto_trip_id=v_trip_id
      ) and status='pending';
      update public.shared_auto_trip_bookings
      set updated_at=now()
      where shared_auto_trip_id=v_trip_id and status='confirmed';
    end if;
  end if;

  if new.status='in_progress' and old.status is distinct from new.status then
    update public.shared_auto_trips set status='in_progress',updated_at=now()
    where id=v_trip_id and status in ('matching','assigned');
  end if;

  if new.status in ('cancelled','completed','no_driver_found')
     and old.status is distinct from new.status then
    update public.shared_auto_trip_bookings
    set status=case when new.status='completed' then 'completed' else 'cancelled' end,
        updated_at=now()
    where ride_id=new.id and status='confirmed';

    if new.status<>'completed' then
      update public.shared_auto_trips
      set reserved_seats=greatest(0,reserved_seats - coalesce(
        (select passenger_count from public.shared_auto_trip_bookings where ride_id=new.id),0
      )),
      lead_ride_id=case when lead_ride_id=new.id then coalesce(
        (select b.ride_id
         from public.shared_auto_trip_bookings b
         join public.rides r on r.id=b.ride_id
         where b.shared_auto_trip_id=v_trip_id and b.status='confirmed'
           and r.id<>new.id and r.status not in ('cancelled','completed','no_driver_found')
         order by b.created_at limit 1),
        lead_ride_id
      ) else lead_ride_id end,
      status=case when not exists(
        select 1 from public.shared_auto_trip_bookings b
        where b.shared_auto_trip_id=v_trip_id and b.status='confirmed' and b.ride_id<>new.id
      ) then 'cancelled' else status end,
      updated_at=now()
      where id=v_trip_id and status in ('matching','assigned');
    end if;
  end if;

  select count(*) into v_active_count
  from public.shared_auto_trip_bookings b
  join public.rides r on r.id=b.ride_id
  where b.shared_auto_trip_id=v_trip_id and b.status='confirmed'
    and r.status not in ('completed','cancelled','no_driver_found');

  if v_active_count=0 then
    update public.shared_auto_trips set status='completed',updated_at=now()
    where id=v_trip_id and status='in_progress';
  end if;

  return new;
end;
$$;

drop trigger if exists rides_sync_shared_auto_trip on public.rides;
create trigger rides_sync_shared_auto_trip
after update of driver_id,status on public.rides
for each row execute function public.sync_shared_auto_trip_from_ride();

create or replace function public.get_shared_auto_trip_for_ride(p_ride_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.shared_auto_trips%rowtype;
  v_ride public.rides%rowtype;
begin
  select * into v_ride from public.rides where id=p_ride_id;
  if not found then raise exception 'Ride not found' using errcode='P0002'; end if;
  select * into v_trip from public.shared_auto_trips where id=v_ride.shared_auto_trip_id;
  if not found then return null; end if;
  return jsonb_build_object(
    'id',v_trip.id,'status',v_trip.status,'driver_id',v_trip.driver_id,
    'reserved_seats',v_trip.reserved_seats,'seat_capacity',v_trip.seat_capacity,
    'route_distance_m',v_trip.route_distance_m,'route_duration_s',v_trip.route_duration_s,
    'bookings',(select coalesce(jsonb_agg(jsonb_build_object(
      'ride_id',b.ride_id,'customer_id',b.customer_id,
      'passenger_count',b.passenger_count,'status',b.status,
      'pickup_address',r.pickup_address,'destination_address',r.destination_address,
      'ride_status',r.status
    ) order by b.created_at),'[]'::jsonb)
      from public.shared_auto_trip_bookings b join public.rides r on r.id=b.ride_id
      where b.shared_auto_trip_id=v_trip.id and b.status='confirmed')
  );
end;
$$;

-- These functions are called by trusted Edge Functions using the service role.
revoke all on function public.create_shared_auto_trip(uuid,smallint,integer,integer,jsonb)
  from public,anon,authenticated;
revoke all on function public.join_shared_auto_trip(uuid,uuid,smallint,integer,integer,numeric,numeric,jsonb)
  from public,anon,authenticated;
revoke all on function public.get_shared_auto_trip_for_ride(uuid)
  from public,anon,authenticated;

grant execute on function public.create_shared_auto_trip(uuid,smallint,integer,integer,jsonb)
  to service_role;
grant execute on function public.join_shared_auto_trip(uuid,uuid,smallint,integer,integer,numeric,numeric,jsonb)
  to service_role;
grant execute on function public.get_shared_auto_trip_for_ride(uuid)
  to service_role;

grant select,insert,update,delete on public.shared_auto_configs to service_role;
grant select,insert,update,delete on public.shared_auto_trips to service_role;
grant select,insert,update,delete on public.shared_auto_trip_bookings to service_role;
grant select,insert,update,delete on public.shared_auto_trip_stops to service_role;

comment on table public.shared_auto_trips is
  'One shared Auto vehicle journey. Shared Auto only; capacity is hard-limited to three seats.';
comment on table public.shared_auto_trip_bookings is
  'Each customer retains an independent ride booking and fare while joining one shared Auto trip.';
comment on table public.shared_auto_trip_stops is
  'Server-calculated combined pickup/dropoff order. Customers may read only their own stops; the assigned driver may read the full route.';
