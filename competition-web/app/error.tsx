'use client';

export default function ErrorPage({reset}:{error:Error & {digest?:string};reset:()=>void}){
  return <main className="page-shell"><section className="welcome"><p className="eyebrow">TEMPORARY ERROR</p><h1>That did not work.</h1><p className="intro">Your competition data has not been changed. Try again or return to the start.</p><div className="action-row"><button className="button primary" onClick={reset}>Try again</button><a className="text-link" href="/">Back to the start</a></div></section></main>;
}
