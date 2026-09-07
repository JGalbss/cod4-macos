# jgalbs cod4 0.2.9 release candidate

This build fixes three native-client gameplay regressions:

- Level-up, kill-streak, and other game notifications now expire using their
  configured on-screen duration.
- Smoke now blocks friendly-name and aim-assist visibility from its first
  active visibility particle instead of skipping blocker slot zero.
- Profiles polluted by the old `NativeInputCheck` diagnostic now restore their
  active profile name; intentional custom multiplayer names are preserved.

The client still requires legally owned Call of Duty 4 game data. Retail game
files are not included in the app or disk image.
