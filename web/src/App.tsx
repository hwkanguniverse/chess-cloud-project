/**
 * Routes and the shell.
 *
 * The important structural decision: <Authenticator> wraps only the submit
 * screen, not the app. The directory and the player screen are public because
 * the API behind them is public. Gating the whole app in the browser would be
 * a lock on a door with no wall: anyone could still read the same data
 * straight from the API, and a signed-out visitor would be shown a login form
 * for content that was never restricted.
 *
 * So sign-in is required exactly where the API requires it: submitting.
 */
import { Link, Route, Routes } from "react-router-dom";

import Directory from "./screens/Directory";
import Home from "./screens/Home";
import Player from "./screens/Player";
import UserMenu from "./components/UserMenu";

export default function App() {
  return (
    <div className="app">
      <header className="app-header">
        <Link to="/" className="brand">
          <span aria-hidden="true">♟</span> chess-cloud
        </Link>
        <nav>
          <Link to="/players">Players</Link>
          <Link to="/">Analyse</Link>
        </nav>
        <UserMenu />
      </header>

      <main>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/players" element={<Directory />} />
          <Route path="/player/:platform/:username" element={<Player />} />
          <Route path="*" element={<p className="empty">Nothing here.</p>} />
        </Routes>
      </main>
    </div>
  );
}
