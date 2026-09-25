# PixelConquest Licensing

PixelConquest is a modified version of [OpenFront](https://github.com/openfrontio/OpenFrontIO),
ported to Roblox (Luau) by BunniGames in 2026.

Copyright © OpenFront and Contributors
Copyright © 2026 BunniGames (modifications and new code)

## Code — AGPL v3.0

All code in this repository (every `.luau` file under `sync/`) is licensed under the
**GNU Affero General Public License v3.0**, with additional terms under Section 7.
See [`LICENSE`](LICENSE) for the full text and the additional terms.

In short:

- You may use, modify and redistribute this code, including in a game you run.
- If you run a modified version that players use over a network (such as a Roblox
  experience), you must offer those players the complete source of your version
  under this same license.
- You must keep "© OpenFront and Contributors" and "Modified by BunniGames" visible
  in your game (main menu, loading screen or credits).
- You may not use the names "OpenFront", "PixelConquest" or "BunniGames" as your
  game's title, or imply endorsement by either project.

### Modification notice (AGPL Section 5(a))

The game systems in this repository (simulation, economy, units, structures, nukes,
navy, alliances, rendering and related modules) are ported from OpenFrontIO's
TypeScript source to Luau and modified by BunniGames, starting in 2026. Files ported
from OpenFront say so in their header comments. All other code is original to
PixelConquest.

## Assets — not covered by the AGPL

The AGPL applies to code only. The following are **not** licensed under it and are
**Copyright © 2026 BunniGames, All Rights Reserved**:

- Sounds and music
- Images, icons and decals
- Meshes, textures and visual effects artwork
- Any other asset referenced by Roblox asset ID (`rbxassetid://…`) that BunniGames
  uploaded

These assets may not be copied, re-uploaded or used outside PixelConquest without
written permission. A copy of this game built from this repository will run without
them; replace them with your own.

## Map data

- **Natural Earth** — the world, continent and country maps are derived from
  [Natural Earth](https://www.naturalearthdata.com/) 1:10m data, which is in the
  public domain.
- **OpenStreetMap** — the Tokyo, Venice and New York City maps are derived from
  OpenStreetMap data, © OpenStreetMap contributors, available under the
  [Open Database License (ODbL)](https://www.openstreetmap.org/copyright). The derived
  map data in `TokyoMap.luau`, `VeniceMap.luau` and `NewYorkMap.luau` is made
  available under the ODbL.

## Getting the source

The source for the version of PixelConquest running on Roblox is this repository.
In-game, players are directed to it through the community links on the game's
Roblox page.
