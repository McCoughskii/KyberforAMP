# Co-Op 24/7 (draft)

KYBER server plugin: Galactic Assault with every human on one team against AI, looping maps forever.

- All humans go to team 1; bots fill team 2 to `playersPerTeam`, and (optionally) top up team 1 as well.
- Bots are added/removed a few at a time every `tickInterval` seconds, so joins and leaves rebalance automatically.
- Replaces the map rotation with a shuffled Galactic Assault list (turn off with `overrideRotation = false`).
- Chat: `!coop` (status), `!next` (next map). Console: `Coop.Status`, `Coop.PerTeam <n>`, `Coop.Fill on|off`.

Settings live in `server/config.lua`.

## Install on the AMP server

1. Build: `cd plugins/coop-247 && zip -r ../coop-247.kbplugin plugin.json server`
2. Upload `coop-247.kbplugin` to the instance's `plugins/` folder.
3. Tick **Enable Plugins Folder** in App Settings and restart.
4. Look for `[Co-Op 24/7] loaded:` in the console.
