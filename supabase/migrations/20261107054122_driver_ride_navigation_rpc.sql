CREATE OR REPLACE FUNCTION public.get_driver_ride_navigation(p_ride_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  SELECT jsonb_build_object(
    'ride', jsonb_build_object(
      'id', r.id,
      'status', r.status,
      'pickup_address', r.pickup_address,
      'destination_address', r.destination_address,
      'pickup', jsonb_build_object(
        'longitude', extensions.st_x(r.pickup_location::extensions.geometry),
        'latitude', extensions.st_y(r.pickup_location::extensions.geometry)
      ),
      'destination', jsonb_build_object(
        'longitude', extensions.st_x(r.destination_location::extensions.geometry),
        'latitude', extensions.st_y(r.destination_location::extensions.geometry)
      )
    )
  )
  INTO v_result
  FROM public.rides r
  WHERE r.id = p_ride_id
    AND r.driver_id = auth.uid()
    AND r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress');

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Active ride not found or not assigned to this driver'
      USING ERRCODE = 'P0002';
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_driver_ride_navigation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_driver_ride_navigation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_driver_ride_navigation(uuid) TO authenticated;
