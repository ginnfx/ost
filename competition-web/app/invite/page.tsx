import type { Metadata } from "next";
import { InviteEnrollment } from "@/components/invite-enrollment";

export const metadata: Metadata = {
  title: "Accept invite · OST Competition",
  robots: { index: false, follow: false },
  openGraph: {
    title: "OST Competition",
    description: "Private soundtrack competition.",
  },
};
export default function InvitePage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <a className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </a>
      </header>
      <section className="welcome invite-page">
        <p className="eyebrow">PRIVATE INVITE</p>
        <h1>Join the round</h1>
        <p className="intro">
          Choose a nickname and create a passkey for this account.
        </p>
        <InviteEnrollment />
      </section>
    </main>
  );
}
