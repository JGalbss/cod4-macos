# jgalbs cod4 0.2.6

This Apple Silicon release candidate fixes the false connection warning seen
between otherwise healthy matches.

## Fixed

- Suppresses `Connection Interrupted` only during the final scoreboard and map
  vote transition, when the server intentionally pauses command consumption.
- Leaves real network timeout detection active.

## Verified

- Real multiplayer gameplay held approximately 120 FPS on a 120 Hz display
  with clean normal-frame pacing and CPU/GPU headroom.
- A timed match passed through outcome, intermission, and map-vote state without
  showing the false warning or crashing.
- The current full-color vision policy remained neutral after joining the live
  protocol-21 server; remote developer film overrides were rejected.

This DMG is ad-hoc signed for private testing. A public release still requires
Developer ID signing, Apple notarization, and stapling. Players must provide a
legally owned Call of Duty 4 data directory; retail game data is not bundled.
