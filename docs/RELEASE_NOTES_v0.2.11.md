# jgalbs cod4 0.2.11 release candidate

- Kill-streak and level-up text now fades and clears at the effect's deadline.
- The multiplayer kill feed renders the weapon icon instead of binary gibberish.
- Rust, Terminal, and Scrapyard remain bundled; retail CoD4 files are not included.

Quit the old app, open the DMG, and replace **jgalbs cod4.app** in Applications.
Your profile, settings, and downloaded maps are kept outside the app and are
preserved. Launch the Applications copy after replacing it.

Requires Apple Silicon and macOS 15.5 or newer. This is an ad-hoc-signed test
build, not Apple-notarized. For a trusted download blocked by Gatekeeper, attempt
to open it, then use System Settings → Privacy & Security → Open Anyway.
New players must select their legally owned CoD4 data directory on first launch.

Verification: the in-client HUD test keeps timed elements alive and confirms
visible → fading → expired for two successive awards without hiding the permanent
control label. A three-kill, two-client combat test also confirmed that the
actual "3 Kill Streak!" award and radar prompt fade and expire, along with
working inline weapon materials, killcam, and respawn. Timing tests cover
replay, re-arming, expiry boundaries,
untimed text, and integer overflow.
