REVOKE SELECT ON TABLE public.profiles FROM authenticated;
GRANT SELECT (id, full_name, avatar_url)
ON TABLE public.profiles TO authenticated;
