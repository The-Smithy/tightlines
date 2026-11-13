//! The database and the way in: TightLines' SavedVariables files are read and
//! every journal event, trip and name in them is stored. Reading the same file
//! twice stores nothing twice (an event is known by its install id and its
//! sequence number).

use crate::lua::{self, Table, Value};
use anyhow::{Context, Result};
use rusqlite::{Connection, params};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The fishing bobber's game object id: loot that came from it is open water.
pub const BOBBER: i64 = 35591;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS installs (
    id TEXT PRIMARY KEY,
    account TEXT,
    first_seen INTEGER NOT NULL,
    last_ingest INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    install TEXT NOT NULL,
    seq INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    toon TEXT,
    trip INTEGER,
    map INTEGER,
    subzone TEXT,
    x REAL,
    y REAL,
    skill INTEGER,
    modifier INTEGER,
    hour INTEGER,
    source INTEGER,
    cast_seq INTEGER,
    need INTEGER,
    skill_from INTEGER,
    skill_to INTEGER,
    text TEXT,
    PRIMARY KEY (install, seq)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS events_kind_map ON events (kind, map);
CREATE TABLE IF NOT EXISTS catch_items (
    install TEXT NOT NULL,
    seq INTEGER NOT NULL,
    item INTEGER NOT NULL,
    qty INTEGER NOT NULL,
    PRIMARY KEY (install, seq, item)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS catch_items_item ON catch_items (item);
CREATE TABLE IF NOT EXISTS trips (
    install TEXT NOT NULL,
    toon TEXT NOT NULL,
    trip INTEGER NOT NULL,
    started INTEGER NOT NULL,
    stopped INTEGER,
    open INTEGER NOT NULL,
    casts INTEGER NOT NULL,
    catches INTEGER NOT NULL,
    away INTEGER NOT NULL,
    skill_start INTEGER,
    skill_end INTEGER,
    value INTEGER,
    PRIMARY KEY (install, toon, trip)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS trip_items (
    install TEXT NOT NULL,
    toon TEXT NOT NULL,
    trip INTEGER NOT NULL,
    item INTEGER NOT NULL,
    qty INTEGER NOT NULL,
    PRIMARY KEY (install, toon, trip, item)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS trip_zones (
    install TEXT NOT NULL,
    toon TEXT NOT NULL,
    trip INTEGER NOT NULL,
    map INTEGER NOT NULL,
    catches INTEGER NOT NULL,
    PRIMARY KEY (install, toon, trip, map)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS names (
    kind TEXT NOT NULL,
    id INTEGER NOT NULL,
    name TEXT NOT NULL,
    PRIMARY KEY (kind, id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS guide_items (item INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS guide_fish (
    item INTEGER NOT NULL,
    map INTEGER NOT NULL,
    PRIMARY KEY (item, map)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS guide_zones (map INTEGER PRIMARY KEY, base_skill INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS guide_pools (object INTEGER PRIMARY KEY, name TEXT NOT NULL);
";

pub fn open(path: &Path) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
    }
    let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
    conn.execute_batch(SCHEMA)?;
    Ok(conn)
}

/// TightLines' SavedVariables files under a game folder: (account, file).
pub fn find_saved_variables(wow: &Path) -> Vec<(String, PathBuf)> {
    let mut found = Vec::new();
    let accounts = wow.join("WTF").join("Account");
    let Ok(entries) = std::fs::read_dir(&accounts) else { return found };
    for entry in entries.flatten() {
        let file = entry.path().join("SavedVariables").join("TightLines.lua");
        if file.is_file() {
            found.push((entry.file_name().to_string_lossy().into_owned(), file));
        }
    }
    found.sort();
    found
}

/// What reading one file added.
#[derive(Debug, Default, PartialEq)]
pub struct Ingested {
    pub install: Option<String>,
    pub events_in_file: usize,
    pub events_new: usize,
    pub trips: usize,
    pub note: Option<String>,
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn fields(event: &str) -> HashMap<&str, &str> {
    event.split('^').filter_map(|part| part.split_once('=')).collect()
}

pub fn ingest_file(conn: &mut Connection, account: &str, path: &Path) -> Result<Ingested> {
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let text = String::from_utf8_lossy(&bytes);
    ingest_text(conn, account, &text).with_context(|| format!("in {}", path.display()))
}

pub fn ingest_text(conn: &mut Connection, account: &str, text: &str) -> Result<Ingested> {
    let globals = lua::parse(text)?;
    let mut out = Ingested::default();
    let Some(db) = globals.iter().find(|(name, _)| name == "TightLinesDB").and_then(|(_, v)| v.as_table()) else {
        out.note = Some("no TightLinesDB in the file".into());
        return Ok(out);
    };
    let Some(journal) = db.table("journal") else {
        out.note = Some("no journal yet: log in once with TightLines enabled".into());
        return Ok(out);
    };
    let Some(install) = journal.str("id") else {
        out.note = Some("the journal has no id yet: log in once with TightLines enabled".into());
        return Ok(out);
    };
    out.install = Some(install.to_string());
    let toons: Vec<&str> = journal.table("chars").map(|t| t.array().into_iter().filter_map(Value::as_str).collect()).unwrap_or_default();

    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO installs (id, account, first_seen, last_ingest) VALUES (?1, ?2, ?3, ?3)
         ON CONFLICT(id) DO UPDATE SET account = ?2, last_ingest = ?3",
        params![install, account, now()],
    )?;

    // Events
    {
        let mut insert_event = tx.prepare(
            "INSERT OR IGNORE INTO events (install, seq, ts, kind, toon, trip, map, subzone, x, y, skill, modifier,
                hour, source, cast_seq, need, skill_from, skill_to, text)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
        )?;
        let mut insert_item =
            tx.prepare("INSERT OR IGNORE INTO catch_items (install, seq, item, qty) VALUES (?1, ?2, ?3, ?4)")?;
        let events = journal.table("events").map(Table::array).unwrap_or_default();
        for event in events.into_iter().filter_map(Value::as_str) {
            let f = fields(event);
            let int = |key: &str| f.get(key).and_then(|v| v.trim().parse::<f64>().ok()).map(|v| v as i64);
            let real = |key: &str| f.get(key).and_then(|v| v.trim().parse::<f64>().ok());
            let (Some(seq), Some(kind)) = (int("s"), f.get("e")) else { continue };
            out.events_in_file += 1;
            let toon = int("c").and_then(|i| toons.get((i - 1).max(0) as usize)).copied();
            let added = insert_event.execute(params![
                install,
                seq,
                int("ts").unwrap_or(0),
                kind,
                toon,
                int("tr"),
                int("m"),
                f.get("sz"),
                real("x"),
                real("y"),
                int("sk"),
                int("md"),
                int("h"),
                int("src"),
                int("cs"),
                int("need"),
                int("from"),
                int("to"),
                f.get("text"),
            ])?;
            if added == 0 {
                continue;
            }
            out.events_new += 1;
            for pair in f.get("it").map(|it| it.split(',')).into_iter().flatten() {
                if let Some((item, qty)) = pair.split_once(':') {
                    if let (Ok(item), Ok(qty)) = (item.parse::<i64>(), qty.parse::<i64>()) {
                        insert_item.execute(params![install, seq, item, qty])?;
                    }
                }
            }
        }
    }

    // Names the addon saw for items, maps and pools
    if let Some(names) = journal.table("names") {
        let mut insert = tx.prepare("INSERT OR REPLACE INTO names (kind, id, name) VALUES (?1, ?2, ?3)")?;
        for (key, kind) in [("i", "item"), ("m", "map"), ("o", "object")] {
            for (id, name) in names.table(key).into_iter().flat_map(Table::int_entries) {
                if let Some(name) = name.as_str() {
                    insert.execute(params![kind, id, name])?;
                }
            }
        }
    }

    // Each character's trips
    if let Some(chars) = db.table("chars") {
        let mut insert_trip = tx.prepare(
            "INSERT OR REPLACE INTO trips (install, toon, trip, started, stopped, open, casts, catches, away,
                skill_start, skill_end, value)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        )?;
        let mut clear_items = tx.prepare("DELETE FROM trip_items WHERE install = ?1 AND toon = ?2 AND trip = ?3")?;
        let mut clear_zones = tx.prepare("DELETE FROM trip_zones WHERE install = ?1 AND toon = ?2 AND trip = ?3")?;
        let mut insert_trip_item =
            tx.prepare("INSERT OR REPLACE INTO trip_items (install, toon, trip, item, qty) VALUES (?1, ?2, ?3, ?4, ?5)")?;
        let mut insert_trip_zone =
            tx.prepare("INSERT OR REPLACE INTO trip_zones (install, toon, trip, map, catches) VALUES (?1, ?2, ?3, ?4, ?5)")?;
        for (toon, value) in chars.str_entries() {
            let Some(trips) = value.as_table().and_then(|t| t.table("trips")) else { continue };
            for trip in trips.array().into_iter().filter_map(Value::as_table) {
                let (Some(id), Some(started)) = (trip.int("id"), trip.int("start")) else { continue };
                let open = trip.get("open").is_some_and(Value::is_true);
                insert_trip.execute(params![
                    install,
                    toon,
                    id,
                    started,
                    trip.int("stop").or(trip.int("last")),
                    open,
                    trip.int("casts").unwrap_or(0),
                    trip.int("catches").unwrap_or(0),
                    trip.int("away").unwrap_or(0),
                    trip.int("skill0"),
                    trip.int("skill1"),
                    trip.int("value"),
                ])?;
                clear_items.execute(params![install, toon, id])?;
                clear_zones.execute(params![install, toon, id])?;
                for (item, qty) in trip.table("items").into_iter().flat_map(Table::int_entries) {
                    insert_trip_item.execute(params![install, toon, id, item, qty.as_i64().unwrap_or(0)])?;
                }
                for (map, catches) in trip.table("zones").into_iter().flat_map(Table::int_entries) {
                    insert_trip_zone.execute(params![install, toon, id, map, catches.as_i64().unwrap_or(0)])?;
                }
                out.trips += 1;
            }
        }
    }

    // What the guide itself says, for `creel report` to compare against
    if let Some(guide) = db.table("guide") {
        tx.execute_batch("DELETE FROM guide_items; DELETE FROM guide_fish; DELETE FROM guide_zones; DELETE FROM guide_pools;")?;
        for (map, base) in guide.table("zoneSkill").into_iter().flat_map(Table::int_entries) {
            tx.execute("INSERT OR REPLACE INTO guide_zones (map, base_skill) VALUES (?1, ?2)", params![map, base.as_i64().unwrap_or(0)])?;
        }
        for (item, zones) in guide.table("fish").into_iter().flat_map(Table::int_entries) {
            tx.execute("INSERT OR REPLACE INTO guide_items (item) VALUES (?1)", params![item])?;
            for map in zones.as_str().unwrap_or("").split(',').filter_map(|m| m.trim().parse::<i64>().ok()) {
                tx.execute("INSERT OR REPLACE INTO guide_fish (item, map) VALUES (?1, ?2)", params![item, map])?;
            }
        }
        for (object, name) in guide.table("pools").into_iter().flat_map(Table::int_entries) {
            if let Some(name) = name.as_str() {
                tx.execute("INSERT OR REPLACE INTO guide_pools (object, name) VALUES (?1, ?2)", params![object, name])?;
            }
        }
    }

    tx.commit()?;
    Ok(out)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub const FIXTURE: &str = r#"
TightLinesDB = {
	["journal"] = {
		["v"] = 1,
		["id"] = "abc123",
		["seq"] = 9,
		["chars"] = {
			"Tester-Realm", -- [1]
		},
		["events"] = {
			"s=1^e=trip^ts=100^c=1^tr=1", -- [1]
			"s=2^e=cast^ts=101^c=1^tr=1^m=1444^sz=Verdantis River^x=31.2^y=43.5^sk=230^md=75^h=20", -- [2]
			"s=3^e=catch^ts=120^c=1^tr=1^m=1444^sz=Verdantis River^x=31.2^y=43.5^sk=230^md=75^h=20^it=13758:1^src=35591^cs=2", -- [3]
			"s=4^e=cast^ts=130^c=1^tr=1^m=1444^x=31.4^y=43.6^sk=230^md=75^h=20", -- [4]
			"s=5^e=away^ts=150^c=1^tr=1^m=1444^x=31.4^y=43.6^sk=230^md=75^h=20^cs=4", -- [5]
			"s=6^e=cast^ts=160^c=1^tr=1^m=1444^x=45.2^y=61^sk=230^md=75^h=20", -- [6]
			"s=7^e=catch^ts=180^c=1^tr=1^m=1444^x=45.2^y=61^sk=230^md=75^h=20^it=13422:2,99001:1^src=180712^cs=6", -- [7]
			"s=8^e=lowskill^ts=200^c=1^m=2548^sz=Glimmer Shoals^need=180^sk=150^md=0", -- [8]
			"s=9^e=skillup^ts=210^c=1^m=1444^from=230^to=231", -- [9]
		},
		["names"] = {
			["i"] = {
				[13758] = "Raw Redgill",
				[13422] = "Stonescale Eel",
				[99001] = "Forever \"Glimmerfin\"",
			},
			["m"] = {
				[1444] = "Feralas",
				[2548] = "Riverglades",
			},
			["o"] = {
				[180712] = "Stonescale Eel Swarm",
			},
		},
	},
	["chars"] = {
		["Tester-Realm"] = {
			["nextTrip"] = 2,
			["trips"] = {
				{
					["id"] = 1,
					["start"] = 100,
					["last"] = 180,
					["open"] = true,
					["casts"] = 3,
					["catches"] = 2,
					["away"] = 1,
					["skill0"] = 230,
					["items"] = {
						[13758] = 1,
						[13422] = 2,
					},
					["zones"] = {
						[1444] = 2,
					},
				}, -- [1]
			},
		},
	},
	["guide"] = {
		["zoneSkill"] = {
			[1444] = 205,
		},
		["fish"] = {
			[13758] = "1425,1444",
			[13422] = "",
		},
		["pools"] = {
			[180712] = "Stonescale Eel Swarm",
		},
	},
}
"#;

    #[test]
    fn stores_a_file_once() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        let first = ingest_text(&mut conn, "ACCOUNT", FIXTURE).unwrap();
        assert_eq!(first.install.as_deref(), Some("abc123"));
        assert_eq!((first.events_in_file, first.events_new, first.trips), (9, 9, 1));
        let again = ingest_text(&mut conn, "ACCOUNT", FIXTURE).unwrap();
        assert_eq!((again.events_in_file, again.events_new), (9, 0));

        let count = |sql: &str| conn.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        assert_eq!(count("SELECT COUNT(*) FROM events"), 9);
        assert_eq!(count("SELECT COUNT(*) FROM catch_items"), 3);
        assert_eq!(count("SELECT qty FROM catch_items WHERE item = 13422"), 2);
        assert_eq!(count("SELECT source FROM events WHERE seq = 7"), 180712);
        assert_eq!(count("SELECT need FROM events WHERE kind = 'lowskill'"), 180);
        assert_eq!(count("SELECT COUNT(*) FROM trips WHERE open = 1"), 1);
        assert_eq!(count("SELECT COUNT(*) FROM trip_items"), 2);
        assert_eq!(count("SELECT COUNT(*) FROM guide_fish"), 2);
        assert_eq!(count("SELECT COUNT(*) FROM guide_items"), 2);
        let toon: String = conn.query_row("SELECT toon FROM events WHERE seq = 3", [], |r| r.get(0)).unwrap();
        assert_eq!(toon, "Tester-Realm");
        let name: String = conn.query_row("SELECT name FROM names WHERE kind = 'item' AND id = 99001", [], |r| r.get(0)).unwrap();
        assert_eq!(name, "Forever \"Glimmerfin\"");
    }

    #[test]
    fn a_file_without_a_journal_is_not_an_error() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        let out = ingest_text(&mut conn, "ACCOUNT", "TightLinesDB = { [\"scale\"] = 1 }").unwrap();
        assert_eq!(out.events_new, 0);
        assert!(out.note.is_some());
    }

    pub fn fixture_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        ingest_text(&mut conn, "ACCOUNT", FIXTURE).unwrap();
        conn
    }
}
