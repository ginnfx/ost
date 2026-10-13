# Local setup and deployment notes

## Current readiness

This checkout is an in-progress local build. It is not ready for real participant information, uploads, or a live competition. The media worker and Cloud Run deployment configuration are implemented and exercised locally, but have not been deployed to a Google Cloud account. Other verification and production-readiness gaps remain in PROGRESS.md.

## Run the local stack

1. Install Node.js 22 or newer, Docker Desktop or Colima, and the Supabase CLI. On this Mac, Docker uses the colima context.
2. From competition-web/, copy .env.example to .env.local. Fill in the local Supabase keys after starting the local stack. .env.local is ignored by Git. Keep every service key server-only.
3. Start Docker and run supabase start. The local Supabase project uses supabase/config.toml; the API is on port 54341 and Studio is on 54343.
4. Apply migrations with supabase db reset. This destroys and recreates only the local competition database. It does not touch the OSTTracker Supabase project.
5. Create a random database password and run scripts/bootstrap-local-db-role.sh. Configure the resulting least-privilege SUPABASE_DB_URL; do not connect the web server as postgres.
6. Build the isolated worker with `npm run media:build`; verify the transcode and silent-file rejection with `npm run media:test`. After the local Supabase stack is up and `.env.local` is configured, run `npm run storage:test` to verify a disposable participant's signed TUS upload, private read, and cleanup. To process uploads while using the local site, open another terminal in `competition-web/` and run `set -a; source .env.local; set +a; npm run media:serve`. Set real random values for the local worker token and callback secret first. On macOS/Colima, set `MEDIA_WORKER_TEMP_DIR` in `.env.local` to a directory within this repository so Docker can mount it.
7. Install site dependencies with npm ci, then run npm run dev. Open http://localhost:3000 and use /demo; the demo uses browser session state and fake content.
8. Run `npm run typecheck`, `npm run lint`, `npm test`, `npm run test:e2e`, `npm run security:audit`, and `npm run build`. `npm run workflow:test` runs a disposable local round through lock, batches, ratings, scoring, reveals, and the trial create/open/delete lifecycle; it deletes only its own test accounts and data.
9. With the local database, Storage, and production build running, verify SQL permissions with `docker exec -i supabase_db_ost-competition-private psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < tests/security.sql`, then run `npm run storage:test` and `npm run security:integration`. The API integration test starts a local production server on port 3210, creates three disposable Auth users and private fixture media, exercises participant/host authorization and page payloads, then deletes its fixtures. The Storage test checks the allowed pending-key TUS upload, rejects a mismatched key, and verifies direct reads are denied.
10. To test completed TUS uploads through the HTTP worker orchestration locally, run `npm run build` followed by `npm run media:orchestration:test`. The integration test starts the same `worker/server.py` handler used by the Cloud Run image, uses the local retry dispatcher, uploads synthetic clips by TUS, waits for the signed callback, downloads the private AAC result and decodes it with FFmpeg. It also sends a silent video and verifies the host submission-review API reports its permanent failure. It creates and removes only disposable local fixtures.

## Deploy only the demo

The demo can run as a separate Vercel deployment without a Supabase project or Supabase environment variables. It uses bundled fictional data, synthesized browser audio, and session-only state. The `/demo` route stays on that deployment when `NEXT_PUBLIC_DEMO_ORIGIN` is unset; if that variable is set, it redirects visitors to the configured demo origin.

1. Create a Vercel project from this repository and set its Root Directory to `competition-web`.
2. Leave all environment variables unset for the demo-only deployment, including `NEXT_PUBLIC_DEMO_ORIGIN`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_DB_URL`.
3. Use Vercel's default build command (`npm run build`) and deploy. Open `/demo` on the deployment and confirm the persistent demo notice appears and the demo can be reset.
4. Keep the demo on its own hostname when a real competition site is deployed. Do not add a production Supabase key to this Vercel project. Confirm browser network tools show no calls to Supabase while using `/demo`.

This path was tested locally on 2026-10-13: production build with `.env.local` moved aside, then a WebKit visit to `/demo` with all Supabase variables and `NEXT_PUBLIC_DEMO_ORIGIN` unset. The banner appeared without page errors. Vercel itself has not been deployed from this account. In Vercel, set `competition-web` as the project Root Directory as described in [Vercel's monorepo guide](https://vercel.com/docs/monorepos).

## Before a real deployment

1. Create a separate Supabase project for this competition. Never point it at OSTTracker's personal snapshot project.
2. Use Supabase Pro for a real competition, review its current plan limits, and set a budget/spend cap and billing alerts in the Supabase dashboard before uploading media. The exact limits and controls can change; verify them in the dashboard at setup time.
3. Choose the permanent HTTPS domain first. Configure that domain in NEXT_PUBLIC_SITE_URL, NEXT_PUBLIC_SITE_ORIGINS, WEBAUTHN_RP_ID, and WEBAUTHN_ALLOWED_ORIGINS. Never register a passkey on a preview deployment or temporary hostname.
4. Add a private storage bucket with the configured name and apply all migrations. Verify direct access is denied for anon and participants, and signed URLs expire quickly.
5. Deploy the isolated processor to Google Cloud Run using the steps below. The web app only enqueues work; it does not run FFmpeg or hold media-worker Storage credentials. The media pipeline is implemented, but GCP deployment and a live Cloud Tasks retry exercise still need to be completed in your account before accepting real uploads.
6. Configure production secrets through the deployment provider. Do not expose the Supabase service key, database login, WebAuthn challenge secret, or host identifier through NEXT_PUBLIC_ variables.
7. Apply the host access migration, then run `npm run host:bootstrap` once from a trusted operator shell with `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `HOST_BOOTSTRAP_DB_URL`, and the permanent `NEXT_PUBLIC_SITE_URL` set. The command creates a non-mail host identity, writes the single host ID and a 10-minute hashed bootstrap token through the privileged database connection, and prints a one-time setup link. It does not grant host status through the website or user metadata. Do not put the bootstrap DB URL or service key into Vercel; unset them after the command.
8. Open the link on the permanent HTTPS domain and register the primary passkey. Then open `/host/security`, sign in again with the new passkey, add a backup passkey, and generate ten recovery codes. Store the codes offline; they are shown only once. Test recovery in a separate local/test project before inviting friends.
9. Create the short trial round through the host UI after trial cleanup is tested. Confirm each transition, invitation, submission, rating, reveal and deletion step with test accounts first.
10. Keep originals until 30 days after archive by default, then run and verify the retention job. Never put active competition media into a public bucket.

## Production media worker: Google Cloud Run and Cloud Tasks

The participant completes a resumable TUS upload, then the authenticated website endpoint verifies the upload row and round settings and enqueues one Cloud Task. Cloud Tasks sends the task to a private Cloud Run service with a Google OIDC identity. The worker downloads the source using a short-lived signed Storage URL, runs the existing FFmpeg/ffprobe processor, uploads the AAC using a signed upload URL, and calls the website result endpoint. That callback requires a timestamped HMAC. Permanent media validation failures are recorded immediately; transient storage or callback failures receive Cloud Tasks retries. After retries are exhausted, the host submission-review screen lists the failure and attempt count. Replaying a task is safe: its task name is versioned per dispatch, its output key is stable for the upload, and the signed upload permits overwrite.

The worker never receives the Supabase service-role key or database password. FFmpeg/ffprobe use `-protocol_whitelist file`; the Python task handler only accepts signed URL origins configured for the Supabase project and the callback origin configured for the website. Redirects are rejected. Cloud Run IAM rejects unauthenticated callers, and Cloud Tasks attaches an OIDC token from the dedicated invoker service account. The callback HMAC authenticates the reverse result call. Network egress firewall rules are not provisioned by this repo; the handler enforces the expected URL origins at the application layer.

1. Enable `run.googleapis.com`, `cloudtasks.googleapis.com`, `artifactregistry.googleapis.com`, `cloudbuild.googleapis.com`, and `secretmanager.googleapis.com` in the Google Cloud project. Create a Docker Artifact Registry repository in the chosen region (the default name in `.env.example` is `ost-media`). Install `gcloud` and select a billing-enabled project.
2. Create three service accounts: a Cloud Tasks enqueuer/client, a Cloud Tasks OIDC invoker, and the Cloud Run runtime identity. Example commands:

   ```sh
   gcloud iam service-accounts create ost-task-enqueuer --project "$GCP_PROJECT_ID"
   gcloud iam service-accounts create ost-task-invoker --project "$GCP_PROJECT_ID"
   gcloud iam service-accounts create ost-worker-runtime --project "$GCP_PROJECT_ID"
   gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
     --member "serviceAccount:ost-task-enqueuer@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
     --role roles/cloudtasks.enqueuer
   ```

   Set the three service-account environment variables to those email addresses. The deployment script grants the enqueuer `roles/iam.serviceAccountUser` on the invoker and grants the invoker `roles/run.invoker` on the worker. The runtime identity gets access only to the callback HMAC secret. Cloud Tasks' service agent must be able to mint the invoker's OIDC token; verify its service-agent role if dispatch reports an IAM error. Google documents this identity flow in [Cloud Tasks HTTP target authentication](https://cloud.google.com/tasks/docs/creating-http-target-tasks#auth).
3. Generate a random 32-byte callback secret with `openssl rand -hex 32`. Create Secret Manager secret `ost-media-worker-callback` and add that value as its first version. Store the same value in the website deployment's server-only `MEDIA_WORKER_CALLBACK_SECRET` variable. Do not put it in source control, a `NEXT_PUBLIC_` variable, or a task body.
4. Create the Cloud Tasks queue in the same region. A starting policy for this private group is 5 attempts, 10-second minimum backoff, 120-second maximum backoff, 1-hour retry duration, maximum 3 concurrent tasks, and 2 dispatches per second:

   ```sh
   gcloud tasks queues create media-processing \
     --project "$GCP_PROJECT_ID" --location "$GCP_REGION" \
     --max-attempts 5 --min-backoff 10s --max-backoff 120s \
     --max-doublings 3 --max-retry-duration 3600s \
     --max-concurrent-dispatches 3 --max-dispatches-per-second 2
   ```

   Confirm with `gcloud tasks queues describe media-processing --project "$GCP_PROJECT_ID" --location "$GCP_REGION"`. Cloud Tasks supports authenticated HTTP targets and retry policies; see [queue retries and limits](https://cloud.google.com/tasks/docs/configuring-queues).
5. Before first deploy, set these shell variables: `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_ARTIFACT_REPOSITORY`, `GCP_TASKS_CLIENT_EMAIL`, `GCP_TASKS_INVOKER_SERVICE_ACCOUNT`, and `MEDIA_WORKER_RUNTIME_SERVICE_ACCOUNT`. Set `MEDIA_ALLOWED_STORAGE_ORIGIN` to the exact origin of the competition Supabase project, such as `https://project-ref.supabase.co`; set `MEDIA_CALLBACK_ORIGIN` to the permanent website origin. Create the secret and grant the runtime service account access as in step 3. Then run `worker/deploy-cloud-run.sh` from `competition-web/`. It builds the worker image, deploys with minimum instances 0, maximum 3, concurrency 1, 2 CPUs, 2 GiB RAM and a 30-minute request timeout, disables unauthenticated invocation, and binds the Cloud Tasks invoker identity. Cloud Run scales instances to zero when idle when min instances is zero; cold starts are expected. See [Cloud Run minimum instances](https://cloud.google.com/run/docs/configuring/min-instances) and [request timeouts](https://cloud.google.com/run/docs/configuring/request-timeout).
6. Create a key for the enqueuer service account in a secure, ignored location (`gcloud iam service-accounts keys create /secure/path/ost-task-enqueuer.json --iam-account "$GCP_TASKS_CLIENT_EMAIL"`). Copy its `private_key` value into the Vercel server-only `GCP_TASKS_CLIENT_PRIVATE_KEY` variable, then securely remove that local JSON file. Set the website's production variables: `MEDIA_TASK_MODE=cloud-tasks`, `MEDIA_WORKER_URL` to the deployed service URL, `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_TASKS_QUEUE=media-processing`, `GCP_TASKS_CLIENT_EMAIL`, `GCP_TASKS_INVOKER_SERVICE_ACCOUNT`, `GCP_TASKS_CLIENT_PRIVATE_KEY`, `MEDIA_WORKER_CALLBACK_SECRET`, `MEDIA_ALLOWED_STORAGE_ORIGIN`, and `MEDIA_CALLBACK_ORIGIN`. The website enqueuer key must be stored as a server-only Vercel environment variable. This Vercel integration uses a Google service-account key to mint Cloud Tasks API OAuth tokens; restrict that account to task creation and `actAs` on the invoker, keep the key only in production, and rotate/revoke it if it is exposed. The worker itself does not receive this key.
7. Verify the service URL with `curl -i "$MEDIA_WORKER_URL/healthz"`; unauthenticated requests to `/process` must be rejected by Cloud Run IAM. Then, using local test accounts in a separate Supabase project, run the TUS-to-AAC orchestration test above and inspect the worker's Cloud Run logs and the Cloud Tasks queue. Before real participants, upload one valid clip and one silent clip in a disposable production test round; confirm the valid audio previews, the silent clip produces a host-visible failure, and retry counts appear in the host console. Delete the test round afterward.

Cloud Run container requests support timeouts up to 60 minutes; Cloud Tasks HTTP tasks allow at most 30 minutes. This setup uses a 30-minute task deadline and sets FFmpeg's per-job timeout to 15 minutes so a request should finish or return for retry before Cloud Tasks closes it. Confirm duration and cold-start behavior against the chosen region before production. The code has not been deployed to your GCP account from this workspace.

## OSTTracker macOS competition client

The Mac competition client is on the separate `feature/ost-competition-mac-integration` branch. After reviewing/merging that branch, regenerate the Xcode project with `xcodegen generate --spec OSTTracker/project.yml` and build the `OSTTracker` macOS scheme. In OSTTracker Settings, enter the permanent HTTPS competition website address, choose **Sign in with passkey**, and finish in the system browser. The Mac keeps the resulting refresh token in Keychain; it does not receive the Supabase service key. Host actions are authorized by the server.

Use the Competition section to load released batches, play anonymous audio, and rate it from 1 to 10. Successfully played clips and the latest anonymous batch are cached on this Mac for offline use. Signed Storage URLs and auth tokens are never included in that cache. If another device changed a rating, the Mac reports a conflict and reloads the current server value. **Refresh competitions** retries local ratings marked not saved; a stale write remains visible until you choose **Use server** or **Save mine**. After the competition is complete, **Archive on this Mac** saves audio locally and imports the revealed titles into OSTTracker history. For the host, the confirmation step also saves the private originals and then removes them from cloud Storage. Old OSTTracker rounds can be imported as a separate private archive; their historical ratings are not included in competition scoring. OSTTracker's existing personal snapshot sync remains a separate account and data path.

## Break-glass host access

For break-glass recovery if all passkeys and recovery codes are lost, use the Supabase dashboard and direct database access to verify `private.platform_config`, then delete that host's rows from `private.passkey_credentials` and `auth.sessions`. Run `npm run host:rotate-bootstrap` once from a trusted operator shell with `HOST_BOOTSTRAP_DB_URL` and `NEXT_PUBLIC_SITE_URL` set, then open the printed setup link and register a new passkey. The script preserves the host ID, rotates any outstanding setup token, and records the action. Never change host status through editable user metadata or a participant-facing API.

## Real iPhone checks

After a production-ready build exists, test on Safari at 320–375 CSS px and in landscape, rotate while a clip is playing, use Dynamic Type and 200% zoom, finish a batch after temporarily going offline, verify save confirmation only appears after server acknowledgment, inspect Media Session lock-screen controls, and verify all dialogs and bottom navigation clear the safe-area insets. The current WebKit runs simulate small viewports and throttled requests; they do not replace a real-device check.
