# Driver onboarding and KYC workflow

## Driver steps

1. Sign in with Google in the Driver app.
2. Submit vehicle category, registration, make/model and operating pincode.
3. Upload a driving licence, vehicle RC and current vehicle insurance as PDF, JPG or PNG files (up to 5 MB each).
4. Each upload goes to the private `driver-documents` Storage bucket in a folder scoped to the signed-in driver's user ID. The app registers metadata through `driver-ride-actions`; the mobile client cannot write verification metadata directly.
5. Driver can see whether each required document is pending, approved or rejected. Rejected items can be replaced with another upload.
6. Admin reviews each document. Driver remains pending until all three required documents are approved and unexpired, then the Admin can approve the overall driver application.
7. Service-pincode membership is reviewed separately. The driver can go online only after driver approval, pincode approval and any required subscription is active.

## Admin steps

- Open Operations → Driver applications.
- Expand a driver to review vehicle details, service-pincode requests and uploaded documents.
- Open a document through the short-lived signed preview URL.
- Approve or reject each document, with an optional review note.
- Approve the driver application only after licence, RC and insurance have approved, unexpired records. The server checks this condition independently of the UI.
- Review the driver's requested service pincode separately.

## Storage and authorization

- Bucket: `driver-documents`; private, 5 MB file limit, MIME allow-list: `application/pdf`, `image/jpeg`, `image/png`.
- Driver uploads and owner reads are limited by the first object-path folder matching `auth.uid()`; upload also requires a driver profile in pending or under-review state.
- The driver Edge Function checks ownership/path format, file type/size metadata and existence in Storage before inserting the `driver_documents` row.
- Only the Admin Edge Function uses the service role to create time-limited signed preview URLs and write review outcomes/audit logs.
- Do not change the bucket to public or expose service-role credentials.

## Pilot validation

Before accepting real drivers, test with a non-admin driver account and an Admin account: upload valid and invalid files, attempt cross-account paths, approve/reject documents, confirm an expired document cannot be approved, and confirm overall driver approval fails when any required document is missing, rejected or expired.
