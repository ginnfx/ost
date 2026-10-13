import Link from "next/link";
import { ArrowRight } from "@phosphor-icons/react/ssr";

export default function HomePage() {
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
      </header>
      <section className="welcome" aria-labelledby="welcome-title">
        <h1 id="welcome-title">
          Listen first.
          <br />
          Rank together.
        </h1>
        <p className="intro">
          A private competition for invited friends. Submit soundtracks, rate
          anonymous clips, and reveal the final ranking together.
        </p>
        <div className="action-row">
          <Link className="button primary" href="/demo">
            Explore the demo <ArrowRight size={17} />
          </Link>
          <Link className="text-link" href="/how-it-works">
            How it works
          </Link>
          <Link className="text-link" href="/login">
            Sign in
          </Link>
        </div>
      </section>
    </main>
  );
}
