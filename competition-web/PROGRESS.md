# Build progress

Build brief status: **in progress**. Checked boxes mean code exists and the stated local verification passed; a box is not checked merely because files were scaffolded.

## User-directed resume sequence (2026-10-13)
- [x] Scoring clarification: remove tie-boundary movement; fixed nonempty groups, with the last group absorbing remainders. Fixture ranking and score expectations were unchanged; group boundaries were updated to match the revised rule.
- [x] Step 1: reset local Supabase with auth migration and verify schema/security baseline. `supabase db reset` applied both competition and auth migrations locally; `supabase migration list --local` agreed. `tests/security.sql`, typecheck, lint, and 19 unit tests passed before proceeding. Supabase reports that optional local services are stopped and `inbucket` config is deprecated; neither blocked the reset.
- [x] Step 2: prove `/demo` production build/runtime without Supabase variables; add standalone Vercel deployment instructions. Built with `.env.local` moved aside and no Supabase or `NEXT_PUBLIC_DEMO_ORIGIN` variables, then loaded `/demo` in WebKit at 375 px and verified its isolation banner and zero page errors. Vercel itself was not deployed because no account access was provided.
- [x] Step 3: host bootstrap, recovery codes, credential and session management. Implemented the operator-only host bootstrap script and expiring one-use browser registration; ten hashed single-use recovery codes and recovery passkey replacement; host credential list/add/remove with backup-key guard; and database-backed global session revocation. The CLI created a local-only host and the bootstrap options API returned WebAuthn options for its one-time token. Local migration reset, SQL security checks, source-boundary tests, typecheck, lint, 21 unit tests, production build, and 8 demo E2E tests pass. A real authenticator recovery drill remains untested and is required before production.
- [x] Step 4: submissions, resumable uploads, Storage-connected worker and media validation. The submission form includes AniList lookup, per-round size/duration checks, TUS progress/resume while the tab remains open, processed-audio preview and confirmation/replacement. Host checks show same-round duplicates and prior-round reuse privately, while duration mismatches require audited review. A pending-row Storage RLS policy authorizes only each participant's assigned key. Local verification: fresh DB reset, SQL security assertions, disposable authenticated TUS upload/private read/delete, Docker transcode + silent-input rejection, typecheck, lint, 21 unit tests, and production build. Production scale-to-zero processing orchestration remains unimplemented; current processing requires a long-running Node host with Docker access.
- [x] Step 5: listening batches, rating sync, immutable scoring snapshot, and real reveal publication. Host lock/start/release/reopen/close/score/group-publish/one-at-a-time reveal actions are server authorized and audited. Participants get anonymous, per-person shuffled batches, automatic own 10s, optimistic rating versions, a sessionStorage offline queue with truthful save state, 4-second rating/result refresh, finalize locks and published entries only. Local disposable two-person/four-entry round exercised the whole database state machine, checks own tens, complete nonempty batches, frozen scores, reveal counts, and final completion. Unit tests, SQL security assertions, lint, typecheck and production build pass. Passkey confirmation is a recent verified user-presence window (5 minutes); physical authenticator and live Safari checks remain outstanding.
- [x] Step 6: trial round creation and cleanup. Local trial uses the standard competition flow with two entries per participant, one batch/group, 24/72-hour deadlines, clear trial labels, invite cap, and exclusion from future OST reuse history. Host cleanup removes the trial media, unused invite identities, and dependent competition rows after confirmation while retaining a deletion audit record. Fresh `supabase db reset`, SQL security assertions, and `npm run workflow:test` passed through create, open, single-active-trial rejection, and delete.
- [x] Step 7: full API, Storage and page payload security suite. SQL checks enforce role grants/RLS, empty search paths for definer functions, private/no-view rules, append-only audit, snapshot immutability, and nonpublic storage. Disposable Auth-backed HTTP probes tested participant/host access, metadata host spoofing, own-submission scoping, anonymous batch output, other-rating isolation, unreleased audio, unpublished results, CSRF, host review/security/trial APIs, PostgREST private-schema denial, direct original/audio reads, and no-store page payloads. Storage integration verified exact pending-key TUS upload succeeds while unmatched-key upload and direct reads fail. All tests passed locally.
- [x] Step 8: Mac integration on `feature/ost-competition-mac-integration`, branched from the completed platform commit. Added passkey browser login with a short-lived one-use native code, Keychain-backed refreshable Supabase session, authenticated competition list/batch/rating access, per-rating version conflicts, completed media archive/import, and host-only import of old rankings. Added Python scorer parity against the shared JSON fixture. Mac/iOS targets compile; native-session, stale-write, legacy-import, archive, Storage and page-payload probes pass. Hardware passkey handoff and archive playback on a real Mac remain unverified.

## Phase 1 — Design system
- [x] Inspect OSTTracker SwiftUI theme, shapes, roster/detail/player views, project setup, asset catalog, and existing backend terminology.
- [x] Separate branch and `competition-web/` project boundary.
- [x] Extract OSTTracker design tokens with source notes; generate CSS variables.
- [x] App shell, navigation entry, sibling visual style, light/dark system colors, mobile safe areas.
- [x] Shared roster card, compact player, fullscreen player/lyrics, and ten-choice rating primitives.
- [x] Focus, hover, pressed, and disabled button states in the shell and shared primitives.
- [ ] Loading states and complete interaction states will be audited as real forms ship in later phases.
- [x] Validate 320 px and touch targets in Playwright WebKit.
- [x] WebKit viewport checks at 320 px, iPhone portrait, and landscape with throttled requests.
- [x] Phase checks: static production build, TypeScript, ESLint, and npm audit (zero findings).
- [x] Phase checkpoint committed (see git history).

## Phase 2 — Data interface and isolated demo
- [x] Shared domain/data interface and sessionStorage-backed mock adapter.
- [x] Demo data: 10 fictional participants, 45 other entries plus 5 visitor submissions, original synthesized browser audio.
- [x] Participant submission, simulated upload progress/processing/confirm/replace.
- [x] Waiting/listening, ratings, offline queue, finalize/lock, own-entry automatic 10 after opening.
- [x] Five reveal groups and published aggregate statistics; the host confirms one reveal group with a simulated passkey, then advances anonymous soundtracks one at a time.
- [x] Host console for review, simulated flags, batches, progress, reopen, scoring, participant preview, passkey-gated publication, audit and credentials/recovery.
- [x] Triggerable failures and time controls; reset; skippable tour; end screen.
- [x] Isolation test (demo never imports real API), sessionStorage only, noindex, banner, generic OG.
- [x] Phase checks: typecheck, lint, unit tests, 8 WebKit E2E tests including axe, Safari prompt, viewport/throttling, participant and host journeys; production build and zero npm audit findings.
- [x] Phase checkpoint committed (see git history).

## Phase 3 — Schema and security foundation
- [x] Competition schema/migrations in separate Supabase project config.
- [x] Default-deny forced RLS, server-only host config table, append-only audit, immutable scoring snapshots, and private authorization functions. There are no SQL views yet.
- [x] Nonced CSP/security headers, dynamic no-store responses, explicit participant DTO shapes, generic errors, origin validation helper.
- [x] Security foundation checks for direct grants, metadata spoofing, GraphQL, private storage, host function execution, and immutable records.
- [x] Start local Supabase and apply/reset migrations; tested using the local stack.
- [x] Phase checks before authentication changes: migration/security SQL, Vitest, typecheck, lint, production build; WebKit suite passed again after group-reveal changes.
- [x] Phase checkpoint committed before authentication changes (see git history).

## Phase 4 — Authentication
- [x] Server-side WebAuthn participant registration, one-use expiring invite tokens in URL fragment, nickname-only enrollment; local Auth placeholder identifier exercised.
- [ ] Host invite UI (the invite API exists; the host-facing invite management UI is still pending).
- [x] Initial host passkey bootstrap via trusted operator CLI and single-use short-lived token.
- [x] Discoverable WebAuthn login and session sign-out endpoint.
- [x] Host recovery codes, credential management, session management and host bootstrap.
- [x] Secure session cookies, same-origin mutation checks, rate limits, generic not-found responses.
- [x] Instagram in-app-browser prompt, tested with a simulated Instagram user agent.
- [ ] Full CSRF/security exercise.
- [ ] Mac ASWebAuthenticationSession plan and Keychain token boundary.
- [x] Phase checks passed and phase changes committed; hardware authenticator enrollment/recovery still needs a real-device check.

## Phase 5 — Submission and media pipeline
- [x] Submission limits, AniList lookup, same-round duplicate/prior-round reuse host-only checks.
- [x] Resumable uploads, content verification through ffprobe, duration checks, private original retention.
- [x] Container worker uses network none, read-only root, least privilege, resource caps, file-only FFmpeg, AAC 256 kbps / 48 kHz / stereo.
- [x] Local worker integration downloads/uploads private Storage through the server; isolated FFmpeg honors edit lists, checks duration delta and flags over 100 ms.
- [x] Preview/confirm/replace, duration mismatch review flags and replacement deletion.
- [x] Local Docker transcode/no-audio rejection and participant-scoped TUS Storage integration passed. A production scale-to-zero job launcher is still absent and is explicitly documented.

## Phase 6 — Listening
- [x] Server-created anonymous labels, cryptographic shuffle seed, submitter-balanced batches and per-participant display order.
- [x] Short-lived signed audio URLs and direct storage playback.
- [x] Integer 1–10 controls, autosave, sessionStorage offline queue, version conflicts and truthful save states.
- [x] Batch finalization locks/reopen audit; own entry receives automatic 10.
- [x] Native audio controls and Media Session title, local workflow tests pass.

## Phase 7 — Scoring
- [x] Integer-only TypeScript scoring engine and JSON fixture tests (not yet authoritative DB publication).
- [x] Incomplete-rater exclusion, ties, withdrawals, seeded deterministic draw, and fixed nonempty reveal group partitioning in the TypeScript scorer.
- [x] JSON fixture covers scorer rules; Python parity deferred to separate Mac integration branch.
- [x] Immutable scored snapshot and mutation-blocking trigger.
- [x] Host-triggered scoring snapshot records input seed, excluded raters and ranking; local complete-round exercise passes.

## Phase 8 — Reveals
- [x] Host sees reveal-group sizes/progress and publishes with a recent passkey verification window plus hold-to-confirm.
- [x] Publish one reveal entry per host action; participant responses contain only published rows and aggregate scores.
- [ ] Dedicated view-as-participant preview and post-reveal statistics.
- [x] No unpublished results in participant DTOs/API; realtime is disabled and responses are private/no-store.
- [ ] Phase checks and commit.

## Phase 9 — Trial round
- [x] Two entries/person, one batch/group, short deadlines; clearly marked Trial.
- [x] Exact same domain paths; excluded from prior-round reuse history; confirmed full cleanup.
- [x] Phase checks: clean migration reset, SQL security checks, trial lifecycle through the local workflow test.
- [x] Phase checkpoint committed (see git history).

## Phase 10 — Mac integration (separate branch)
- [x] Implemented only on `feature/ost-competition-mac-integration`.
- [x] Authenticated native API client; host powers remain server-authorized; no service key in Mac.
- [x] Per-rating versions and visible stale-write rejection; HTTP 409 behavior exercised locally.
- [x] Archive completed audio locally; host can save originals, import results into OSTTracker history, then confirm cloud-original cleanup.
- [x] Import old OSTTracker rankings into a private legacy archive; repeated imports are idempotent.
- [x] Existing personal snapshot sync code was not changed; the competition account section is separate.

## Phase 11 — End-to-end and security exercises
- [x] Local Supabase, Storage, media worker checks, and Next production build were run together.
- [ ] Simulated 10-account complete round, host flow, demo, recovery drill.
- [x] Unauthorized reads/actions, storage access, participant host-grant attempt (local SQL, HTTP/API, Storage, and rendered-payload probes passed).
- [x] Playwright WebKit viewport/throttle and demo/participant/host demo journeys pass; axe passes on implemented public pages in dark and light modes.
- [ ] Axe coverage for every authenticated route, physical authenticator/recovery verification, and production performance measurements.
- [ ] Full Python suite is not fully green: 145 passed; one pre-existing assertion in `tests/test_data_layer.py::test_statistics_edge_cases` expects `"—"`, while the unchanged `spread_label(None, None)` implementation returns an empty string. The Mac scoring/history-focused subset passes (30 tests); this unrelated OSTTracker behavior was left unchanged.

## Phase 12 — Documentation and report
- [ ] Beginner SETUP.md with Supabase project/domain/RP ID/deploy/cost/passkeys/trial steps and verification.
- [ ] DECISIONS.md complete and current.
- [ ] LICENSES includes every icon/image/audio/font.
- [ ] Privacy/how-it-works page, robots exclusion, real-iPhone checklist.
- [ ] Lint/types/unit/fixtures/security/axe/e2e/build/performance results recorded accurately.
- [ ] Final report includes open risks and manual steps.


## Current work checkpoint (2026-10-13 19:50 CEST)

The Mac integration branch includes the website native-session bridge, SwiftUI Mac competition account, history imports, local media archive flow, and Python scoring parity tests. The deployment-only demo was built and browser-checked without local env files or Supabase/demo-origin variables. The full local API/Storage/page security probe passes. A full ten-account competition, physical passkey/recovery exercise, production worker orchestration, real-Mac archive playback, complete authenticated-route axe sweep, and performance measurements remain unverified; keep real participant data off the current local setup.
