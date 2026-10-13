import Link from "next/link";
import type { Metadata } from "next";
import { PasskeyLogin } from "@/components/passkey-login";

export const metadata: Metadata = {
  title: "Sign in · OST Competition",
  robots: { index: false, follow: false },
  openGraph: {
    title: "OST Competition",
    description: "Private soundtrack competition.",
  },
};
export default function LoginPage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
      </header>
      <section className="welcome invite-page">
        <p className="eyebrow">INVITED PARTICIPANTS</p>
        <h1>Sign in</h1>
        <p className="intro">
          This competition is private. Sign in with the passkey you created from
          your invite.
        </p>
        <PasskeyLogin />
        <p className="muted-small">
          Need access? Ask the host for a new invite link.
        </p>
      </section>
    </main>
  );
}
