import Link from "next/link";

export const metadata = {
  title: "OST Competition demo",
  robots: { index: false, follow: false },
};

export default function HowItWorksPage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
        <Link className="text-link" href="/demo">
          Try demo
        </Link>
      </header>
      <article className="welcome information-page">
        <p className="eyebrow">HOUSE RULES FOR FRIENDS</p>
        <h1>How it works</h1>
        <p className="intro">
          This is a private soundtrack game for invited people. It is not a
          public ranking site or a legal contract.
        </p>
        <h2>Competition rules</h2>
        <p>
          Each person submits five video clips. The service extracts audio and
          removes identifying metadata. During listening, entries use anonymous
          labels and arrive in shuffled batches. Rate every clip from 1 to 10.
          Your own clip receives 10 automatically. A batch locks when you
          finalize it; the host can reopen it and that action is recorded.
        </p>
        <p>
          At the deadline, people who did not finish every batch are left out of
          scoring. The average includes automatic self-ratings. Ties are
          resolved by more 10s, then the higher median, then the lower spread of
          ratings, then a seeded draw. The full order is set before reveal
          groups are made. Groups use fixed sizes; ties can cross a group
          boundary, and the last group absorbs any remainder. The host reveals
          results one soundtrack at a time from last place upward.
        </p>
        <h2>Joining the round</h2>
        <p>
          Participants need a nickname and a passkey, not an email address.
          Supabase Auth requires an email-shaped account identifier, so the
          server creates a random address at the reserved .invalid domain. It
          cannot receive mail and is not shared with participants.
        </p>
        <h2>What is stored</h2>
        <p>
          The planned service stores your nickname, account identifier and
          passkey public key, submitted videos and processed audio, ratings,
          progress, and security audit events. Passkey private keys stay with
          your device or passkey provider. The Mac OSTTracker personal library
          remains in its separate personal sync system.
        </p>
        <p>
          Competition data is intended to live in a separate private Supabase
          project. Audio is kept through the round and archive; originals are
          scheduled for deletion 30 days after archive by default. A host can
          change the configured retention period. Before a real round starts,
          the host must publish the actual service location, retention settings,
          and deletion contact.
        </p>
        <h2>Ask for deletion</h2>
        <p>
          Contact the host directly to request deletion or correct your account
          data. Some records may need to remain until a round is archived so
          that its published result can be explained. The host should confirm
          what was deleted and what remains.
        </p>
        <h2>Demo</h2>
        <p>
          The demo uses invented people and titles, and original synthesized
          audio. It stays in this browser session and does not save to the
          competition service.
        </p>
        <p className="muted-small">
          The real service is not ready for participant data until setup,
          security tests, domain, authentication, and retention jobs are
          configured and verified.
        </p>
      </article>
    </main>
  );
}
