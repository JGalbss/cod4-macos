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

The jgalbs server is ensured in Favorites for fresh and upgraded profiles.
Other saved Favorites are preserved and its address is not duplicated.

Mod compatibility
-----------------

The client exposes the normal fs_game paths used by CoD4 script, IWD, fastfile,
and asset mods, but broad mod compatibility has not been established. The New
Experience server/mod is part of the current native test scope. A mod that
ships its own Windows-only DLL is not directly loadable by an arm64 macOS
process and needs a native source port of that DLL.

Licensing
---------

The client source is distributed under GPLv3. See GPL-3.0.txt and
SOURCE-NOTICE.txt. SDL2 and SDL3 licenses are included inside jgalbs cod4.app.
