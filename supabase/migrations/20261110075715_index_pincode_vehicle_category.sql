-- Cover the second foreign key on the public pincode vehicle catalogue.
create index if not exists service_area_pincode_vehicles_category_idx
  on public.service_area_pincode_vehicles(vehicle_category_id);
