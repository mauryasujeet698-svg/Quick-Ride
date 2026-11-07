CREATE POLICY driver_profiles_customer_read_active_ride
ON public.driver_profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.rides r
    WHERE r.driver_id = driver_profiles.user_id
      AND r.customer_id = (SELECT auth.uid())
      AND r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
  )
);

CREATE POLICY profiles_customer_read_active_ride_driver
ON public.profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.rides r
    WHERE r.driver_id = profiles.id
      AND r.customer_id = (SELECT auth.uid())
      AND r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
  )
);

REVOKE SELECT (phone_e164, account_status, created_at, updated_at)
ON public.profiles FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_customer_ride_tracking(p_ride_id uuid)
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
      'estimated_fare', r.estimated_fare,
      'final_fare', r.final_fare,
      'currency', r.currency,
      'requested_at', r.requested_at,
      'accepted_at', r.accepted_at,
      'started_at', r.started_at,
      'completed_at', r.completed_at,
      'pickup', jsonb_build_object(
        'longitude', extensions.st_x(r.pickup_location::extensions.geometry),
        'latitude', extensions.st_y(r.pickup_location::extensions.geometry)
      ),
      'destination', jsonb_build_object(
        'longitude', extensions.st_x(r.destination_location::extensions.geometry),
        'latitude', extensions.st_y(r.destination_location::extensions.geometry)
      )
    ),
    'driver', CASE
      WHEN r.driver_id IS NULL OR dp.user_id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'name', COALESCE(NULLIF(p.full_name, ''), 'Quick-Ride driver'),
        'avatar_url', p.avatar_url,
        'vehicle_make', dp.vehicle_make,
        'vehicle_model', dp.vehicle_model,
        'vehicle_color', dp.vehicle_color,
        'vehicle_registration', dp.vehicle_registration,
        'vehicle_category', vc.name,
        'location', CASE
          WHEN r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
            AND dl.recorded_at >= now() - interval '2 minutes'
          THEN jsonb_build_object(
            'longitude', extensions.st_x(dl.location::extensions.geometry),
            'latitude', extensions.st_y(dl.location::extensions.geometry),
            'recorded_at', dl.recorded_at
          )
          ELSE NULL
        END
      )
    END
  )
  INTO v_result
  FROM public.rides r
  LEFT JOIN public.driver_profiles dp ON dp.user_id = r.driver_id
  LEFT JOIN public.profiles p ON p.id = r.driver_id
  LEFT JOIN public.vehicle_categories vc ON vc.id = dp.vehicle_category_id
  LEFT JOIN public.driver_locations dl ON dl.driver_id = r.driver_id
  WHERE r.id = p_ride_id
    AND r.customer_id = auth.uid();

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Ride not found or not accessible'
      USING ERRCODE = 'P0002';
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_customer_ride_tracking(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_ride_tracking(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_customer_ride_tracking(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_customer_ride_tracking(uuid) TO authenticated;
