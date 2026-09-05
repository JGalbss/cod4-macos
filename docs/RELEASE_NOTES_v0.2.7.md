# jgalbs cod4 0.2.7

This Apple Silicon release candidate corrects an overly sensitive active-play
connection warning on high-refresh-rate Macs.

## Fixed

- Uses a fixed two-second command-stall threshold for `Connection Interrupted`
  instead of a 128-command history whose duration shrank as frame rate rose.
- Prevents ordinary one-second Internet jitter from flashing the warning at
  120+ FPS.
- Still displays the warning for a genuine two-second outage and retains the
  existing hard-timeout behavior.

## Verified

- A live protocol-21 session completed without a warning during normal traffic.
- A controlled three-second server-to-client outage displayed the warning at
  2.002 seconds, recovered when traffic resumed, and exited cleanly.

This DMG is ad-hoc signed for private testing. A public release still requires
Developer ID signing, Apple notarization, and stapling. Players must provide a
legally owned Call of Duty 4 data directory; retail game data is not bundled.
