# Build progress

Build brief status: **in progress**. Checked boxes mean code exists and the stated local verification passed; a box is not checked merely because files were scaffolded.

## User-directed resume sequence (2026-10-13)
- [x] Scoring clarification: remove tie-boundary movement; fixed nonempty groups, with the last group absorbing remainders. Fixture ranking and score expectations were unchanged; group boundaries were updated to match the revised rule.
- [x] Step 1: reset local Supabase with auth migration and verify schema/security baseline. `supabase db reset` applied both competition and auth migrations locally; `supabase migration list --local` agreed. `tests/security.sql`, typecheck, lint, and 19 unit tests passed before proceeding. Supabase reports that optional local services are stopped and `inbucket` config is deprecated; neither blocked the reset.
- [x] Step 2: prove `/demo` production build/runtime without Supabase variables; add standalone Vercel deployment instructions. A clean copy without `.env*` built successfully with all Supabase variables and `NEXT_PUBLIC_DEMO_ORIGIN` unset; production server returned the demo notice in WebKit with zero page errors. Removed an unnecessary CSP upgrade directive that had broken local HTTP production-mode asset loading. Vercel itself was not deployed because no account access was provided.
- [x] Step 3: host bootstrap, recovery codes, credential and session management. Implemented the operator-only host bootstrap script and expiring one-use browser registration; ten hashed single-use recovery codes and recovery passkey replacement; host credential list/add/remove with backup-key guard; and database-backed global session revocation. The CLI created a local-only host and the bootstrap options API returned WebAuthn options for its one-time token. Local migration reset, SQL security checks, source-boundary tests, typecheck, lint, 21 unit tests, production build, and 8 demo E2E tests pass. A real authenticator recovery drill remains untested and is required before production.
- [ ] Step 4: submissions, resumable uploads, Storage-connected worker and full media validation.
- [ ] Step 5: batches, rating sync, immutable scoring snapshot, real reveal publication.
- [ ] Step 6: trial round creation and cleanup.
- [ ] Step 7: full API, Storage and page payload security suite.
- [ ] Step 8: Mac integration, last, on its own branch.

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
- [ ] Submission limits, AniList lookup, duplicate/reuse host-only checks.
- [ ] Resumable uploads, content sniffing, ffprobe checks, private original retention.
- [x] Container worker uses network none, read-only root, least privilege, resource caps, file-only FFmpeg, AAC 256 kbps / 48 kHz / stereo.
- [ ] Hosted worker orchestration, private storage download/upload, lifecycle integration.
- [ ] Preview/confirm/replace, duration mismatch flags, deletion.
- [x] Local Docker transcode and no-audio rejection smoke test passed; phase checks/commit pending.

## Phase 6 — Listening
- [ ] Server-created anonymous IDs/labels, secure seeded shuffle, balanced batches.
- [ ] Signed short-lived audio URLs and direct storage playback.
- [ ] Integer rating radio control, autosave/queued offline writes, truthful save states.
- [ ] Batch finalization/locking/reopen audit, own-entry automatic ten.
- [ ] Media Session, phase tests and commit.

## Phase 7 — Scoring
- [x] Integer-only TypeScript scoring engine and JSON fixture tests (not yet authoritative DB publication).
- [x] Incomplete-rater exclusion, ties, withdrawals, seeded deterministic draw, and fixed nonempty reveal group partitioning in the TypeScript scorer.
- [x] JSON fixture covers scorer rules; Python parity deferred to separate Mac integration branch.
- [ ] Immutable scored snapshot and mutation-blocking trigger.
- [ ] Phase checks and commit.

## Phase 8 — Reveals
- [ ] Host preview and publish with recent verified user-presence credential + hold action.
- [ ] Publish only one reveal entry at a time; participants see only aggregate data.
- [ ] Statistics and no unpublished-data leakage across HTML/API/cache/realtime.
- [ ] Phase checks and commit.

## Phase 9 — Trial round
- [ ] Two entries/person, one batch/group, short deadlines; clearly marked Trial.
- [ ] Exact same domain paths; excluded history/statistics; confirmed full cleanup.
- [ ] Phase checks and commit.

## Phase 10 — Mac integration (separate branch)
- [ ] Implement only on a distinct git branch.
- [ ] Authenticated API client; host power stays server-authorized; no secret key in Mac.
- [ ] Per-record versions and visible stale-write rejection.
- [ ] Archive completed round/media locally and import into OSTTracker history.
- [ ] Import old OSTTracker competitions.
- [ ] Verify existing personal snapshot sync remains untouched.

## Phase 11 — End-to-end and security exercises
- [ ] Full local Supabase + worker + Next dev + production stack.
- [ ] Simulated 10-account complete round, host flow, demo, recovery drill.
- [ ] Unauthorized reads/actions, storage access, participant host-grant attempt.
- [ ] Playwright WebKit viewport/throttle, axe on every route, production error checks.

## Phase 12 — Documentation and report
- [ ] Beginner SETUP.md with Supabase project/domain/RP ID/deploy/cost/passkeys/trial steps and verification.
- [ ] DECISIONS.md complete and current.
- [ ] LICENSES includes every icon/image/audio/font.
- [ ] Privacy/how-it-works page, robots exclusion, real-iPhone checklist.
- [ ] Lint/types/unit/fixtures/security/axe/e2e/build/performance results recorded accurately.
- [ ] Final report includes open risks and manual steps.


## Current work checkpoint (2026-10-13 17:08 CEST)

The current branch contains Auth endpoints, scoring foundations, a Docker media worker, and the requested design/reveal/invite adjustments. The resume scoring change is committed as `78d5b5a`. Local Supabase reset and auth migration validation passed. Host controls, real submissions, listening/reveal, and trial cleanup are not yet complete; demo passkey prompts remain simulated. Do not treat the current app as ready for real competition data.
