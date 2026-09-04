jgalbs cod4 for Apple Silicon
=============================

This is a native arm64 macOS and Metal client. It does not use Wine.

Requirements
------------

- Apple Silicon Mac
- macOS 15.5 or newer
- A legally owned Call of Duty 4 installation

The application does not include Call of Duty 4 maps, textures, sounds, or
other retail game data. On first launch, select the Call of Duty 4 directory
that contains main/iw_00.iwd.

Installation
------------

Drag jgalbs cod4.app to Applications, open it, and select the retail data directory
when prompted.

The New Experience server is added to Favorites automatically for a new
profile. Existing Favorites lists are preserved.

Mod compatibility
-----------------

CoD4 script, IWD, fastfile, and asset mods use the normal fs_game paths. The
New Experience server/mod is part of this build's native play test. A mod that
ships its own Windows-only DLL is not directly loadable by an arm64 macOS
process and needs a native source port of that DLL.

Licensing
---------

The client source is distributed under GPLv3. See GPL-3.0.txt and
SOURCE-NOTICE.txt. SDL2 and SDL3 licenses are included inside jgalbs cod4.app.
