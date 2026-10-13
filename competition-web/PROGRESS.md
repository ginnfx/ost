# Build progress

Build brief status: **in progress**. Checked boxes mean code exists and the stated local verification passed; a box is not checked merely because files were scaffolded.

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
- [x] Five reveal groups and published aggregate statistics; the host now publishes one anonymous soundtrack per passkey-confirmed action, from last place upward.
- [x] Host console for review, simulated flags, batches, progress, reopen, scoring, participant preview, passkey-gated publication, audit and credentials/recovery.
- [x] Triggerable failures and time controls; reset; skippable tour; end screen.
- [x] Isolation test (demo never imports real API), sessionStorage only, noindex, banner, generic OG.
- [x] Phase checks: typecheck, lint, 3 unit tests, 5 WebKit E2E tests including axe, viewport/throttling, participant and host journeys; production build and zero npm audit findings.
- [x] Phase checkpoint committed (see git history).

## Phase 3 — Schema and security foundation
- [x] Competition schema/migrations in separate Supabase project config.
- [x] Default-deny forced RLS, server-only host config table, append-only audit, immutable scoring snapshots, and private authorization functions. There are no SQL views yet.
- [x] Nonced CSP/security headers, dynamic no-store responses, explicit participant DTO shapes, generic errors, origin validation helper.
- [x] Security foundation checks for direct grants, metadata spoofing, GraphQL, private storage, host function execution, and immutable records.
- [x] Start local Supabase and apply/reset migrations; tested using the local stack.
- [x] Phase checks: migration/security SQL, Vitest, typecheck, lint, production build; WebKit suite running after per-entry reveal adjustment.
- [x] Phase checkpoint committed after the WebKit run.

## Phase 4 — Authentication
- [ ] Invite-only participant auth, one-use expiring invite tokens in URL fragment.
- [ ] Host passkeys/recovery codes/session and credential management.
- [ ] Session-safe cookies, CSRF, rate limits, generic not-found, Instagram browser prompt.
- [ ] Mac ASWebAuthenticationSession plan and Keychain token boundary.
- [ ] Phase checks and commit.

## Phase 5 — Submission and media pipeline
- [ ] Submission limits, AniList lookup, duplicate/reuse host-only checks.
- [ ] Resumable uploads, content sniffing, ffprobe checks, private original retention.
- [ ] Isolated Docker worker, FFmpeg sandbox/resource caps/protocol whitelist, normalized AAC.
- [ ] Preview/confirm/replace, duration mismatch flags, deletion.
- [ ] Local worker tests and phase commit.

## Phase 6 — Listening
- [ ] Server-created anonymous IDs/labels, secure seeded shuffle, balanced batches.
- [ ] Signed short-lived audio URLs and direct storage playback.
- [ ] Integer rating radio control, autosave/queued offline writes, truthful save states.
- [ ] Batch finalization/locking/reopen audit, own-entry automatic ten.
- [ ] Media Session, phase tests and commit.

## Phase 7 — Scoring
- [ ] Single server scoring function with integer arithmetic.
- [ ] Incomplete-rater exclusion, ties, withdrawals, deterministic draw, reveal boundary rules.
- [ ] Shared JSON fixtures; Python scorer parity plan for Mac integration.
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
