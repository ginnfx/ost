import { Play } from "@phosphor-icons/react/ssr";

export function SoundtrackCard({
  title,
  franchise,
  score,
  rank,
  cover,
}: {
  title: string;
  franchise: string;
  score: string;
  rank: number;
  cover?: string;
}) {
  return (
    <article className="ost-card">
      <div className="ost-art" aria-hidden="true">
        {cover ? <img src={cover} alt="" /> : <div className="art-fallback" />}
        <span className={`rank rank-${rank <= 3 ? rank : "other"}`}>
          {rank}
        </span>
      </div>
      <div className="ost-card-copy">
        <h3>{title}</h3>
        <p>{franchise}</p>
      </div>
      <div className="ost-score">
        <strong>{score}</strong>
        <span>AVG</span>
      </div>
    </article>
  );
}

export function RatingScale({
  value,
  onChange,
  label,
}: {
  value?: number;
  onChange?: (value: number) => void;
  label: string;
}) {
  return (
    <fieldset className="rating-field">
      <legend>{label}</legend>
      <div className="rating-options" role="radiogroup" aria-label={label}>
        {Array.from({ length: 10 }, (_, i) => i + 1).map((score) => (
          <button
            type="button"
            role="radio"
            aria-checked={value === score}
            aria-label={`${label}, rating ${score} of 10`}
            className={`rating-option${value === score ? " selected" : ""}`}
            key={score}
            onClick={() => onChange?.(score)}
            disabled={!onChange}
          >
            {score}
          </button>
        ))}
      </div>
    </fieldset>
  );
}

export function CompactPlayer({
  title,
  playing,
  onToggle,
  onExpand,
}: {
  title: string;
  playing: boolean;
  onToggle: () => void;
  onExpand: () => void;
}) {
  return (
    <section className="compact-player" aria-label="Audio player">
      <button
        type="button"
        className="player-action"
        aria-label={playing ? "Pause" : "Play"}
        onClick={onToggle}
      >
        <Play size={18} fill="currentColor" />
      </button>
      <div className="player-track">
        <strong>{title}</strong>
        <div className="player-progress" aria-hidden="true">
          <span />
        </div>
      </div>
      <button type="button" className="player-expand" onClick={onExpand}>
        Full player
      </button>
    </section>
  );
}

export function FullscreenPlayer({
  title,
  onClose,
}: {
  title: string;
  onClose: () => void;
}) {
  return (
    <dialog
      className="fullscreen-player"
      open
      aria-label="Fullscreen audio player"
    >
      <button className="close-button" onClick={onClose}>
        Close player
      </button>
      <div className="player-cover" aria-hidden="true" />
      <p className="eyebrow">NOW PLAYING</p>
      <h2>{title}</h2>
      <div className="visualizer" aria-label="Audio visualizer">
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
        <span />
      </div>
      <section className="lyrics-panel" aria-label="Lyrics">
        <h3>Lyrics</h3>
        <p>Synced lyrics will appear here when available.</p>
      </section>
      <button className="button primary" onClick={onClose}>
        Done
      </button>
    </dialog>
  );
}
