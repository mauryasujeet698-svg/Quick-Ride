DROP POLICY IF EXISTS driver_documents_owner_upload ON storage.objects;

CREATE POLICY driver_documents_owner_upload
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'driver-documents'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  AND EXISTS (
    SELECT 1
    FROM public.driver_profiles dp
    WHERE dp.user_id = (SELECT auth.uid())
      AND dp.verification_status IN ('pending', 'under_review')
  )
);
