# Local setup and deployment notes

## Current readiness

This checkout is an in-progress local build. It is not ready for real participant information, uploads, or a live competition. Several production paths listed later in this file are not implemented yet. Do not create or invite real participants until the security suite and full end-to-end requirements in PROGRESS.md are complete.

## Run the local stack

1. Install Node.js 22 or newer, Docker Desktop or Colima, and the Supabase CLI. On this Mac, Docker uses the colima context.
2. From competition-web/, copy .env.example to .env.local. Fill in the local Supabase keys after starting the local stack. .env.local is ignored by Git. Keep every service key server-only.
3. Start Docker and run supabase start. The local Supabase project uses supabase/config.toml; the API is on port 54341 and Studio is on 54343.
4. Apply migrations with supabase db reset. This destroys and recreates only the local competition database. It does not touch the OSTTracker Supabase project.
5. Create a random database password and run scripts/bootstrap-local-db-role.sh. Configure the resulting least-privilege SUPABASE_DB_URL; do not connect the web server as postgres.
6. Build the isolated worker with npm run media:build; verify the transcode and silent-file rejection with npm run media:test. On macOS/Colima, set MEDIA_WORKER_TEMP_DIR in .env.local to a directory within this repository so Docker can mount it.
7. Install site dependencies with npm ci, then run npm run dev. Open http://localhost:3000 and use /demo; the demo uses browser session state and fake content.
8. Run npm run typecheck, npm run lint, npm test, npm run test:e2e, npm run security:audit, and npm run build.

## Before a real deployment

1. Create a separate Supabase project for this competition. Never point it at OSTTracker's personal snapshot project.
2. Use Supabase Pro for a real competition, review its current plan limits, and set a budget/spend cap and billing alerts in the Supabase dashboard before uploading media. The exact limits and controls can change; verify them in the dashboard at setup time.
3. Choose the permanent HTTPS domain first. Configure that domain in NEXT_PUBLIC_SITE_URL, NEXT_PUBLIC_SITE_ORIGINS, WEBAUTHN_RP_ID, and WEBAUTHN_ALLOWED_ORIGINS. Never register a passkey on a preview deployment or temporary hostname.
4. Add a private storage bucket with the configured name and apply all migrations. Verify direct access is denied for anon and participants, and signed URLs expire quickly.
5. Deploy the Next.js server and isolated media worker. The worker container must have no network, a read-only root, memory/CPU/PID/time limits, and no credentials. The server must fetch inputs and upload outputs outside the worker container.
6. Configure production secrets through the deployment provider. Do not expose the Supabase service key, database login, WebAuthn challenge secret, or host identifier through NEXT_PUBLIC_ variables.
7. The initial host bootstrap, production invite management, recovery-code workflow, complete media orchestration, lifecycle operations, and trial-round creation UI are not finished in this checkout. Do not register production credentials or issue invitations until those paths and the security suite are implemented and tested.
8. Once those paths exist, register a primary and backup host passkey on the permanent domain, generate ten high-entropy single-use recovery codes, and store them offline. Test the lost-device and recovery drill before inviting friends.
9. Create the short trial round through the host UI after trial cleanup is tested. Confirm each transition, invitation, submission, rating, reveal and deletion step with test accounts first.
10. Keep originals until 30 days after archive by default, then run and verify the retention job. Never put active competition media into a public bucket.

## Break-glass host access

No production host account should be created until the bootstrap and recovery flows are complete. If host access later needs recovery, use the Supabase dashboard to verify the single host config row and the host's Auth user ID, follow the documented operator-only credential replacement procedure, revoke all old sessions, and record the action. Do not grant host status through editable user metadata or a participant-facing API.

## Real iPhone checks

After a production-ready build exists, test on Safari at 320–375 CSS px and in landscape, rotate while a clip is playing, use Dynamic Type and 200% zoom, finish a batch after temporarily going offline, verify save confirmation only appears after server acknowledgment, inspect Media Session lock-screen controls, and verify all dialogs and bottom navigation clear the safe-area insets. The current WebKit runs simulate small viewports and throttled requests; they do not replace a real-device check.
