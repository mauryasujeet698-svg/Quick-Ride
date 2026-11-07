create table public.ride_share_links (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  token_hash text not null unique
    check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_accessed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint ride_share_links_expiry_after_creation
    check (expires_at > created_at)
);

create index ride_share_links_ride_creator_idx
  on public.ride_share_links (ride_id, created_by, expires_at desc);

alter table public.ride_share_links enable row level security;
revoke all on table public.ride_share_links from anon, authenticated;
grant select, insert, update, delete on table public.ride_share_links to service_role;

create or replace function public.get_ride_share_snapshot(p_ride_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $function$
  select jsonb_build_object(
    'ride', jsonb_build_object(
      'id', r.id,
      'status', r.status,
      'pickup_address', r.pickup_address,
      'destination_address', r.destination_address,
      'pickup', jsonb_build_object(
        'latitude', extensions.st_y(r.pickup_location::extensions.geometry),
        'longitude', extensions.st_x(r.pickup_location::extensions.geometry)
      ),
      'destination', jsonb_build_object(
        'latitude', extensions.st_y(r.destination_location::extensions.geometry),
        'longitude', extensions.st_x(r.destination_location::extensions.geometry)
      ),
      'currency', r.currency,
      'estimated_fare', r.estimated_fare,
      'final_fare', r.final_fare,
      'requested_at', r.requested_at,
      'accepted_at', r.accepted_at,
      'started_at', r.started_at,
      'completed_at', r.completed_at,
      'cancelled_at', r.cancelled_at
    ),
    'driver', case when dp.user_id is null then null else jsonb_build_object(
      'name', coalesce(pr.full_name, 'Quick-Ride driver'),
      'avatar_url', pr.avatar_url,
      'vehicle_category', vc.name,
      'vehicle_make', dp.vehicle_make,
      'vehicle_model', dp.vehicle_model,
      'vehicle_color', dp.vehicle_color,
      'vehicle_registration', dp.vehicle_registration
    ) end,
    'driver_location', case
      when dl.recorded_at is null
        or dl.recorded_at < now() - interval '2 minutes'
      then null
      else jsonb_build_object(
        'latitude', extensions.st_y(dl.location::extensions.geometry),
        'longitude', extensions.st_x(dl.location::extensions.geometry),
        'heading_degrees', dl.heading_degrees,
        'recorded_at', dl.recorded_at
      )
    end
  )
  from public.rides r
  left join public.driver_profiles dp on dp.user_id = r.driver_id
  left join public.profiles pr on pr.id = dp.user_id
  left join public.vehicle_categories vc on vc.id = dp.vehicle_category_id
  left join public.driver_locations dl on dl.driver_id = r.driver_id
  where r.id = p_ride_id;
$function$;

revoke all on function public.get_ride_share_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.get_ride_share_snapshot(uuid) to service_role;
