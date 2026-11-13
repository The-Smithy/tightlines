# TightLines

A fishing guide addon for WoW Forever, and the tool that learns from what you catch.

Everything lives in this folder. The game folder is only where the addon is installed to, and where the game writes the addon's saved data.

```
addon/TightLines/   the addon's source (the copy in the game is installed from here)
creel/              the Rust tool: journal -> SQLite -> Generated.lua, and the installer
tests/              the addon run against a mock of the game's API, and the end-to-end check
```

## The loop

1. **Fish.** The addon writes every cast, catch, fish that got away, "skill too low" message and skill-up to a journal, and keeps each character's trips. The game saves both to `WTF\Account\<account>\SavedVariables\TightLines.lua` on logout or `/reload`.
2. **`creel sync`.** creel stores the journal in a SQLite database and writes `Generated.lua`: where each fish was caught, what share of a zone's catches it is, what came out of each pool, and the fishing skill the game asked for in zones the guide has no number for.
3. **Log in again.** The addon loads `Generated.lua`: the spots go on its maps, unknown catches join the guide, and the journal events creel has stored are dropped from the saved data.

## creel

```
cd creel
cargo run --release -- <command>      # or: cargo install --path . and then just `creel`
```

| Command | What it does |
|---|---|
| `creel` or `creel sync` | Read every account's journal, then rebuild `Generated.lua` (in `addon/TightLines` and in the installed copy) |
| `creel install` | Copy the addon from `addon/TightLines` into the game |
| `creel report` | What the logs say against what the guide says: new catches, new zones, measured skills, pool contents, errors inside the addon |
| `creel trips` | Stored fishing trips, newest first (`--character <name>`, `--limit <n>`) |
| `creel ingest` / `creel build` | The two halves of `sync` |
| `creel paths` | The folders and files in use |

Defaults, each with a flag and an environment variable:

- `--wow` / `CREEL_WOW`: the game folder, `C:\Program Files (x86)\World of Warcraft\_forever_`
- `--db` / `CREEL_DB`: the database, `%LOCALAPPDATA%\creel\creel.db`
- `--addon` / `CREEL_ADDON`: the addon source, `addon\TightLines` in this folder

The database is the only complete copy of the history: once creel has stored journal events, the addon drops them.

## The journal

One event is one string of `key=value` pairs joined by `^`, in `TightLinesDB.journal.events`. The format is described at the top of `addon/TightLines/Journal.lua`. An event is known by the journal's install id and its sequence number, so reading a file twice stores nothing twice.

## Tests

```
cd creel && cargo test          # the Lua reader, the ingest, the analysis
bash tests/e2e.sh               # the whole loop in a sandbox under tests/out
```

`tests/e2e.sh` needs `luajit`. Set `TIGHTLINES_LFD` to the game's `Interface/AddOns` folder to run the addon against the real LibForeverData too.

None of this runs the game: the tests use a mock of its API. What only the game can show is listed below.

## Not yet seen in the game

- The window's look, the EllesmereUI skin, the in-window map and the world-map pins.
- Whether the Forever client sends the events the journal listens for (the fishing channel start, the loot's source id, the "fish got away" and "Requires Fishing N" messages) the way the original game does.
- The addon's fish-by-zone tables are the original game's; `creel report` shows where your catches disagree.

## Other addons

TightLines works with these when they are installed, through their public APIs, at runtime. None of their code or data files are in this repository.

- **Auctionator**: prices, searches and shopping lists (`Auctionator.API.v1`).
- **LibForeverData** and **QuestieDB**: where pools and NPCs stand, and quest records.
- **EllesmereUI**: its skinning and plugin APIs, for the window look and a settings page.

The guide ships its own small tables of game facts in `addon/TightLines/Data.lua` (item, quest, NPC and pool ids, zone fishing skills). The pool, quest and NPC ids were checked against LibForeverData.
