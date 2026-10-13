"use client";

import { useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  SpeakerHigh,
  SpeakerSlash,
} from "@phosphor-icons/react/ssr";
import type { Entry } from "@/lib/domain";
import { IntroArtwork, use3DCapability } from "./scene-viewport";

export function DemoIntro({
  samples,
  soundEffects,
  onSoundEffects,
  onPreview,
  onEnter,
}: {
  samples: Entry[];
  soundEffects: boolean;
  onSoundEffects: () => void;
  onPreview: (entry: Entry) => void;
  onEnter: () => void;
}) {
  const [index, setIndex] = useState(0);
  const [touchStart, setTouchStart] = useState<number | null>(null);
  const [exploringShelf, setExploringShelf] = useState(false);
  const can3D = use3DCapability();
  const sample = samples[index % samples.length];
  const change = (step: number) => {
    setExploringShelf(true);
    setIndex((current) => (current + step + samples.length) % samples.length);
  };

  return (
    <main className="demo-intro-shell">
      <div className="demo-banner">
        <strong>Demo.</strong> Nothing here is saved or real.
        <button
          className="sound-toggle"
          onClick={onSoundEffects}
          aria-pressed={soundEffects}
          aria-label={`Sound effects ${soundEffects ? "on" : "off"}`}
        >
          {soundEffects ? (
            <SpeakerHigh size={18} />
          ) : (
            <SpeakerSlash size={18} />
          )}
          <span>Sound {soundEffects ? "on" : "off"}</span>
        </button>
      </div>
      <header className="intro-topbar">
        <span className="wordmark">
          OST TRACKER <i>COMPETITION</i>
        </span>
        <span className="trial-chip">TRIAL ROUND</span>
      </header>
      <section className="intro-stage" aria-labelledby="intro-title">
        <div className="intro-copy">
          <p className="eyebrow">THE MYSTERY LISTENING ROOM</p>
          <h1 id="intro-title">
            Hear the track.
            <br />
            Guess the story.
          </h1>
          <p className="intro-lede">
            Friends send in five soundtrack clips. Everyone listens without the
            names, rates each one, then opens the ranking together.
          </p>
          <ul className="intro-steps" aria-label="How the round goes">
            <li>
              <b>1</b>
              <span>Send in your picks</span>
            </li>
            <li>
              <b>2</b>
              <span>Listen and rate</span>
            </li>
            <li>
              <b>3</b>
              <span>Reveal the ranking</span>
            </li>
          </ul>
          <button className="button primary intro-enter" onClick={onEnter}>
            Enter the listening room <ArrowRight size={18} />
          </button>
          <button className="intro-preview" onClick={() => onPreview(sample)}>
            <span aria-hidden="true">▶</span> Hear a generated melody
          </button>
        </div>
        <div
          className="intro-record-stage"
          onTouchStart={(event) =>
            setTouchStart(event.touches[0]?.clientX ?? null)
          }
          onTouchEnd={(event) => {
            if (touchStart === null) return;
            const diff = event.changedTouches[0]?.clientX - touchStart;
            if (Math.abs(diff) > 35) change(diff < 0 ? 1 : -1);
            setTouchStart(null);
          }}
        >
          <div className="intro-record-meta">
            <span>Mystery sleeve {String(index + 1).padStart(2, "0")}</span>
            <span>Tap through the shelf</span>
          </div>
          <IntroArtwork index={index} enabled={can3D && exploringShelf} />
          <div className="intro-shelf-controls">
            <button
              aria-label="Previous mystery record"
              onClick={() => change(-1)}
            >
              <ArrowLeft size={19} />
            </button>
            <div
              role="img"
              className="intro-dots"
              aria-label={`Sleeve ${index + 1} of ${samples.length}`}
            >
              {samples.slice(0, 5).map((_, i) => (
                <span key={i} className={i === index % 5 ? "active" : ""} />
              ))}
            </div>
            <button aria-label="Next mystery record" onClick={() => change(1)}>
              <ArrowRight size={19} />
            </button>
          </div>
          <p className="intro-footnote">
            Original placeholder melodies. No show art or soundtrack audio.
          </p>
        </div>
      </section>
      <footer className="intro-footer">
        <span>One browser tab. Made for a small group of friends.</span>
        <span>
          Need the rules? <a href="/how-it-works">How this works</a>
        </span>
      </footer>
    </main>
  );
}
