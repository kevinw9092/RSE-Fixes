# Changelog

## 0.1.7
- Full reports walk every object in the game and list every primitive (anything that draws or collides) within 5 m, whatever its class. The deck was not any of the mesh classes searched by name.
- Full reports count the building system's representation components and the ISM pool, and log the properties of the nearest ones.

## 0.1.6
- Full reports list every mesh component within 5 m of you, whatever its mesh: name, folder, owner and collision.
- Full reports list building-kit instanced meshes anywhere in the world, with owner and instance count (in case their "near me" query returns nothing).

## 0.1.5
- Safety: the local player is now found with property reads only, with no game function calls on objects that may belong to a world being torn down.
- Waits 10 seconds (was 5) after a map has loaded, and logs when it resumes.

## 0.1.4
- What you stand on is now read from your character's movement base, which works where the floor reference reads as "(unknown component)".
- Full reports also list building-kit instanced meshes whose distance cannot be read, with their owner and instance count.

## 0.1.3
- Fixed: the Mod Menu button "Log building diagnostics now" did nothing unless a setting had also changed.
- Full reports list every piece actor nearby, with the parts that block you (or NONE).
- Full reports search every building-kit mesh near you, whatever object owns it, with its collision. This can cause a short hitch, so only the full report does it.

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
