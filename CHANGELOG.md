# Changelog

## 0.1.2
- Safety: when a map starts loading, every stored game object is dropped and the mod pauses until 5 seconds after the new map has loaded (at most 60 seconds). Calling into objects of a world that is being torn down can crash the game.

## 0.1.1
- Floor timeline: for 15 seconds after a join or teleport, every change of what you stand on is logged, with the time and the height change. This shows when your game gets a building's collision.
- Reports what you stand on in detail: its mesh, whether it is a player-built piece, and its collision.
- Also inspects building-kit meshes on plain static mesh actors and on the lightweight-piece manager's meshes, which is where decks, floors and walls appear to live.
- Reports which object holds the spawn backlog.
- Fixed: reports could fail with "attempt to call a nil value (method 'IsValid')".
- Removed the "GHOSTED" label: the game sets that flag on every piece, so it said nothing.

## 0.1.0
- First version: diagnostics for walking through player-built pieces after joining or teleporting. The game is not changed.
- Reports on your character's collision, movement and floor, on nearby building actors and instances, on the spawn backlog, and on the building settings.
- Automatic reports after teleports, joins and respawns, and when your footing turns unstable.
- On-demand reports with the console command `fixes_buildings`, or the Mod Menu button.
