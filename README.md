# RSE-Fixes

*Part of **RSE** (RuneScape Enhanced), a family of UE4SS mods for RuneScape: Dragonwilds.*

Fixes for problems in the game itself. Each fix starts as a diagnostic, so it is built on what the game actually does rather than on guesses.

## 0.1: walking through player-built pieces

**The problem.** After joining a world or teleporting, your character sometimes jitters up and down on a floor, wall or deck built by players, then falls through it. This happens without any mods.

**What is known so far.**
- Player buildings reach each client through a per-player building stream, and they are spawned in time slices. Pieces exist as individual actors, as instances in shared instanced meshes, or as lightweight pieces.
- The jitter-then-fall pattern points to your game and the server disagreeing about whether the floor is there. Movement is predicted on your machine and corrected by the server, and the two keep overruling each other.

**What 0.1 does.** It changes nothing in the game. It writes reports to `ue4ss\UE4SS.log`, lines starting with `[RSE-Fixes]`:
- **Your character:** collision, the channels it blocks, movement mode, and what it is standing on.
- **Nearby building actors:** present, ghosted, collision on, and whether they would stop your character.
- **Nearby building instances:** how many are around you, and whether their meshes have collision.
- **The spawn backlog:** pieces still waiting to load or spawn.
- **The building settings** that pace spawning and streaming.

**When reports are written.**
- **Automatically**, after a teleport, a join or a respawn, at +1, +3 and +6 seconds.
- **Automatically**, the moment your footing turns unstable (walking and falling flicker, or upward snaps).
- **On demand:** type `fixes_buildings` in the console, or use **Log building diagnostics now** in Esc > MODS (with RSE-ModMenu). This writes a full report now and short ones after 2, 5 and 10 seconds.

**On the server (0.2).** It only happens when you arrive (join or teleport) *on* a building, and only with a remote host. Your game has the building's collision while you fall, so the server is the side that pulls you through. Install RSE-Fixes on the server or host, and it logs what the server sees under each arriving player:
- **A dedicated server:** copy the `RSE-Fixes` folder to the server's `ue4ss\Mods\` and add `RSE-Fixes : 1` to its `mods.txt`. See RSE-Server.
- **Hosting from your own game:** nothing extra. A friend joins, and the host's `UE4SS.log` gets `server:` lines for them. Type `fixes_players` on the host for a report on demand.

**The fix (0.3, off by default).** Turn on `HoldArrivals` on the server, or in the host's game. When a player from another machine joins or teleports, the server looks under them:
- **On the ground:** nothing changes.
- **Otherwise:** the server freezes them with the game's own freeze until the building under them has collision, puts them just on top of it and lets them go. That's a short pause, at most `HoldSeconds`.
- **While the game holds them itself** (loading the world around them, teleporting, frozen): the hold waits. Once the game lets go, it looks under them again (0.4).

Your own game can't do this: the server decides where you are.

**Please help.** When it happens, keep playing for a few seconds, then send `UE4SS.log`. Say whether you were hosting, joined someone, or played on a dedicated server.

## Installation
Copy the `RSE-Fixes` folder to `RSDragonwilds\Binaries\Win64\ue4ss\Mods\`. It needs UE4SS, a recent experimental build.

## Settings
In `config.txt`, or Esc > MODS with RSE-ModMenu:

| Setting | Default | Meaning |
|---|---|---|
| `AutoDiagnose` | `true` | Automatic reports after teleports, joins and unstable footing |
| `Radius` | `15` | Metres around your character to inspect |
| `TeleportDistance` | `50` | Metres moved within a quarter of a second that count as a teleport |
| `HoldArrivals` | `false` | Server/host fix: hold arriving players until building collision exists under them |
| `HoldSeconds` | `10` | Longest hold before letting them go where they are (2 to 30) |
| `Debug` | `false` | Automatic reports and log lines; off, the mod only reports when asked |
