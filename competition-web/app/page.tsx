import Link from 'next/link';
import { ArrowRight, Headphones, ListMusic, ShieldCheck } from 'lucide-react';

export default function HomePage() {
  return <main className="page-shell">
    <header className="topbar"><Link className="wordmark" href="/">OST TRACKER <span>COMPETITION</span></Link><span className="private-label"><ShieldCheck size={15}/> Private</span></header>
    <section className="welcome" aria-labelledby="welcome-title">
      <p className="eyebrow">ANIME SOUNDTRACK RANKING</p>
      <h1 id="welcome-title">Listen first.<br/>Rank together.</h1>
      <p className="intro">A private competition for invited friends. Submit soundtracks, rate anonymous clips, and reveal the final ranking together.</p>
      <div className="action-row"><Link className="button primary" href="/demo">Explore the demo <ArrowRight size={17}/></Link><Link className="text-link" href="/how-it-works">How it works</Link></div>
    </section>
    <section className="feature-list" aria-label="Competition steps">
      <article><ListMusic size={19}/><div><h2>Submit</h2><p>Choose five anime soundtracks for the round.</p></div></article>
      <article><Headphones size={19}/><div><h2>Listen</h2><p>Hear audio-only clips in daily batches.</p></div></article>
      <article><span className="rank-mark">#</span><div><h2>Reveal</h2><p>See the standings together, from last to first.</p></div></article>
    </section>
    <footer className="footer"><span>Invite only</span><span>Nothing is public</span></footer>
  </main>;
}
