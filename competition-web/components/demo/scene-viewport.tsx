"use client";

import dynamic from "next/dynamic";
import { useEffect, useState } from "react";

const IntroScene = dynamic(
  () => import("./scenes").then((module) => module.IntroScene),
  { ssr: false },
);
const VinylScene = dynamic(
  () => import("./scenes").then((module) => module.VinylScene),
  { ssr: false },
);
const RevealScene = dynamic(
  () => import("./scenes").then((module) => module.RevealScene),
  { ssr: false },
);

function canUse3D() {
  if (typeof window === "undefined") return false;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches)
    return false;
  if (
    ((navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 8) < 3
  )
    return false;
  if (navigator.hardwareConcurrency > 0 && navigator.hardwareConcurrency <= 2)
    return false;
  try {
    const canvas = document.createElement("canvas");
    const context =
      canvas.getContext("webgl2", { powerPreference: "low-power" }) ||
      canvas.getContext("webgl", { powerPreference: "low-power" });
    const supported = Boolean(context);
    context?.getExtension("WEBGL_lose_context")?.loseContext();
    return supported;
  } catch {
    return false;
  }
}

export function use3DCapability() {
  const [enabled, setEnabled] = useState(false);
  useEffect(() => setEnabled(canUse3D()), []);
  return enabled;
}

function usePageVisible() {
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    const update = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", update);
    update();
    return () => document.removeEventListener("visibilitychange", update);
  }, []);
  return visible;
}

export function IntroArtwork({
  index,
  enabled,
}: {
  index: number;
  enabled: boolean;
}) {
  return enabled ? (
    <div className="scene-canvas intro-scene" aria-hidden="true">
      <IntroScene index={index} />
    </div>
  ) : (
    <IntroFallback index={index} />
  );
}

export function PlayerArtwork({
  entryId,
  playing,
  analyser,
  enabled,
}: {
  entryId: string;
  playing: boolean;
  analyser: AnalyserNode | null;
  enabled: boolean;
}) {
  const visible = usePageVisible();
  return enabled ? (
    <div className="scene-canvas player-scene" aria-hidden="true">
      <VinylScene
        entryId={entryId}
        playing={playing && visible}
        analyser={analyser}
      />
    </div>
  ) : (
    <div
      className={`vinyl-fallback${playing ? " is-playing" : ""}`}
      aria-hidden="true"
    >
      <ArtworkSwatch seed={entryId} />
    </div>
  );
}

export function RevealArtwork({
  entryId,
  rank,
  enabled,
}: {
  entryId: string;
  rank: number;
  enabled: boolean;
}) {
  const visible = usePageVisible();
  return enabled ? (
    <div className="scene-canvas reveal-scene" aria-hidden="true">
      <RevealScene entryId={entryId} rank={rank} visible={visible} />
    </div>
  ) : (
    <RevealFallback entryId={entryId} rank={rank} />
  );
}

function IntroFallback({ index }: { index: number }) {
  return (
    <div className="intro-fallback" aria-hidden="true">
      {[-2, -1, 1, 2].map((offset) => (
        <div
          className={`intro-fallback-sleeve sleeve-shift-${offset}`}
          key={offset}
        >
          <ArtworkSwatch seed={`sleeve-${index + offset}`} />
        </div>
      ))}
      <div className="intro-fallback-sleeve front-sleeve" key={index}>
        <ArtworkSwatch seed={`sleeve-${index}`} />
      </div>
    </div>
  );
}

function ArtworkSwatch({ seed }: { seed: string }) {
  const hue =
    [...seed].reduce((sum, char) => sum + char.charCodeAt(0), 0) % 360;
  return (
    <div className={`artwork-swatch art-hue-${Math.floor(hue / 30)}`}>
      <span />
      <i />
      <b />
    </div>
  );
}

function RevealFallback({ entryId, rank }: { entryId: string; rank: number }) {
  return (
    <div className="reveal-fallback" aria-hidden="true">
      <div className="reveal-flat-sleeve">
        <ArtworkSwatch seed={entryId} />
      </div>
      <div className={`rank-gem rank-gem-${rank <= 3 ? rank : "other"}`}>
        {rank}
      </div>
    </div>
  );
}
