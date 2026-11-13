//! The way out: what the stored events say, as the addon's Generated.lua and as
//! a report for a person to read.

use crate::store::BOBBER;
use anyhow::Result;
use rusqlite::Connection;
use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;

/// At most this many spots per fish (or pool) and map go to the addon.
const MAX_SPOTS: usize = 40;

#[derive(Debug, Default)]
pub struct Generated {
    pub built: i64,
    pub events: i64,
    pub ingested: Vec<(String, i64)>,
    pub zones: Vec<Zone>,
    pub fish: Vec<Fish>,
    pub pools: Vec<Pool>,
}

#[derive(Debug, Default)]
pub struct Zone {
    pub map: i64,
    pub casts: i64,
    pub catches: i64,
    pub away: i64,
    /// The lowest "Requires Fishing N" the game gave anywhere in the zone.
    pub need: Option<i64>,
    /// The highest skill (with lures) at which a fish still got away.
    pub away_max: Option<i64>,
    /// Subzones that asked for a skill of their own.
    pub subzones: Vec<(String, i64)>,
}

#[derive(Debug, Default)]
pub struct Fish {
    pub item: i64,
    pub name: Option<String>,
    pub total: i64,
    pub zones: Vec<FishZone>,
}

#[derive(Debug, Default)]
pub struct FishZone {
    pub map: i64,
    pub qty: i64,
    /// Percent of the zone's open-water catches that held this item.
    pub share: Option<i64>,
    pub spots: Vec<Spot>,
}

/// Catches gathered into one map-percent cell: where, and how many.
#[derive(Debug, Clone, PartialEq)]
pub struct Spot {
    pub x: f64,
    pub y: f64,
    pub n: i64,
}

#[derive(Debug, Default)]
pub struct Pool {
    pub object: i64,
    pub name: Option<String>,
    pub catches: i64,
    pub items: Vec<(i64, i64)>,
    pub spots: Vec<(i64, Vec<Spot>)>,
}

fn names(conn: &Connection, kind: &str) -> Result<HashMap<i64, String>> {
    let mut stmt = conn.prepare("SELECT id, name FROM names WHERE kind = ?1")?;
    let rows = stmt.query_map([kind], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
    let mut out = HashMap::new();
    for row in rows {
        let (id, name) = row?;
        out.insert(id, name);
    }
    Ok(out)
}

pub fn build(conn: &Connection, built: i64) -> Result<Generated> {
    let mut out = Generated { built, ..Default::default() };
    out.events = conn.query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))?;
    let item_names = names(conn, "item")?;
    let object_names = names(conn, "object")?;

    // How far each install's journal has been stored: the addon drops those events.
    {
        let mut stmt = conn.prepare("SELECT install, MAX(seq) FROM events GROUP BY install ORDER BY install")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            out.ingested.push(row?);
        }
    }

    // Zones
    let mut subzones: HashMap<i64, Vec<(String, i64)>> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT map, subzone, MAX(need) FROM events
             WHERE kind = 'lowskill' AND map IS NOT NULL AND subzone IS NOT NULL AND need IS NOT NULL
             GROUP BY map, subzone ORDER BY map, subzone",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))?;
        for row in rows {
            let (map, subzone, need) = row?;
            subzones.entry(map).or_default().push((subzone, need));
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT map,
                SUM(kind = 'cast'), SUM(kind = 'catch'), SUM(kind = 'away'),
                MIN(CASE WHEN kind = 'lowskill' THEN need END),
                MAX(CASE WHEN kind = 'away' THEN skill + COALESCE(modifier, 0) END)
             FROM events WHERE map IS NOT NULL GROUP BY map ORDER BY map",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Zone {
                map: r.get(0)?,
                casts: r.get(1)?,
                catches: r.get(2)?,
                away: r.get(3)?,
                need: r.get(4)?,
                away_max: r.get(5)?,
                subzones: Vec::new(),
            })
        })?;
        for row in rows {
            let mut zone = row?;
            zone.subzones = subzones.remove(&zone.map).unwrap_or_default();
            out.zones.push(zone);
        }
    }

    // Fish: totals and shares per zone
    let mut open_total: HashMap<i64, i64> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT map, COUNT(*) FROM events
             WHERE kind = 'catch' AND map IS NOT NULL AND (source IS NULL OR source = ?1) GROUP BY map",
        )?;
        let rows = stmt.query_map([BOBBER], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            let (map, n) = row?;
            open_total.insert(map, n);
        }
    }
    let mut fish: BTreeMap<i64, Fish> = BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT c.item, e.map, SUM(c.qty),
                SUM(CASE WHEN e.source IS NULL OR e.source = ?1 THEN 1 ELSE 0 END)
             FROM catch_items c JOIN events e ON e.install = c.install AND e.seq = c.seq
             WHERE e.map IS NOT NULL GROUP BY c.item, e.map ORDER BY c.item, e.map",
        )?;
        let rows = stmt.query_map([BOBBER], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?))
        })?;
        for row in rows {
            let (item, map, qty, open) = row?;
            let entry = fish.entry(item).or_insert_with(|| Fish { item, name: item_names.get(&item).cloned(), ..Default::default() });
            entry.total += qty;
            let total = open_total.get(&map).copied().unwrap_or(0);
            let share = (total > 0 && open > 0).then(|| ((open as f64 / total as f64) * 100.0).round() as i64);
            entry.zones.push(FishZone { map, qty, share, spots: Vec::new() });
        }
    }
    // Fish: where they were caught, gathered into one-percent cells, busiest first
    {
        let mut stmt = conn.prepare(
            "SELECT c.item, e.map, AVG(e.x), AVG(e.y), COUNT(*) AS n
             FROM catch_items c JOIN events e ON e.install = c.install AND e.seq = c.seq
             WHERE e.map IS NOT NULL AND e.x IS NOT NULL AND e.y IS NOT NULL
             GROUP BY c.item, e.map, CAST(e.x AS INTEGER), CAST(e.y AS INTEGER)
             ORDER BY c.item, e.map, n DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, f64>(2)?, r.get::<_, f64>(3)?, r.get::<_, i64>(4)?))
        })?;
        for row in rows {
            let (item, map, x, y, n) = row?;
            let Some(zone) = fish.get_mut(&item).and_then(|f| f.zones.iter_mut().find(|z| z.map == map)) else { continue };
            if zone.spots.len() < MAX_SPOTS {
                zone.spots.push(Spot { x, y, n });
            }
        }
    }
    out.fish = fish.into_values().collect();

    // Pools: what came out of each and where it was seen
    let mut pools: BTreeMap<i64, Pool> = BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT source, COUNT(*) FROM events
             WHERE kind = 'catch' AND source IS NOT NULL AND source != ?1 GROUP BY source ORDER BY source",
        )?;
        let rows = stmt.query_map([BOBBER], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            let (object, catches) = row?;
            pools.insert(object, Pool { object, name: object_names.get(&object).cloned(), catches, ..Default::default() });
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT e.source, c.item, SUM(c.qty) AS n
             FROM catch_items c JOIN events e ON e.install = c.install AND e.seq = c.seq
             WHERE e.source IS NOT NULL AND e.source != ?1 GROUP BY e.source, c.item ORDER BY e.source, n DESC",
        )?;
        let rows = stmt.query_map([BOBBER], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))?;
        for row in rows {
            let (object, item, qty) = row?;
            if let Some(pool) = pools.get_mut(&object) {
                pool.items.push((item, qty));
            }
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT source, map, AVG(x), AVG(y), COUNT(*) AS n FROM events
             WHERE kind = 'catch' AND source IS NOT NULL AND source != ?1
                AND map IS NOT NULL AND x IS NOT NULL AND y IS NOT NULL
             GROUP BY source, map, CAST(x AS INTEGER), CAST(y AS INTEGER)
             ORDER BY source, map, n DESC",
        )?;
        let rows = stmt.query_map([BOBBER], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, f64>(2)?, r.get::<_, f64>(3)?, r.get::<_, i64>(4)?))
        })?;
        for row in rows {
            let (object, map, x, y, n) = row?;
            let Some(pool) = pools.get_mut(&object) else { continue };
            if pool.spots.last().map(|(m, _)| *m) != Some(map) {
                pool.spots.push((map, Vec::new()));
            }
            let spots = &mut pool.spots.last_mut().expect("just pushed").1;
            if spots.len() < MAX_SPOTS {
                spots.push(Spot { x, y, n });
            }
        }
    }
    out.pools = pools.into_values().collect();
    Ok(out)
}

fn lua_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn lua_spots(spots: &[Spot]) -> String {
    let parts: Vec<String> = spots.iter().map(|s| format!("{:.1}, {:.1}, {}", s.x, s.y, s.n)).collect();
    format!("{{ {} }}", parts.join(", "))
}

/// The addon's Generated.lua.
pub fn to_lua(g: &Generated) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "-- Written by creel {} (the TightLines log analyzer). Do not edit: run `creel sync` to rebuild it.", env!("CARGO_PKG_VERSION"));
    let _ = writeln!(s, "-- From {} journal events in creel's database.", g.events);
    s.push_str("local _, TL = ...\nTL.Generated = {\n  version = 1,\n");
    let _ = writeln!(s, "  built = {},", g.built);
    let _ = writeln!(s, "  events = {},", g.events);

    // Journal events up to these sequence numbers are stored; the addon drops them.
    s.push_str("  ingested = {\n");
    for (install, seq) in &g.ingested {
        let _ = writeln!(s, "    [{}] = {},", lua_string(install), seq);
    }
    s.push_str("  },\n");

    s.push_str("  zones = {\n");
    for z in &g.zones {
        let _ = write!(s, "    [{}] = {{ casts = {}, catches = {}, away = {}", z.map, z.casts, z.catches, z.away);
        if let Some(need) = z.need {
            let _ = write!(s, ", need = {need}");
        }
        if let Some(away_max) = z.away_max {
            let _ = write!(s, ", awayMax = {away_max}");
        }
        if !z.subzones.is_empty() {
            let parts: Vec<String> = z.subzones.iter().map(|(name, need)| format!("[{}] = {}", lua_string(name), need)).collect();
            let _ = write!(s, ", sub = {{ {} }}", parts.join(", "));
        }
        s.push_str(" },\n");
    }
    s.push_str("  },\n");

    s.push_str("  fish = {\n");
    for f in &g.fish {
        let _ = write!(s, "    [{}] = {{ ", f.item);
        if let Some(name) = &f.name {
            let _ = write!(s, "name = {}, ", lua_string(name));
        }
        let _ = writeln!(s, "n = {}, zones = {{", f.total);
        for z in &f.zones {
            let _ = write!(s, "      [{}] = {{ n = {}", z.map, z.qty);
            if let Some(share) = z.share {
                let _ = write!(s, ", share = {share}");
            }
            let _ = writeln!(s, ", spots = {} }},", lua_spots(&z.spots));
        }
        s.push_str("    } },\n");
    }
    s.push_str("  },\n");

    s.push_str("  pools = {\n");
    for p in &g.pools {
        let _ = write!(s, "    [{}] = {{ ", p.object);
        if let Some(name) = &p.name {
            let _ = write!(s, "name = {}, ", lua_string(name));
        }
        let items: Vec<String> = p.items.iter().map(|(item, qty)| format!("[{item}] = {qty}")).collect();
        let _ = writeln!(s, "n = {}, items = {{ {} }}, spots = {{", p.catches, items.join(", "));
        for (map, spots) in &p.spots {
            let _ = writeln!(s, "      [{}] = {},", map, lua_spots(spots));
        }
        s.push_str("    } },\n");
    }
    s.push_str("  },\n}\n");
    s
}

fn label(names: &HashMap<i64, String>, id: i64) -> String {
    match names.get(&id) {
        Some(name) => format!("{name} ({id})"),
        None => format!("#{id}"),
    }
}

/// What the logs say against what the guide says, for a person to read.
pub fn report(conn: &Connection) -> Result<String> {
    let mut s = String::new();
    let items = names(conn, "item")?;
    let maps = names(conn, "map")?;
    let objects = names(conn, "object")?;

    let _ = writeln!(s, "EVENTS");
    {
        let mut stmt = conn.prepare("SELECT kind, COUNT(*) FROM events GROUP BY kind ORDER BY COUNT(*) DESC")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        let mut any = false;
        for row in rows {
            let (kind, n) = row?;
            let _ = writeln!(s, "  {kind:<10} {n}");
            any = true;
        }
        if !any {
            let _ = writeln!(s, "  none yet: fish with TightLines enabled, log out, then run `creel sync`");
            return Ok(s);
        }
    }

    let g = build(conn, 0)?;

    let _ = writeln!(s, "\nZONES  (casts / catches / got away; skill measured against the guide)");
    {
        let mut stmt = conn.prepare("SELECT base_skill FROM guide_zones WHERE map = ?1")?;
        for z in &g.zones {
            let guide: Option<i64> = stmt.query_row([z.map], |r| r.get(0)).ok();
            let mut line = format!("  {:<28} {:>5} / {:>5} / {:>4}", label(&maps, z.map), z.casts, z.catches, z.away);
            match (z.need, guide) {
                (Some(need), Some(base)) if need != base.max(1) => {
                    let _ = write!(line, "   game asked for {need}, the guide says {}  <-- differs", base.max(1));
                }
                (Some(need), Some(_)) => {
                    let _ = write!(line, "   game asked for {need}, as the guide says");
                }
                (Some(need), None) => {
                    let _ = write!(line, "   game asked for {need}; the guide has no skill for this zone  <-- new");
                }
                (None, None) => line.push_str("   not in the guide; no skill message seen yet"),
                (None, Some(_)) => {}
            }
            if let Some(away_max) = z.away_max {
                let _ = write!(line, "   fish got away up to skill {away_max}");
            }
            let _ = writeln!(s, "{line}");
            for (subzone, need) in &z.subzones {
                let _ = writeln!(s, "      {subzone}: asked for {need}");
            }
        }
    }

    let _ = writeln!(s, "\nCATCHES THE GUIDE DOES NOT LIST");
    {
        let mut any = false;
        let mut in_guide = conn.prepare("SELECT 1 FROM guide_items WHERE item = ?1")?;
        for f in &g.fish {
            if in_guide.exists([f.item])? {
                continue;
            }
            let zones: Vec<String> = f.zones.iter().map(|z| format!("{} x{}", label(&maps, z.map), z.qty)).collect();
            let _ = writeln!(s, "  {:<34} {:>5}   {}", label(&items, f.item), f.total, zones.join(", "));
            any = true;
        }
        if !any {
            let _ = writeln!(s, "  none");
        }
    }

    let _ = writeln!(s, "\nOPEN-WATER CATCHES IN ZONES THE GUIDE DOES NOT GIVE FOR THAT FISH");
    {
        let mut stmt = conn.prepare(
            "SELECT c.item, e.map, SUM(c.qty) FROM catch_items c
             JOIN events e ON e.install = c.install AND e.seq = c.seq
             WHERE e.map IS NOT NULL AND (e.source IS NULL OR e.source = ?1)
               AND c.item IN (SELECT item FROM guide_items)
               AND NOT EXISTS (SELECT 1 FROM guide_fish g WHERE g.item = c.item AND g.map = e.map)
             GROUP BY c.item, e.map ORDER BY c.item, e.map",
        )?;
        let rows = stmt.query_map([BOBBER], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))?;
        let mut any = false;
        for row in rows {
            let (item, map, qty) = row?;
            let _ = writeln!(s, "  {:<34} in {:<28} x{qty}", label(&items, item), label(&maps, map));
            any = true;
        }
        if !any {
            let _ = writeln!(s, "  none");
        }
    }

    let _ = writeln!(s, "\nPOOLS  (what came out of each)");
    if g.pools.is_empty() {
        let _ = writeln!(s, "  none seen yet");
    }
    for p in &g.pools {
        let contents: Vec<String> = p.items.iter().map(|(item, qty)| format!("{} x{qty}", label(&items, *item))).collect();
        let _ = writeln!(s, "  {:<34} {:>4} catches   {}", label(&objects, p.object), p.catches, contents.join(", "));
    }

    let _ = writeln!(s, "\nHOURS  (server hours each catch was seen in, 5 catches or more)");
    {
        let mut stmt = conn.prepare(
            "SELECT c.item, e.hour, COUNT(*) FROM catch_items c
             JOIN events e ON e.install = c.install AND e.seq = c.seq
             WHERE e.hour IS NOT NULL GROUP BY c.item, e.hour ORDER BY c.item, e.hour",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))?;
        let mut by_item: BTreeMap<i64, Vec<(i64, i64)>> = BTreeMap::new();
        for row in rows {
            let (item, hour, n) = row?;
            by_item.entry(item).or_default().push((hour, n));
        }
        for (item, hours) in by_item {
            if hours.iter().map(|(_, n)| n).sum::<i64>() < 5 {
                continue;
            }
            let list: Vec<String> = hours.iter().map(|(hour, n)| format!("{hour:02}h x{n}")).collect();
            let _ = writeln!(s, "  {:<34} {}", label(&items, item), list.join("  "));
        }
    }

    let _ = writeln!(s, "\nERRORS INSIDE TIGHTLINES");
    {
        let mut stmt = conn.prepare(
            "SELECT text, COUNT(*), MAX(ts) FROM events WHERE kind = 'error' AND text IS NOT NULL
             GROUP BY text ORDER BY MAX(ts) DESC LIMIT 20",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        let mut any = false;
        for row in rows {
            let (text, n) = row?;
            let _ = writeln!(s, "  x{n}  {text}");
            any = true;
        }
        if !any {
            let _ = writeln!(s, "  none");
        }
    }
    Ok(s)
}

/// A unix time as "2026-11-14 19:02" (UTC).
fn date(ts: i64) -> String {
    let (days, secs) = (ts.div_euclid(86400), ts.rem_euclid(86400));
    // Days since 1970 to a civil date (Howard Hinnant's algorithm)
    let z = days + 719_468;
    let (era, doe) = (z.div_euclid(146_097), z.rem_euclid(146_097));
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}", secs / 3600, secs % 3600 / 60)
}

/// Stored trips, newest first.
pub fn trips(conn: &Connection, toon: Option<&str>, limit: usize) -> Result<String> {
    let maps = names(conn, "map")?;
    let mut s = String::new();
    let _ = writeln!(s, "{:<24} {:<17} {:>8} {:>6} {:>8} {:>5}  {}", "character", "started (UTC)", "minutes", "casts", "catches", "away", "zones");
    let mut zones = conn.prepare("SELECT map, catches FROM trip_zones WHERE install = ?1 AND toon = ?2 AND trip = ?3 ORDER BY catches DESC")?;
    let mut stmt = conn.prepare(
        "SELECT install, toon, trip, started, COALESCE(stopped, started), casts, catches, away FROM trips
         WHERE ?1 IS NULL OR toon LIKE '%' || ?1 || '%' ORDER BY started DESC LIMIT ?2",
    )?;
    let rows = stmt.query_map(rusqlite::params![toon, limit as i64], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, i64>(7)?,
        ))
    })?;
    let mut any = false;
    for row in rows {
        let (install, toon, trip, started, stopped, casts, catches, away) = row?;
        let zone_rows = zones.query_map(rusqlite::params![install, toon, trip], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?;
        let mut where_ = Vec::new();
        for z in zone_rows {
            let (map, n) = z?;
            where_.push(format!("{} x{n}", maps.get(&map).cloned().unwrap_or_else(|| format!("#{map}"))));
        }
        let minutes = ((stopped - started).max(60) as f64 / 60.0).round() as i64;
        let _ = writeln!(s, "{toon:<24} {:<17} {minutes:>8} {casts:>6} {catches:>8} {away:>5}  {}", date(started), where_.join(", "));
        any = true;
    }
    if !any {
        let _ = writeln!(s, "no trips stored yet");
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::fixture_db;

    #[test]
    fn builds_what_the_addon_reads() {
        let conn = fixture_db();
        let g = build(&conn, 1234).unwrap();
        assert_eq!(g.events, 9);
        assert_eq!(g.ingested, vec![("abc123".to_string(), 9)]);

        let feralas = g.zones.iter().find(|z| z.map == 1444).unwrap();
        assert_eq!((feralas.casts, feralas.catches, feralas.away), (3, 2, 1));
        assert_eq!(feralas.away_max, Some(305));
        assert_eq!(feralas.need, None);
        let riverglades = g.zones.iter().find(|z| z.map == 2548).unwrap();
        assert_eq!(riverglades.need, Some(180));
        assert_eq!(riverglades.subzones, vec![("Glimmer Shoals".to_string(), 180)]);

        let redgill = g.fish.iter().find(|f| f.item == 13758).unwrap();
        assert_eq!(redgill.total, 1);
        assert_eq!(redgill.zones[0].share, Some(100)); // the only open-water catch
        assert_eq!(redgill.zones[0].spots, vec![Spot { x: 31.2, y: 43.5, n: 1 }]);
        let eel = g.fish.iter().find(|f| f.item == 13422).unwrap();
        assert_eq!(eel.total, 2);
        assert_eq!(eel.zones[0].share, None); // it came from a pool

        assert_eq!(g.pools.len(), 1);
        assert_eq!(g.pools[0].object, 180712);
        assert_eq!(g.pools[0].items, vec![(13422, 2), (99001, 1)]);
        assert_eq!(g.pools[0].spots[0].0, 1444);

        let lua = to_lua(&g);
        assert!(lua.contains("built = 1234,"));
        assert!(lua.contains("[\"abc123\"] = 9,"));
        assert!(lua.contains("[2548] = { casts = 0, catches = 0, away = 0, need = 180, sub = { [\"Glimmer Shoals\"] = 180 } },"));
        assert!(lua.contains("name = \"Forever \\\"Glimmerfin\\\"\""));
        assert!(lua.contains("[1444] = { n = 1, share = 100, spots = { 31.2, 43.5, 1 } },"));
    }

    #[test]
    fn reports_what_the_guide_lacks() {
        let conn = fixture_db();
        let text = report(&conn).unwrap();
        assert!(text.contains("Forever \"Glimmerfin\" (99001)"), "{text}");
        assert!(text.contains("the guide has no skill for this zone"), "{text}");
        assert!(text.contains("Stonescale Eel Swarm (180712)"), "{text}");
        let trips = trips(&conn, Some("Tester"), 10).unwrap();
        assert!(trips.contains("Tester-Realm"), "{trips}");
        assert!(trips.contains("Feralas x2"), "{trips}");
        assert!(trips.contains("1970-01-01 00:01"), "{trips}");
        assert_eq!(date(1_794_000_000), "2026-11-06 21:20");
    }
}
