'use client';

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, AudioLines, BadgeCheck, BookOpen, Check, ChevronRight, CircleHelp, Clock3, Headphones, ListMusic, LockKeyhole, Play, Radio, RotateCcw, ShieldCheck, SkipForward, SlidersHorizontal, Sparkles, Upload, Users, Wifi, WifiOff, X } from 'lucide-react';
import type { DemoState, Entry, RoundPhase } from '@/lib/domain';
import { demoData } from '@/lib/demo/mock-api';
import { SoundtrackCard, RatingScale } from './ui';

const selfId='person-1';
const delay=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
const nextMysteryLabel=(entries:Entry[])=>{
  const used=new Set(entries.map(entry=>Number(entry.label.match(/#(\d+)/)?.[1])).filter(Number.isFinite));
  return `Mystery OST #${Array.from({length:50},(_,i)=>i+1).find(n=>!used.has(n))??50}`;
};

export function DemoApp() {
  const [state,setState]=useState<DemoState|null>(null);
  const [busy,setBusy]=useState(false);
  const [uploadProgress,setUploadProgress]=useState(0);
  const [videoFile,setVideoFile]=useState<File|null>(null);
  const [title,setTitle]=useState('');
  const [franchise,setFranchise]=useState('');
  const [playing,setPlaying]=useState(false);
  const [showTour,setShowTour]=useState(false);
  const [hold,setHold]=useState(false);
  const holdTimer=useRef<ReturnType<typeof setTimeout>|null>(null);
  const playerRef=useRef<AudioContext|null>(null);
  const pendingRef=useRef<DemoState|null>(null);

  useEffect(()=>{ void demoData.read().then(setState); },[]);
  useEffect(()=>{
    const onOffline=()=>{ if(state) setState({...state,online:false,toast:'You are offline. New ratings will wait to save.'}); };
    const onOnline=()=>{ const pending=pendingRef.current; if(pending) { pendingRef.current=null; void demoData.write(pending); setState({...pending,online:true,toast:'Connection restored. Ratings saved.'}); } else if(state) setState({...state,online:true,toast:'Connection restored.'}); };
    window.addEventListener('offline',onOffline); window.addEventListener('online',onOnline);
    return ()=>{window.removeEventListener('offline',onOffline);window.removeEventListener('online',onOnline);};
  },[state]);
  useEffect(()=>{
    if(!state || state.phase!=='listening') return;
    const timer=setInterval(()=>setState(current=>{
      if(!current || !current.online) return current;
      const participants=current.participants.map((p,i)=>p.id===selfId?p:{...p,rated:Math.min(50,p.rated+(((Date.now()/8000|0)+i)%3===0?1:0))});
      return {...current,participants};
    }),8000);
    return ()=>clearInterval(timer);
  },[state?.phase]);

  const save=useCallback((next:DemoState, offlineQueue=false)=>{
    setState(next);
    if(offlineQueue && !next.online) { pendingRef.current=next; return; }
    void demoData.write(next);
  },[]);
  const patch=(fn:(current:DemoState)=>DemoState,offlineQueue=false)=>{ if(!state)return; save(fn(state),offlineQueue); };
  const toast=(message:string)=>patch(s=>({...s,toast:message}));
  const ownEntries=useMemo(()=>state?.entries.filter(e=>e.submitterId===selfId)??[],[state?.entries]);
  const listeningEntries=useMemo(()=>state?.entries.filter(e=>e.batch===state.batch)??[],[state?.entries,state?.batch]);

  const startTone=()=>{
    const AudioContextCtor=window.AudioContext;
    const context=playerRef.current??new AudioContextCtor(); playerRef.current=context;
    if(context.state==='suspended') void context.resume();
    const now=context.currentTime;
    [440,523.25,659.25,587.33].forEach((freq,i)=>{
      const oscillator=context.createOscillator(),gain=context.createGain();
      oscillator.type='sine';oscillator.frequency.value=freq;
      gain.gain.setValueAtTime(.0001,now+i*.22);gain.gain.exponentialRampToValueAtTime(.075,now+i*.22+.025);gain.gain.exponentialRampToValueAtTime(.0001,now+i*.22+.2);
      oscillator.connect(gain).connect(context.destination);oscillator.start(now+i*.22);oscillator.stop(now+i*.22+.21);
    });
    setPlaying(true);window.setTimeout(()=>setPlaying(false),1100);
  };

  const reset=async()=>{pendingRef.current=null;setState(await demoData.reset());setShowTour(false);setBusy(false);};
  const skipToListening=()=>patch(s=>{
    const own=s.entries.filter(e=>e.submitterId===selfId);
    const generated=[...own];
    while(generated.length<5) generated.push({id:`entry-skip-${generated.length}`,listeningId:`listen-${crypto.randomUUID()}`,label:nextMysteryLabel([...s.entries,...generated]),title:`First Light: Movement ${generated.length+1}`,franchise:'Glass Harbor',submitterId:selfId,duration:128,batch:generated.length,confirmed:true,own:true,score:10,ratings:9});
    return {...s,entries:[...s.entries.filter(e=>e.submitterId!==selfId),...generated],participants:s.participants.map(p=>p.id===selfId?{...p,submitted:5}:p),phase:'listening',batch:0,toast:'Listening is open. Rate each clip from 1 to 10.'};
  });
  const finishBatch=()=>{
    if(!state)return;
    const current=state.batch;
    const missing=listeningEntries.filter(e=>!e.own&&!state.ratingByEntry[e.id]);
    if(missing.length){toast(`Rate ${missing.length} more clips before finalizing this batch.`);return;}
    const finalized=[...new Set([...state.finalized,current])];
    const nextBatch=current+1;
    const phase:RoundPhase=nextBatch>=5?'reveals':'listening';
    const next={...state,finalized,batch:Math.min(nextBatch,4),phase,toast:phase==='reveals'?'All batches are complete. The host is scoring the round.':`Batch ${current+1} finalized. Batch ${nextBatch+1} is ready.`,participants:state.participants.map(p=>p.id===selfId?{...p,finalized:finalized.length}:p)};
    save(next);
  };
  const playEntry=(entry:Entry)=>{if(entry.own&&!entry.opened)patch(s=>({...s,entries:s.entries.map(e=>e.id===entry.id?{...e,opened:true}:e),toast:'Your entry receives an automatic 10.'}));startTone();};
  const rate=(entry:Entry,score:number)=>{
    if(!state || state.finalized.includes(state.batch)){toast('This batch is finalized and locked.');return;}
    if(entry.own){toast('Your entry receives an automatic 10.');return;}
    const next={...state,ratingByEntry:{...state.ratingByEntry,[entry.id]:score},toast:state.online?'Saving rating…':'Not saved yet. It will retry when you are online.'};
    if(state.online){setState(next);window.setTimeout(()=>{
      setState(current=>{if(!current)return current;const saved={...current,toast:'Rating saved.'};void demoData.write(saved);return saved;});
    },220);}
    else save(next,true);
  };
  const openNextBatch=()=>patch(s=>({...s,batch:Math.min(s.batch+1,4),phase:'listening',toast:`Batch ${Math.min(s.batch+2,5)} is open.`}));
  const fastForward=()=>patch(s=>({...s,participants:s.participants.map(p=>({...p,rated:50,finalized:5})),toast:'Friends finished the round.'}));
  const revealNext=()=>patch(s=>({...s,passkeyPrompt:true,toast:'Confirm the next reveal group with the simulated passkey.'}));
  const record=async()=>{setBusy(true);setUploadProgress(0);for(let i=10;i<=100;i+=30){await delay(100);setUploadProgress(i);}if(!state)return;const own=state.entries.filter(e=>e.own);if(state.failNextUpload){patch(s=>({...s,failNextUpload:false,toast:'Upload rejected: no audio stream was found. Try another video.'}));setBusy(false);setVideoFile(null);return;}const slot=own.length;const item:Entry={id:`entry-demo-${Date.now()}`,listeningId:`listen-${crypto.randomUUID()}`,label:nextMysteryLabel(state.entries),title:title.trim(),franchise:franchise.trim(),submitterId:selfId,duration:state.mismatchNext?350:128,batch:slot,confirmed:false,own:true,score:10,ratings:9,...(state.mismatchNext?{flagged:'Duration mismatch. The host will review this clip.'}:{})};patch(s=>({...s,mismatchNext:false,entries:[...s.entries,item],participants:s.participants.map(p=>p.id===selfId?{...p,submitted:p.submitted+1}:p),toast:item.flagged??'Upload processed. Preview the anonymous audio, then confirm it.'}));setTitle('');setFranchise('');setVideoFile(null);setUploadProgress(0);setBusy(false);};
  const confirmOwn=(entryId:string)=>patch(s=>({...s,entries:s.entries.map(e=>e.id===entryId?{...e,confirmed:true}:e),toast:'Submission confirmed.'}));
  const replaceOwn=(entryId:string)=>patch(s=>({...s,entries:s.entries.filter(e=>e.id!==entryId),participants:s.participants.map(p=>p.id===selfId?{...p,submitted:Math.max(0,p.submitted-1)}:p),toast:'The replaced demo clip was deleted.'}));
  const holdStart=()=>{setHold(true);holdTimer.current=setTimeout(()=>{setHold(false);patch(s=>({...s,passkeyPrompt:true,toast:'Hold complete. Continue with the simulated passkey prompt.'}));},1600);};
  const holdEnd=()=>{if(holdTimer.current)clearTimeout(holdTimer.current);setHold(false);};

  if(!state) return <main className="demo-loading"><span className="skeleton demo-skel"/><span>Loading demo…</span></main>;
  const myProgress=state.finalized.length;

  return <main className="demo-shell">
    <div className="demo-banner"><Sparkles size={15}/><strong>Demo.</strong> Nothing here is saved or real.<button onClick={()=>setShowTour(true)} aria-label="Open demo tour"><CircleHelp size={17}/></button></div>
    <header className="demo-header"><Link href="/" className="back-home" aria-label="Back to home"><ArrowLeft size={18}/></Link><div className="demo-title"><span className="eyebrow">{state.phase==='complete'?'ROUND COMPLETE':`TRIAL · ${state.phase.toUpperCase()}`}</span><h1>Glass Harbor Trial</h1></div><div className="demo-top-actions"><button className="quiet-button" onClick={()=>{if(state.online)patch(s=>({...s,online:false,toast:'You are offline. Ratings are queued.'}));else if(pendingRef.current){save({...pendingRef.current,online:true,toast:'Connection restored. Ratings saved.'});pendingRef.current=null;}else patch(s=>({...s,online:true,toast:'Connection restored.'}));}} aria-label={state.online?'Simulate going offline':'Simulate going online'}>{state.online?<Wifi size={17}/>:<WifiOff size={17}/>}</button><button className="quiet-button" onClick={()=>void reset()} aria-label="Reset demo"><RotateCcw size={17}/></button></div></header>
    <nav className="demo-nav" aria-label="Demo navigation"><button className={state.role==='participant'?'active':''} onClick={()=>patch(s=>({...s,role:'participant',toast:'Participant view.'}))}><Users size={16}/>Participant</button><button className={state.role==='host'?'active':''} onClick={()=>patch(s=>({...s,role:'host',toast:'Host console. Demo actions are simulated.'}))}><ShieldCheck size={16}/>Host</button><span className="nav-spacer"/><button onClick={()=>setShowTour(true)}><BookOpen size={16}/>Tour</button></nav>
    {state.recoveryConsumed&&<div className="recovery-reset" role="status"><p>Host access is paused until a replacement credential is registered.</p><button className="button primary" onClick={()=>patch(s=>({...s,recoveryConsumed:false,credentials:[...s.credentials,'Replacement passkey'],role:'host',toast:'Replacement simulated passkey registered. Host session restored.',audit:[...s.audit,'Replacement passkey registered after recovery']}))}>Register replacement passkey</button></div>}
    {state.toast&&<div role="status" aria-live="polite" className="demo-toast">{state.online?<BadgeCheck size={16}/>:<WifiOff size={16}/>}<span>{state.toast}</span><button onClick={()=>patch(s=>({...s,toast:''}))} aria-label="Dismiss message"><X size={16}/></button></div>}
    {state.role==='participant'?<section className="demo-content" aria-label="Participant area">
      <div className="section-head"><div><p className="eyebrow">{state.phase==='submissions'?'YOUR SUBMISSIONS':state.phase==='waiting'?'READY WHEN YOU ARE':state.phase==='listening'?'LISTENING ROUND':state.phase==='reveals'?'RESULTS':'FINISHED'}</p><h2>{participantHeading(state.phase,state.batch)}</h2></div>{state.phase==='listening'&&<span className="progress-pill">{myProgress}/5 batches</span>}</div>
      {state.phase==='submissions'&&<SubmissionPanel state={state} onChange={patch} entries={ownEntries} title={title} setTitle={setTitle} franchise={franchise} setFranchise={setFranchise} busy={busy} progress={uploadProgress} file={videoFile} setFile={setVideoFile} onAdd={()=>void record()} onConfirm={confirmOwn} onReplace={replaceOwn} onPlay={startTone} playing={playing} onFinish={()=>patch(s=>({...s,phase:'waiting',toast:'Submissions are closed for you. Waiting for listening to start.'}))} />}
      {state.phase==='waiting'&&<WaitingPanel onSkip={skipToListening} />}
    {state.phase==='listening'&&<ListeningPanel state={state} entries={listeningEntries} onRate={rate} onPlay={playEntry} playing={playing} onFinalize={finishBatch} />}
      {(state.phase==='reveals'||state.phase==='complete')&&<ParticipantResults state={state} onPlay={startTone} playing={playing} />}
    </section>:<HostConsole state={state} onChange={patch} onReveal={revealNext} onHoldStart={holdStart} onHoldEnd={holdEnd} hold={hold} />}
    {state.role==='participant'&&<ParticipantTabBar phase={state.phase} onSelect={phase=>patch(s=>({...s,phase,toast:`Demo view: ${phase}.`}))}/>}
    <DemoBottomNav onChange={(phase)=>patch(s=>({...s,phase,toast:`Demo time control: ${phase}.`}))} onFastForward={fastForward} onOpenBatch={openNextBatch} onSkipReveals={()=>patch(s=>({...s,phase:'reveals',revealed:0,toast:'Ready for reveals.'}))} />
    {showTour&&<div className="tour-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)setShowTour(false);}}><section className="tour-dialog" role="dialog" aria-modal="true" aria-labelledby="tour-title"><button className="close-button" onClick={()=>setShowTour(false)} aria-label="Close tour"><X size={18}/></button><p className="eyebrow">QUICK TOUR</p><h2 id="tour-title">A practice round, end to end</h2><p>Submit five soundtrack ideas, listen to mystery-labeled audio, and rate every batch. The host view lets you explore scheduling, review, and reveal controls.</p><p>Use the time controls below to jump between phases. Demo changes live only in this browser tab and reset when the tab session ends.</p><button className="button primary" onClick={()=>{setShowTour(false);patch(s=>({...s,tourDone:true}));}}>Got it</button></section></div>}
    {state.passkeyPrompt&&<div className="tour-backdrop"><section className="tour-dialog" role="dialog" aria-modal="true" aria-labelledby="passkey-title"><p className="eyebrow">SIMULATED SECURITY CHECK</p><h2 id="passkey-title">Confirm with a passkey</h2><p>This is a demo prompt. A real passkey would verify your identity on this device.</p><button className="button primary" onClick={()=>patch(s=>({...s,passkeyPrompt:false,published:true,revealed:Math.min(s.revealed+1,5),phase:s.revealed>=4?'complete':'reveals',toast:'Simulated passkey verified. The next result group is published.',audit:[...s.audit,'Host published a reveal group after simulated passkey verification']}))}>Simulate passkey verification</button><button className="small-button" onClick={()=>patch(s=>({...s,passkeyPrompt:false,toast:'Publish canceled.'}))}>Cancel</button></section></div>}
    {state.phase==='complete'&&<section className="demo-end"><h2>What changes in a real round?</h2><p>Real participants use invite-only accounts. Deadlines are real, ratings are private, and submissions are handled by the competition server.</p><a href={process.env.NEXT_PUBLIC_FEEDBACK_INSTAGRAM||'https://instagram.com/'} target="_blank" rel="noreferrer">Send feedback on Instagram <ChevronRight size={16}/></a></section>}
  </main>;
}

function participantHeading(phase:RoundPhase,batch:number){switch(phase){case'submissions':return 'Submit five entries';case'waiting':return 'Your entries are in';case'listening':return `Batch ${batch+1} of 5`;case'reveals':return 'The ranking is being revealed';case'complete':return 'The round is complete';}}

function SubmissionPanel({state,onChange,entries,title,setTitle,franchise,setFranchise,busy,progress,file,setFile,onAdd,onConfirm,onReplace,onPlay,playing,onFinish}:{state:DemoState;onChange:(fn:(s:DemoState)=>DemoState)=>void;entries:Entry[];title:string;setTitle:(v:string)=>void;franchise:string;setFranchise:(v:string)=>void;busy:boolean;progress:number;file:File|null;setFile:(f:File|null)=>void;onAdd:()=>void;onConfirm:(id:string)=>void;onReplace:(id:string)=>void;onPlay:()=>void;playing:boolean;onFinish:()=>void}){
  const [replace,setReplace]=useState<string|null>(null);
  const confirmed=entries.filter(e=>e.confirmed).length;
  return <><p className="supporting-copy">Add five entries. Uploads and processing below are simulated. Your original video is private in a real round.</p><div className="submission-progress" role="progressbar" aria-label="Confirmed entries" aria-valuemin={0} aria-valuemax={5} aria-valuenow={confirmed}><span style={{width:`${confirmed*20}%`}}/></div><p className="muted-small">{confirmed} of 5 confirmed</p>
    <form className="submission-form" onSubmit={e=>{e.preventDefault();onAdd();}}><label>Anime or franchise<input required maxLength={100} value={franchise} onChange={e=>setFranchise(e.target.value)} placeholder="For example, Glass Harbor"/></label><label>OST title<input required maxLength={100} value={title} onChange={e=>setTitle(e.target.value)} placeholder="Track title"/></label><label className="file-picker">Video clip<input required type="file" accept="video/mp4,video/quicktime,video/webm,video/x-matroska,.mkv" onChange={e=>setFile(e.target.files?.[0]??null)}/><span>{file?.name??'Choose a video file'}</span></label><div className="form-action-row"><button className="button primary" disabled={busy||entries.length>=5||!franchise.trim()||!title.trim()||!file}><Upload size={16}/>{busy?'Processing upload…':'Upload video'}</button><span className="muted-small">MP4, MOV, WebM, MKV · up to 500 MB</span></div>{busy&&<div className="upload-progress" role="progressbar" aria-label="Upload progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progress}><span style={{width:`${progress}%`}}/></div>}</form>
    {entries.length>0&&<div className="submission-list"><h3>Your entries</h3>{entries.map((entry,i)=><article className="submission-row" key={entry.id}><div className="submission-number">{i+1}</div><div className="submission-meta"><strong>{entry.title}</strong><span>{entry.franchise} · {Math.floor(entry.duration/60)}:{String(entry.duration%60).padStart(2,'0')}{entry.flagged&&<em className="flag-text">{entry.flagged}</em>}</span><div className="submission-actions">{entry.confirmed?<span className="state-label"><Check size={14}/>Confirmed</span>:<><button className="small-button" onClick={()=>onPlay()}><Play size={14}/>{playing?'Playing preview':'Preview processed audio'}</button><button className="small-button primary-small" onClick={()=>onConfirm(entry.id)}>Confirm entry</button></>}<button className="small-button" onClick={()=>setReplace(replace===entry.id?null:entry.id)}>Replace</button></div>{replace===entry.id&&<div className="replace-confirm"><span>Replacing deletes this demo clip.</span><button className="small-button danger-small" onClick={()=>{onReplace(entry.id);setReplace(null);}}>Delete and replace</button></div>}</div></article>)}</div>}
    <DemoProblems state={state} onChange={onChange}/>
    {entries.length===5&&entries.every(e=>e.confirmed)&&<button className="button primary wide-button" onClick={onFinish}>Finish submissions</button>}
    {entries.length<5&&<div className="empty-slot"><Clock3 size={17}/><span>{5-entries.length} more {entries.length===4?'entry':'entries'} needed before submission closes.</span></div>}
  </>;
}

function DemoProblems({state,onChange}:{state:DemoState;onChange:(fn:(s:DemoState)=>DemoState)=>void}){
  const change=(key:'failNextUpload'|'mismatchNext')=>onChange(s=>({...s,[key]:!s[key],toast:key==='failNextUpload'?'Next upload will simulate a missing audio track.':'Next upload will have a duration mismatch.'}));
  return <details className="problem-controls"><summary>Try a simulated upload issue</summary><div><button className={state.failNextUpload?'selected':''} onClick={()=>change('failNextUpload')}>Reject next upload: no audio</button><button className={state.mismatchNext?'selected':''} onClick={()=>change('mismatchNext')}>Flag next upload: duration mismatch</button></div></details>;
}

function WaitingPanel({onSkip}:{onSkip:()=>void}){return <div className="waiting-panel"><div className="waiting-symbol"><Headphones size={23}/></div><h3>Everyone is submitting</h3><p>When the host opens listening, your entries will appear with anonymous labels. This demo can jump ahead now.</p><button className="button primary" onClick={onSkip}>Skip to listening</button></div>;}

function ListeningPanel({state,entries,onRate,onPlay,playing,onFinalize}:{state:DemoState;entries:Entry[];onRate:(e:Entry,n:number)=>void;onPlay:(e:Entry)=>void;playing:boolean;onFinalize:()=>void}){
  const complete=entries.every(e=>e.own||state.ratingByEntry[e.id]);
  return <><div className="batch-summary"><span>{entries.length} clips</span><span>{entries.filter(e=>e.own||state.ratingByEntry[e.id]).length} rated</span><span>{state.finalized.includes(state.batch)?'Finalized and locked':'Changes save automatically'}</span></div><div className="listening-list">{entries.map(entry=><article className="listening-card" key={entry.id}><div className="listening-card-head"><span className="mystery-label">{entry.label}</span><span className="duration-label">{Math.floor(entry.duration/60)}:{String(entry.duration%60).padStart(2,'0')}</span></div>{entry.own&&entry.opened&&<p className="own-entry">Your entry. It receives an automatic 10.</p>}<button className="clip-player" onClick={()=>onPlay(entry)} aria-label={`Play ${entry.label}`}><span className="play-disc"><Play size={17} fill="currentColor"/></span><span><strong>{playing?'Playing original placeholder audio':'Play audio-only clip'}</strong><small>Original synthesized placeholder sound</small></span><AudioLines size={20}/></button><RatingScale value={entry.own?(entry.opened?10:undefined):state.ratingByEntry[entry.id]} onChange={entry.own||state.finalized.includes(state.batch)?undefined:(score)=>onRate(entry,score)} label={`Rate ${entry.label}`}/></article>)}</div><div className="batch-footer"><p>{complete?'All clips rated. Finalize to lock your batch.':'Rate every clip before finalizing. Your ratings stay editable until you finalize.'}</p><button className="button primary" onClick={onFinalize} disabled={!complete||state.finalized.includes(state.batch)}>{state.finalized.includes(state.batch)?'Batch finalized':`Finalize batch ${state.batch+1}`}</button></div><div className="friends-progress"><div><h3>Group progress</h3><span>Other participants update in this demo</span></div>{state.participants.filter(p=>p.id!==selfId).slice(0,3).map(p=><div className="friend-progress" key={p.id}><span>{p.name}</span><span>{p.rated}/50 rated</span><div className="submission-progress"><span style={{width:`${p.rated*2}%`}}/></div></div>)}</div></>;
}

function ParticipantResults({state,onPlay,playing}:{state:DemoState;onPlay:()=>void;playing:boolean}){
  const published=state.revealed;
  const ranked=[...state.entries].sort((a,b)=>a.score-b.score);
  const visible=published>0?ranked.slice(0,Math.ceil(ranked.length*published/5)):[];
  return <><div className="results-status"><div className="result-lock"><LockKeyhole size={20}/></div><h3>{state.published?'Results are being published':'The host is scoring the round'}</h3><p>{state.published?`${published} of 5 groups revealed. Unpublished entries remain hidden.`:'Ratings are being checked and ranked. The results will appear here when the host reveals each group.'}</p>{!state.published&&<span className="muted-small">Your progress: 5 of 5 batches finalized</span>}</div>{state.published&&visible.length>0&&<><h3 className="subsection-title">Revealed groups</h3><div className="reveal-groups">{Array.from({length:published},(_,i)=>{const group=ranked.slice(Math.floor(ranked.length/5)*i,Math.floor(ranked.length/5)*(i+1));return <details open={i===published-1} key={i}><summary>Group {5-i} · {group.length} entries <span>places {group[0]?.score.toFixed(1)}–{group[group.length-1]?.score.toFixed(1)}</span></summary><div className="results-grid">{group.map((e,j)=><SoundtrackCard key={e.id} rank={50-(i*10+j)} title={e.label} franchise="Anonymous" score={e.score.toFixed(1)}/>)}</div></details>;})}</div><Statistics state={state} entries={visible}/></>}{published===0&&<div className="waiting-panel"><p>Results appear only after the host publishes them.</p><button className="small-button" onClick={onPlay}><Play size={15}/>{playing?'Playing':'Play a demo clip'}</button></div>}</>;
}

function Statistics({state,entries}:{state:DemoState;entries:Entry[]}){const average=entries.length?entries.reduce((n,e)=>n+e.score,0)/entries.length:0;const variance=entries.length?entries.reduce((n,e)=>n+(e.score-average)**2,0)/entries.length:0;return <section className="stats-block"><h3>Round statistics</h3><div className="stats-grid"><div><strong>{average.toFixed(2)}</strong><span>Published average</span></div><div><strong>{Math.sqrt(variance).toFixed(2)}</strong><span>Score spread</span></div><div><strong>{state.participants.length}</strong><span>Participants</span></div></div></section>}

function DemoProblemsHost({onChange}:{onChange:(fn:(s:DemoState)=>DemoState)=>void}){return <section className="host-panel"><h3>Simulated problems</h3><button className="small-button" onClick={()=>onChange(s=>({...s,toast:'A flagged audio duration is 5:50, but the source was 2:08.',audit:[...s.audit,'Flagged audio mismatch reviewed']}))}>Flagged audio · review duration mismatch</button><button className="small-button" onClick={()=>onChange(s=>({...s,toast:'Invite expired. Create a fresh single-use invite in the real host console.'}))}>Try expired invite link</button></section>}

function HostConsole({state,onChange,onReveal,onHoldStart,onHoldEnd,hold}:{state:DemoState;onChange:(fn:(s:DemoState)=>DemoState)=>void;onReveal:()=>void;onHoldStart:()=>void;onHoldEnd:()=>void;hold:boolean}){
  const [recoveryInput,setRecoveryInput]=useState('');
  const [selectedParticipant,setSelectedParticipant]=useState('person-1');
  const [selectedBatch,setSelectedBatch]=useState(0);
  const tabs=['overview','submissions','batches','progress','reopen','score','preview','publish','audit','credentials'];
  const setTab=(tab:string)=>onChange(s=>({...s,hostTab:tab}));
  const record=(action:string)=>onChange(s=>({...s,toast:action,audit:[...s.audit,action]}));
  const reopen=()=>onChange(s=>{
    const participant=s.participants.find(p=>p.id===selectedParticipant);
    const finalized=participant?.id===selfId?s.finalized.filter(batch=>batch!==selectedBatch):s.finalized;
    return {...s,finalized,reopenedFor:selectedParticipant,reopenedBatch:selectedBatch,participants:s.participants.map(p=>p.id===selectedParticipant?{...p,finalized:Math.max(0,p.finalized-1)}:p),toast:`Reopened batch ${selectedBatch+1} for ${participant?.name??'participant'}.`,audit:[...s.audit,`Reopened batch ${selectedBatch+1} for ${participant?.name??'participant'}`]};
  });
  const generateRecovery=()=>onChange(s=>{
    if(s.recoveryCodes.length)return {...s,recoveryShown:true,toast:'The existing demo codes are shown again only for this active session.'};
    const codes=Array.from({length:10},()=>`DEMO-${crypto.randomUUID().slice(0,8).toUpperCase()}-${crypto.randomUUID().slice(0,8).toUpperCase()}`);
    return {...s,recoveryCodes:codes,recoveryShown:true,toast:'Ten one-time demo recovery codes generated.'};
  });
  const useRecovery=()=>onChange(s=>{
    const code=recoveryInput.trim().toUpperCase();
    if(!s.recoveryCodes.includes(code))return {...s,toast:'That demo recovery code is invalid or already used.'};
    return {...s,recoveryCodes:s.recoveryCodes.filter(value=>value!==code),recoveryShown:false,recoveryConsumed:true,credentials:[],role:'participant',toast:'Recovery code used. Simulated sessions were revoked; register a replacement passkey before returning to host.',audit:[...s.audit,'Recovery code used; all simulated host sessions revoked']};
  });
  const registerReplacement=()=>onChange(s=>({...s,recoveryConsumed:false,credentials:[...s.credentials,'Replacement passkey'],role:'host',toast:'Replacement simulated passkey registered. Host session restored.',audit:[...s.audit,'Replacement passkey registered after recovery']}));
  return <section className="host-content"><div className="section-head"><div><p className="eyebrow">HOST CONSOLE · DEMO</p><h2>Glass Harbor Trial</h2></div><span className="trial-chip">TRIAL</span></div><div className="host-tabs" role="tablist" aria-label="Host tools">{tabs.map(tab=><button role="tab" aria-selected={state.hostTab===tab} key={tab} className={state.hostTab===tab?'active':''} onClick={()=>setTab(tab)}>{tabLabel(tab)}</button>)}</div><div className="host-panel" role="tabpanel">{state.hostTab==='overview'&&<><h3>Round overview</h3><div className="stats-grid"><div><strong>{state.participants.length}</strong><span>participants</span></div><div><strong>{state.entries.length}</strong><span>entries</span></div><div><strong>{state.phase}</strong><span>phase</span></div></div><button className="button primary" onClick={()=>record('Submission window closed by host')}>Close submissions</button></>}
    {state.hostTab==='submissions'&&<><h3>Submissions review</h3><ul className="host-entry-list">{state.entries.slice(0,8).map(e=><li key={e.id}><span>{e.title}<small>{state.participants.find(p=>p.id===e.submitterId)?.name} · {e.franchise}</small></span><button className="small-button" onClick={()=>record(`Reviewed ${e.title}`)}>Review</button></li>)}</ul><DemoProblemsHost onChange={onChange}/></>}
    {state.hostTab==='batches'&&<><h3>Batch schedule</h3><p>5 listening batches · manual release · spread entries from each submitter.</p>{Array.from({length:5},(_,i)=><div className="schedule-row" key={i}><span>Batch {i+1}</span><span>10 mystery clips</span><button className="small-button" onClick={()=>{setTab('progress');onChange(s=>({...s,batch:i,phase:'listening',toast:`Batch ${i+1} opened by host.`}));}}>Open batch {i+1}</button></div>)}</>}
    {state.hostTab==='progress'&&<><h3>Rating progress</h3>{state.participants.map(p=><div className="friend-progress wide" key={p.id}><span>{p.name}{p.id===selfId?' · you':''}</span><span>{p.finalized}/5 finalized · {p.rated}/50 rated</span><div className="submission-progress"><span style={{width:`${p.finalized*20}%`}}/></div></div>)}<button className="small-button" onClick={()=>onChange(s=>({...s,participants:s.participants.map(p=>({...p,rated:50,finalized:5})),toast:'Simulated friends completed all batches.'}))}>Fast-forward friends</button></>}
    {state.hostTab==='reopen'&&<><h3>Reopen a finalized batch</h3><p>Reopening is logged. This updates progress and unlocks the selected participant's demo batch.</p><select aria-label="Choose participant" value={selectedParticipant} onChange={e=>setSelectedParticipant(e.target.value)}>{state.participants.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select><select aria-label="Choose batch" value={selectedBatch} onChange={e=>setSelectedBatch(Number(e.target.value))}>{Array.from({length:5},(_,i)=><option key={i} value={i}>Batch {i+1}</option>)}</select><button className="button secondary" onClick={reopen}>Reopen ratings</button></>}
    {state.hostTab==='score'&&<><h3>Score round</h3><p>Integer ratings are averaged. Incomplete raters are excluded. This demo uses invented example scores.</p><button className="button primary" onClick={()=>onChange(s=>({...s,phase:'reveals',toast:'Demo round scored and frozen.',audit:[...s.audit,'Round scored and snapshot frozen']}))}>Score and freeze round</button></>}
    {state.hostTab==='preview'&&<><h3>View as participant</h3><p>Participant preview shows only published groups. You are currently seeing the host console.</p><button className="button secondary" onClick={()=>onChange(s=>({...s,role:'participant',toast:'Participant preview. Return to Host to continue.'}))}>Open participant view</button></>}
    {state.hostTab==='publish'&&<><h3>Publish results</h3><p>Hold to confirm, then use the simulated passkey prompt. The real service requires a recent verified assertion.</p><div className="publish-preview">Participant preview: {state.revealed} of 5 reveal groups visible. Next group contains ten entries.</div><button className={`button primary hold-button${hold?' holding':''}`} onPointerDown={onHoldStart} onPointerUp={onHoldEnd} onPointerLeave={onHoldEnd} onKeyDown={e=>{if(e.key===' '||e.key==='Enter')onHoldStart();}} onKeyUp={onHoldEnd}>{hold?'Keep holding…':'Hold to publish next group'}</button><button className="small-button" onClick={onReveal}>Try next reveal group with simulated passkey</button></>}
    {state.hostTab==='audit'&&<><h3>Host audit log</h3><ol className="audit-list">{state.audit.map((line,i)=><li key={`${line}-${i}`}><span>{line}</span><time>Just now</time></li>)}</ol></>}
    {state.hostTab==='credentials'&&<><h3>Passkeys and recovery</h3><p>Demo only. A real host should register a primary and backup passkey, then save ten one-time recovery codes.</p><ul>{state.credentials.map(c=><li key={c}>{c} <button className="small-button" onClick={()=>onChange(s=>({...s,credentials:s.credentials.filter(value=>value!==c),toast:`${c} revoked.`,audit:[...s.audit,`${c} revoked`]}))}>Revoke</button></li>)}</ul><button className="small-button" onClick={()=>onChange(s=>({...s,credentials:[...s.credentials,'New passkey'],toast:'Simulated passkey added.',audit:[...s.audit,'New passkey registered']}))}>Add simulated passkey</button><button className="small-button" onClick={generateRecovery}>Generate recovery codes</button>{state.recoveryShown&&<><p>Shown once. Save these codes; they are only demo values.</p><pre className="recovery-codes">{state.recoveryCodes.join('\n')}</pre><button className="small-button" onClick={()=>onChange(s=>({...s,recoveryShown:false,toast:'Demo recovery codes hidden.'}))}>I saved the codes</button></>}<form onSubmit={e=>{e.preventDefault();useRecovery();}} className="recovery-form"><label>Use one demo recovery code<input value={recoveryInput} onChange={e=>setRecoveryInput(e.target.value)} autoComplete="off"/></label><button className="button secondary" disabled={!recoveryInput.trim()}>Use code and revoke sessions</button></form>{state.recoveryConsumed&&<div className="recovery-reset"><p>Host access is paused until a replacement credential is registered.</p><button className="button primary" onClick={registerReplacement}>Register replacement passkey</button></div>}</>}
  </div></section>;
}
function tabLabel(tab:string){return ({overview:'Overview',submissions:'Submissions',batches:'Batches',progress:'Progress',reopen:'Reopen ratings',score:'Score',preview:'View as participant',publish:'Publish results',audit:'Audit log',credentials:'Credentials'} as Record<string,string>)[tab]??tab;}

function ParticipantTabBar({phase,onSelect}:{phase:RoundPhase;onSelect:(p:RoundPhase)=>void}){return <nav className="participant-bottom-nav" aria-label="Participant navigation">{([['submissions',ListMusic,'Submit'],['listening',Headphones,'Listen'],['reveals',Radio,'Results']] as const).map(([target,Icon,label])=><button key={target} aria-current={phase===target?'page':undefined} onClick={()=>onSelect(target)}><Icon size={18}/><span>{label}</span></button>)}</nav>;}
function DemoBottomNav({onChange,onFastForward,onOpenBatch,onSkipReveals}:{onChange:(p:RoundPhase)=>void;onFastForward:()=>void;onOpenBatch:()=>void;onSkipReveals:()=>void}){return <section className="time-tools" aria-label="Demo time controls"><div><SlidersHorizontal size={16}/><strong>Demo time controls</strong><span>Skip ahead to explore the whole round.</span></div><div className="time-actions"><button onClick={()=>onChange('listening')}><SkipForward size={14}/>Skip to listening</button><button onClick={onOpenBatch}>Open next batch</button><button onClick={onFastForward}>Fast-forward friends</button><button onClick={onSkipReveals}>Skip to reveals</button></div></section>;}
