/**
 * Landing: what this is, before anyone is asked to sign in.
 *
 * Public, and deliberately so: the only thing behind sign-in is submitting,
 * so the first screen should explain the app and hand out the public data
 * rather than open on a login form.
 *
 * The recently-analysed list is the one API call here - one read of GET
 * /players per visit. It fails quietly: a throttled or unreachable API hides
 * that section and leaves the rest of the page standing, because nothing else
 * on it depends on the backend.
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";

import { listPlayers, type DirectoryEntry } from "../api";
import { Button } from "../components/ui";
import { ago } from "../format";

const RECENT = 5;

const FEATURES = [
  {
    title: "Your entire history, not just last month",
    body: "Every game you have ever played on Chess.com, counted. See your results, how you do as white and black, which time controls you play most, and the range your rating has covered. It works even at hikaru's 70,840 games.",
  },
  {
    title: "Find out where your games go wrong",
    body: "Run your recent games through Stockfish and see your blunders, your mistakes, and the point in the game where you start losing ground. Then jump straight to your worst games and see what happened.",
  },
  {
    title: "Free to look, no account needed",
    body: "Browse any analysed player, yours or anyone else's, without signing up. You only need an account to add a new player or ask for engine analysis.",
  },
];

const STEPS = [
  "Sign in and submit a Chess.com username.",
  "Every archive is fetched and counted, and the player page fills in as each month lands.",
  "Once the games are in, ask for engine analysis from the player page. Each account gets 5 runs, refilling one an hour.",
];

function RecentPlayers() {
  const [players, setPlayers] = useState<DirectoryEntry[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;

    listPlayers()
      .then((response) => {
        if (cancelled) return;
        const recent = [...response.players]
          .sort((a, b) => (b.lastAnalysedAt ?? 0) - (a.lastAnalysedAt ?? 0))
          .slice(0, RECENT);
        setPlayers(recent);
      })
      .catch(() => !cancelled && setFailed(true));

    // Same StrictMode guard as Directory.
    return () => {
      cancelled = true;
    };
  }, []);

  if (failed) return null;

  return (
    <section className="landing-section">
      <h2 className="label">Recently analysed</h2>
      {!players ? (
        <p className="muted small">Loading…</p>
      ) : players.length === 0 ? (
        <p className="muted small">
          Nobody has been analysed yet. <Link to="/analyse">Be the first.</Link>
        </p>
      ) : (
        <>
          <ul className="recent-list">
            {players.map((player) => (
              <li key={`${player.platform}/${player.username}`}>
                <Link to={`/player/${player.platform}/${player.username}`}>
                  {player.username}
                </Link>
                <span className="muted mono">
                  {player.games.toLocaleString()} games
                </span>
                <span className="muted small">{ago(player.lastAnalysedAt)}</span>
              </li>
            ))}
          </ul>
          <Link to="/players" className="small">
            See all players →
          </Link>
        </>
      )}
    </section>
  );
}

export default function Landing() {
  const navigate = useNavigate();

  return (
    <>
      <section className="hero">
        <h1>Every game a Chess.com player has played.</h1>
        <p className="muted hero-lede">
          Put in a username and get their entire Chess.com history counted,
          not just the last few months, then run their recent games through
          Stockfish. It only works with Chess.com for now.
        </p>
        <div className="cta-row">
          <Button size="lg" onClick={() => navigate("/analyse")}>
            Analyse a player
          </Button>
          <Button
            size="lg"
            variant="secondary"
            onClick={() => navigate("/players")}
          >
            Browse players
          </Button>
        </div>
      </section>

      <section className="landing-section">
        <h2 className="label">What it does</h2>
        <div className="landing-grid">
          {FEATURES.map((feature) => (
            <div key={feature.title}>
              <h3>{feature.title}</h3>
              <p className="muted small">{feature.body}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="landing-section">
        <h2 className="label">How it works</h2>
        <ol className="landing-grid steps">
          {STEPS.map((step) => (
            <li key={step} className="small">
              {step}
            </li>
          ))}
        </ol>
      </section>

      <RecentPlayers />
    </>
  );
}
