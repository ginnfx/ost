import Link from "next/link";

export default function NotFound() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
      </header>
      <section className="welcome">
        <p className="eyebrow">NOT FOUND</p>
        <h1>This page is unavailable.</h1>
        <p className="intro">
          The link may be expired, or this item may no longer be available.
        </p>
        <div className="action-row">
          <Link className="button primary" href="/">
            Back to the start
          </Link>
        </div>
      </section>
    </main>
  );
}
