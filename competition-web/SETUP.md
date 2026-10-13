# Local setup and deployment notes

## Current readiness

This checkout is an in-progress local build. It is not ready for real participant information, uploads, or a live competition. Several production paths listed later in this file are not implemented yet. Do not create or invite real participants until the security suite and full end-to-end requirements in PROGRESS.md are complete.

## Run the local stack

1. Install Node.js 22 or newer, Docker Desktop or Colima, and the Supabase CLI. On this Mac, Docker uses the colima context.
2. From competition-web/, copy .env.example to .env.local. Fill in the local Supabase keys after starting the local stack. .env.local is ignored by Git. Keep every service key server-only.
3. Start Docker and run supabase start. The local Supabase project uses supabase/config.toml; the API is on port 54341 and Studio is on 54343.
4. Apply migrations with supabase db reset. This destroys and recreates only the local competition database. It does not touch the OSTTracker Supabase project.
5. Create a random database password and run scripts/bootstrap-local-db-role.sh. Configure the resulting least-privilege SUPABASE_DB_URL; do not connect the web server as postgres.
6. Build the isolated worker with `npm run media:build`; verify the transcode and silent-file rejection with `npm run media:test`. After the local Supabase stack is up and `.env.local` is configured, run `npm run storage:test` to verify a disposable participant's signed TUS upload, private read, and cleanup. On macOS/Colima, set `MEDIA_WORKER_TEMP_DIR` in `.env.local` to a directory within this repository so Docker can mount it.
7. Install site dependencies with npm ci, then run npm run dev. Open http://localhost:3000 and use /demo; the demo uses browser session state and fake content.
8. Run `npm run typecheck`, `npm run lint`, `npm test`, `npm run test:e2e`, `npm run security:audit`, and `npm run build`. `npm run workflow:test` runs a disposable local round through lock, batches, ratings, scoring and reveals; it deletes only its own test accounts and data.

## Deploy only the demo

The demo can run as a separate Vercel deployment without a Supabase project or Supabase environment variables. It uses bundled fictional data, synthesized browser audio, and session-only state. The `/demo` route stays on that deployment when `NEXT_PUBLIC_DEMO_ORIGIN` is unset; if that variable is set, it redirects visitors to the configured demo origin.

1. Create a Vercel project from this repository and set its Root Directory to `competition-web`.
2. Leave all environment variables unset for the demo-only deployment, including `NEXT_PUBLIC_DEMO_ORIGIN`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_DB_URL`.
3. Use Vercel's default build command (`npm run build`) and deploy. Open `/demo` on the deployment and confirm the persistent demo notice appears and the demo can be reset.
4. Keep the demo on its own hostname when a real competition site is deployed. Do not add a production Supabase key to this Vercel project. Confirm browser network tools show no calls to Supabase while using `/demo`.

This documents and locally validates the standalone build path; it does not claim that a Vercel deployment has been created from this account.

## Before a real deployment

1. Create a separate Supabase project for this competition. Never point it at OSTTracker's personal snapshot project.
2. Use Supabase Pro for a real competition, review its current plan limits, and set a budget/spend cap and billing alerts in the Supabase dashboard before uploading media. The exact limits and controls can change; verify them in the dashboard at setup time.
3. Choose the permanent HTTPS domain first. Configure that domain in NEXT_PUBLIC_SITE_URL, NEXT_PUBLIC_SITE_ORIGINS, WEBAUTHN_RP_ID, and WEBAUTHN_ALLOWED_ORIGINS. Never register a passkey on a preview deployment or temporary hostname.
4. Add a private storage bucket with the configured name and apply all migrations. Verify direct access is denied for anon and participants, and signed URLs expire quickly.
5. The current submission-processing route expects a long-running Node server with Docker access and a host directory Docker can mount. It downloads the source from private Storage, launches the isolated worker with no network, and uploads the result itself. This route is not deployable on Vercel serverless functions. A production scale-to-zero job launcher and worker/Storage credentials boundary still need implementation and testing before real uploads; the Vercel-only demo does not include this pipeline.
6. Configure production secrets through the deployment provider. Do not expose the Supabase service key, database login, WebAuthn challenge secret, or host identifier through NEXT_PUBLIC_ variables.
7. Apply the host access migration, then run `npm run host:bootstrap` once from a trusted operator shell with `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `HOST_BOOTSTRAP_DB_URL`, and the permanent `NEXT_PUBLIC_SITE_URL` set. The command creates a non-mail host identity, writes the single host ID and a 10-minute hashed bootstrap token through the privileged database connection, and prints a one-time setup link. It does not grant host status through the website or user metadata. Do not put the bootstrap DB URL or service key into Vercel; unset them after the command.
8. Open the link on the permanent HTTPS domain and register the primary passkey. Then open `/host/security`, sign in again with the new passkey, add a backup passkey, and generate ten recovery codes. Store the codes offline; they are shown only once. Test recovery in a separate local/test project before inviting friends.
9. Create the short trial round through the host UI after trial cleanup is tested. Confirm each transition, invitation, submission, rating, reveal and deletion step with test accounts first.
10. Keep originals until 30 days after archive by default, then run and verify the retention job. Never put active competition media into a public bucket.

## Break-glass host access

For break-glass recovery if all passkeys and recovery codes are lost, use the Supabase dashboard and direct database access to verify `private.platform_config`, then delete that host's rows from `private.passkey_credentials` and `auth.sessions`. Run `npm run host:rotate-bootstrap` once from a trusted operator shell with `HOST_BOOTSTRAP_DB_URL` and `NEXT_PUBLIC_SITE_URL` set, then open the printed setup link and register a new passkey. The script preserves the host ID, rotates any outstanding setup token, and records the action. Never change host status through editable user metadata or a participant-facing API.

## Real iPhone checks

After a production-ready build exists, test on Safari at 320–375 CSS px and in landscape, rotate while a clip is playing, use Dynamic Type and 200% zoom, finish a batch after temporarily going offline, verify save confirmation only appears after server acknowledgment, inspect Media Session lock-screen controls, and verify all dialogs and bottom navigation clear the safe-area insets. The current WebKit runs simulate small viewports and throttled requests; they do not replace a real-device check.
