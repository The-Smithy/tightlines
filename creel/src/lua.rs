//! A reader for the Lua the game writes into SavedVariables files: global names
//! assigned literals (tables, strings, numbers, booleans, nil). It is not a Lua
//! interpreter; anything else in the file is an error.

use anyhow::{Result, bail};

#[derive(Debug, Clone, PartialEq)]
pub enum Key {
    Int(i64),
    Str(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Nil,
    Bool(bool),
    Num(f64),
    Str(String),
    Table(Table),
}

impl Value {
    pub fn as_table(&self) -> Option<&Table> {
        match self {
            Value::Table(t) => Some(t),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|n| n as i64)
    }

    pub fn is_true(&self) -> bool {
        matches!(self, Value::Bool(true))
    }
}

/// A Lua table, in file order. Positional values get the keys 1, 2, 3...
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Table {
    pub entries: Vec<(Key, Value)>,
}

impl Table {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| matches!(k, Key::Str(s) if s == key)).map(|(_, v)| v)
    }

    pub fn table(&self, key: &str) -> Option<&Table> {
        self.get(key).and_then(Value::as_table)
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Value::as_str)
    }

    pub fn int(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(Value::as_i64)
    }

    /// The values at keys 1, 2, 3... up to the first gap.
    pub fn array(&self) -> Vec<&Value> {
        let mut ints: Vec<(i64, &Value)> = self
            .entries
            .iter()
            .filter_map(|(k, v)| match k {
                Key::Int(i) => Some((*i, v)),
                Key::Str(_) => None,
            })
            .collect();
        ints.sort_by_key(|(i, _)| *i);
        let mut out = Vec::new();
        for (i, v) in ints {
            if i == out.len() as i64 + 1 {
                out.push(v);
            } else if i > out.len() as i64 + 1 {
                break;
            }
        }
        out
    }

    /// Every entry with an integer key, such as `[13758] = 4`.
    pub fn int_entries(&self) -> impl Iterator<Item = (i64, &Value)> {
        self.entries.iter().filter_map(|(k, v)| match k {
            Key::Int(i) => Some((*i, v)),
            Key::Str(_) => None,
        })
    }

    /// Every entry with a string key.
    pub fn str_entries(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().filter_map(|(k, v)| match k {
            Key::Str(s) => Some((s.as_str(), v)),
            Key::Int(_) => None,
        })
    }
}

/// Parses a SavedVariables file into its global assignments, in file order.
pub fn parse(text: &str) -> Result<Vec<(String, Value)>> {
    let mut p = Parser { src: text.as_bytes(), pos: 0 };
    let mut globals = Vec::new();
    loop {
        p.skip_space();
        if p.pos >= p.src.len() {
            break;
        }
        let name = match p.name() {
            Some(name) => name,
            None => bail!("line {}: expected a variable name", p.line()),
        };
        p.skip_space();
        p.expect(b'=')?;
        let value = p.value()?;
        p.skip_space();
        if p.peek() == Some(b';') {
            p.pos += 1;
        }
        globals.push((name, value));
    }
    Ok(globals)
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn line(&self) -> usize {
        self.src[..self.pos.min(self.src.len())].iter().filter(|b| **b == b'\n').count() + 1
    }

    fn starts_with(&self, s: &[u8]) -> bool {
        self.src[self.pos..].starts_with(s)
    }

    /// Skips whitespace and comments (the game writes `-- [1]` after array values).
    fn skip_space(&mut self) {
        loop {
            while matches!(self.peek(), Some(b) if b.is_ascii_whitespace()) {
                self.pos += 1;
            }
            if self.starts_with(b"--[[") {
                self.pos += 4;
                while self.pos < self.src.len() && !self.starts_with(b"]]") {
                    self.pos += 1;
                }
                self.pos = (self.pos + 2).min(self.src.len());
            } else if self.starts_with(b"--") {
                while matches!(self.peek(), Some(b) if b != b'\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn expect(&mut self, byte: u8) -> Result<()> {
        if self.peek() == Some(byte) {
            self.pos += 1;
            Ok(())
        } else {
            bail!("line {}: expected '{}'", self.line(), byte as char)
        }
    }

    fn name(&mut self) -> Option<String> {
        let start = self.pos;
        match self.peek() {
            Some(b) if b.is_ascii_alphabetic() || b == b'_' => {}
            _ => return None,
        }
        while matches!(self.peek(), Some(b) if b.is_ascii_alphanumeric() || b == b'_') {
            self.pos += 1;
        }
        Some(String::from_utf8_lossy(&self.src[start..self.pos]).into_owned())
    }

    fn value(&mut self) -> Result<Value> {
        self.skip_space();
        match self.peek() {
            Some(b'{') => Ok(Value::Table(self.table()?)),
            Some(b'"') | Some(b'\'') => Ok(Value::Str(self.string()?)),
            Some(b) if b.is_ascii_digit() || b == b'-' || b == b'.' => self.number(),
            Some(_) => {
                let line = self.line();
                match self.name().as_deref() {
                    Some("true") => Ok(Value::Bool(true)),
                    Some("false") => Ok(Value::Bool(false)),
                    Some("nil") => Ok(Value::Nil),
                    Some("inf") => Ok(Value::Num(f64::INFINITY)),
                    Some("nan") => Ok(Value::Num(f64::NAN)),
                    Some(other) => bail!("line {line}: unexpected word '{other}'"),
                    None => bail!("line {line}: expected a value"),
                }
            }
            None => bail!("unexpected end of file"),
        }
    }

    fn table(&mut self) -> Result<Table> {
        self.expect(b'{')?;
        let mut table = Table::default();
        let mut next = 1i64;
        loop {
            self.skip_space();
            match self.peek() {
                None => bail!("unexpected end of file inside a table"),
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                Some(b'[') => {
                    self.pos += 1;
                    let line = self.line();
                    let key = match self.value()? {
                        Value::Str(s) => Key::Str(s),
                        Value::Num(n) if n.fract() == 0.0 => Key::Int(n as i64),
                        Value::Num(n) => Key::Str(n.to_string()),
                        _ => bail!("line {line}: a table key must be a string or a number"),
                    };
                    self.skip_space();
                    self.expect(b']')?;
                    self.skip_space();
                    self.expect(b'=')?;
                    let value = self.value()?;
                    table.entries.push((key, value));
                }
                Some(_) => {
                    // `name = value`, or a positional value
                    let start = self.pos;
                    let mut keyed = None;
                    if let Some(name) = self.name() {
                        self.skip_space();
                        if self.peek() == Some(b'=') && self.src.get(self.pos + 1) != Some(&b'=') {
                            self.pos += 1;
                            keyed = Some(name);
                        }
                    }
                    if let Some(name) = keyed {
                        let value = self.value()?;
                        table.entries.push((Key::Str(name), value));
                    } else {
                        self.pos = start;
                        let value = self.value()?;
                        table.entries.push((Key::Int(next), value));
                        next += 1;
                    }
                }
            }
            self.skip_space();
            if matches!(self.peek(), Some(b',') | Some(b';')) {
                self.pos += 1;
            }
        }
        Ok(table)
    }

    fn string(&mut self) -> Result<String> {
        let quote = self.src[self.pos];
        let line = self.line();
        self.pos += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let Some(b) = self.peek() else { bail!("line {line}: unterminated string") };
            self.pos += 1;
            if b == quote {
                break;
            }
            if b != b'\\' {
                out.push(b);
                continue;
            }
            let Some(e) = self.peek() else { bail!("line {line}: unterminated string") };
            self.pos += 1;
            match e {
                b'n' => out.push(b'\n'),
                b'r' => out.push(b'\r'),
                b't' => out.push(b'\t'),
                b'a' => out.push(7),
                b'b' => out.push(8),
                b'f' => out.push(12),
                b'v' => out.push(11),
                b'0'..=b'9' => {
                    // \ddd: up to three decimal digits
                    let mut n = (e - b'0') as u32;
                    for _ in 0..2 {
                        match self.peek() {
                            Some(d) if d.is_ascii_digit() => {
                                n = n * 10 + (d - b'0') as u32;
                                self.pos += 1;
                            }
                            _ => break,
                        }
                    }
                    out.push(n.min(255) as u8);
                }
                other => out.push(other), // \\ \" \' and an escaped newline
            }
        }
        Ok(String::from_utf8_lossy(&out).into_owned())
    }

    fn number(&mut self) -> Result<Value> {
        let start = self.pos;
        let line = self.line();
        if self.peek() == Some(b'-') {
            self.pos += 1;
            // -inf, -nan(ind)
            if matches!(self.peek(), Some(b) if b.is_ascii_alphabetic()) {
                let word = self.name().unwrap_or_default();
                if self.peek() == Some(b'(') {
                    while matches!(self.peek(), Some(b) if b != b')') {
                        self.pos += 1;
                    }
                    self.pos = (self.pos + 1).min(self.src.len());
                }
                return match word.as_str() {
                    "inf" => Ok(Value::Num(f64::NEG_INFINITY)),
                    "nan" => Ok(Value::Num(f64::NAN)),
                    _ => bail!("line {line}: bad number"),
                };
            }
        }
        if self.starts_with(b"0x") || self.starts_with(b"0X") {
            self.pos += 2;
            let digits = self.pos;
            while matches!(self.peek(), Some(b) if b.is_ascii_hexdigit()) {
                self.pos += 1;
            }
            let text = std::str::from_utf8(&self.src[digits..self.pos]).unwrap_or("");
            let n = i64::from_str_radix(text, 16).map_err(|_| anyhow::anyhow!("line {line}: bad hex number"))?;
            let sign = if self.src[start] == b'-' { -1.0 } else { 1.0 };
            return Ok(Value::Num(sign * n as f64));
        }
        while matches!(self.peek(), Some(b) if b.is_ascii_digit() || b == b'.') {
            self.pos += 1;
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(b) if b.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let text = std::str::from_utf8(&self.src[start..self.pos]).unwrap_or("");
        match text.parse::<f64>() {
            Ok(n) => Ok(Value::Num(n)),
            Err(_) => bail!("line {line}: bad number '{text}'"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_the_game_writes() {
        let text = r#"
TightLinesDB = {
	["scale"] = 1,
	["journal"] = {
		["seq"] = 3,
		["events"] = {
			"s=1^e=cast^ts=10", -- [1]
			"s=2^e=catch^ts=20^sz=Bay \"of\" Storms", -- [2]
		},
		["names"] = {
			["i"] = {
				[13758] = "Raw Redgill",
			},
		},
	},
	["minimap"] = {
		["hide"] = false,
		["angle"] = -135.5,
	},
}
Other = nil
"#;
        let globals = parse(text).unwrap();
        assert_eq!(globals.len(), 2);
        assert_eq!(globals[0].0, "TightLinesDB");
        let db = globals[0].1.as_table().unwrap();
        assert_eq!(db.int("scale"), Some(1));
        let journal = db.table("journal").unwrap();
        let events = journal.table("events").unwrap().array();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].as_str(), Some("s=2^e=catch^ts=20^sz=Bay \"of\" Storms"));
        let names: Vec<_> = journal.table("names").unwrap().table("i").unwrap().int_entries().collect();
        assert_eq!(names[0].0, 13758);
        assert_eq!(names[0].1.as_str(), Some("Raw Redgill"));
        let minimap = db.table("minimap").unwrap();
        assert_eq!(minimap.get("hide"), Some(&Value::Bool(false)));
        assert_eq!(minimap.get("angle").and_then(Value::as_f64), Some(-135.5));
        assert_eq!(globals[1].1, Value::Nil);
    }

    #[test]
    fn reads_bare_names_and_mixed_tables() {
        let globals = parse("T = { a = 1, 'two', [3] = true, 4e2, x = { }, }").unwrap();
        let t = globals[0].1.as_table().unwrap();
        assert_eq!(t.int("a"), Some(1));
        assert_eq!(t.array().len(), 3); // 'two', 4e2 and the explicit [3]
        assert_eq!(t.array()[1].as_f64(), Some(400.0));
        assert!(t.table("x").unwrap().entries.is_empty());
    }

    #[test]
    fn reports_the_line_of_a_mistake() {
        let err = parse("A = 1\nB = {\n  oops\n}").unwrap_err().to_string();
        assert!(err.contains("line 3"), "{err}");
    }
}
