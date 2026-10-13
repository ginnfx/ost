# Decisions

Record of implementation choices where the brief leaves room for judgment. Each row gives the choice, reason, code location, and a safe way to change it.

| Choice | Why | Where | How to change |
|---|---|---|---|
| Build the website in `competition-web/` on `feature/ost-competition-platform`; preserve the existing OSTTracker files and data. | Isolates the new platform and allows rollback. Mac integration is explicitly deferred to its own branch. | Repository branch and directory. | Cherry-pick the desired commits; create a separate integration branch from the resulting base for Swift changes. |
| Use Next.js App Router, TypeScript, Supabase Postgres/Auth/Storage, and a thin server-only data layer. No user-facing client calls may contain secret keys. | Matches the requested stack and keeps the policy boundary server side. | `competition-web/app`, `lib`, `.env.example` (to be added). | Replace adapters behind the domain interface without changing views. |
| Use the exact OSTTracker dark palette and add a neutral light palette because the Swift project currently defines dark colors only. | Web brief requires system light/dark; inventing light equivalents is preferable to silently forcing dark mode. | `tokens.json`, generated CSS. | Change source tokens and run `npm run tokens`; the `source` and `notes` fields record provenance. |
| Use Lucide React icons, ISC license, sparingly; use only system fonts on web. | Lucide's simple line icons resemble SF Symbols without copying Apple's symbol files. The brief forbids hosting SF assets/fonts. | `package.json`, `app/`. | Replace icon components; preserve accessible names and include the new license in `LICENSES`. |
| Treat Supabase Passkeys as an optional experimental provider feature and design a standards-based fallback boundary before wiring auth. | Supabase currently labels its passkey integration experimental; avoid making the platform unrecoverable if that API changes. | `lib/auth/` (planned), `SETUP.md`. | Enable Supabase's passkey API only after testing it against the permanent RP ID; fallback is invite-only email OTP plus an application WebAuthn verifier. |
| Never include real anime audio in demo mode. Use a short Web Audio synthesized motif in-browser as original placeholder sound. | No unverifiable CC0 source is bundled, and no anime OST can be treated as demo-safe. | Demo audio module (planned). | Replace only with an original recording or a source whose license is listed and verified in `LICENSES`. |
| Keep private pages uncached/noindex and send the same not-found response for forbidden and missing resources. | Avoid leaking competition existence in HTML, metadata, cache, or error behavior. | Security headers and server domain services (planned). | Any exception must retain privacy guarantees and be added to the security tests. |
| Use the host as a participant; one server-controlled host identity only. | Matches the brief and avoids participant-controlled role claims. | Private config row and authorization functions (planned). | Change only by direct database administration, never through app or public metadata. |

## Design provenance

`tokens.json` extracts accent and dark palette values, chamfer size, card aspect, grid gap, and radius/spacing examples from `OSTTracker/Sources/Theme/Theme.swift`, `OSTTracker/Sources/Theme/Shapes.swift`, `OSTTracker/Sources/Views/RosterView.swift`, `DetailView.swift`, and `NowPlayingBar.swift`. The Swift app bundles Spotify Mix but the web app uses the required system font stack. The app has no light semantic palette; light colors are web-specific accessible equivalents.

## Passkeys status

No passkey implementation is active yet. Supabase's current passkey support is documented as experimental, so the safe fallback is the planned app-owned WebAuthn ceremony with invite-only account creation and hashed, single-use recovery codes. Do not register production passkeys until the permanent HTTPS domain and RP ID are final.
