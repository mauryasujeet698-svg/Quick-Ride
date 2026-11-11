create or replace function public.get_customer_ride_rebook_details(
  p_customer_id uuid,
  p_ride_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ride_id', r.id,
    'status', r.status,
    'vehicle_category_id', r.vehicle_category_id,
    'pickup', jsonb_build_object(
      'longitude', extensions.st_x(r.pickup_location::extensions.geometry),
      'latitude', extensions.st_y(r.pickup_location::extensions.geometry),
      'address', r.pickup_address,
      'pincode', p.pincode
    ),
    'destination', jsonb_build_object(
      'longitude', extensions.st_x(r.destination_location::extensions.geometry),
      'latitude', extensions.st_y(r.destination_location::extensions.geometry),
      'address', r.destination_address
    )
  )
  from public.rides r
  left join public.service_area_pincodes p on p.id = r.pincode_id
  where r.id = p_ride_id
    and r.customer_id = p_customer_id
    and r.status in ('completed', 'cancelled', 'no_driver_found');
$$;

revoke all on function public.get_customer_ride_rebook_details(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.get_customer_ride_rebook_details(uuid, uuid)
  to service_role;
