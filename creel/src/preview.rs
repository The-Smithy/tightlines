//! `creel preview`: the addon's window in a web browser, without the game.
//!
//! The page (preview/index.html) asks for a render; each render runs LuaJIT on
//! preview/host.lua, which loads the addon's real files against a model of the
//! game's UI and prints what would be on screen. The page polls `/stamp` and
//! renders again when a file of the addon or the preview changes.

use anyhow::{Result, anyhow};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;
use tiny_http::{Header, Method, Response, Server};

pub struct Preview {
    /// The project folder: `preview/` is in it.
    pub project: PathBuf,
    /// The addon's source folder.
    pub addon: PathBuf,
    /// The game folder (for LibForeverData and EllesmereUI's font, when installed).
    pub wow: PathBuf,
    /// The addon's SavedVariables file, when the game has written one.
    pub saved: Option<PathBuf>,
}

fn modified(path: &Path) -> u128 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// The newest change to any file in a folder (and its subfolders).
fn newest(dir: &Path) -> u128 {
    let mut best = 0;
    let Ok(entries) = std::fs::read_dir(dir) else { return best };
    for entry in entries.flatten() {
        let path = entry.path();
        best = best.max(if path.is_dir() { newest(&path) } else { modified(&path) });
    }
    best
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push(' '),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn error_json(message: &str) -> String {
    format!("{{\"error\":{}}}", json_string(message))
}

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("a valid header")
}

impl Preview {
    fn host(&self) -> PathBuf {
        self.project.join("preview").join("host.lua")
    }

    fn page(&self) -> PathBuf {
        self.project.join("preview").join("index.html")
    }

    /// "<addon and host stamp> <page stamp>": the page renders again when the
    /// first changes and reloads itself when the second does.
    fn stamp(&self) -> String {
        format!("{} {}", newest(&self.addon).max(modified(&self.host())), modified(&self.page()))
    }

    /// One render: the request (options and the actions to replay) in, JSON out.
    fn render(&self, body: &str) -> String {
        let request = std::env::temp_dir().join(format!("creel-preview-{}.json", std::process::id()));
        if let Err(err) = std::fs::write(&request, body) {
            return error_json(&format!("could not write {}: {err}", request.display()));
        }
        let game_addons = self.wow.join("Interface").join("AddOns");
        let dash = PathBuf::from("-");
        let output = Command::new("luajit")
            .arg(self.host())
            .arg(&self.addon)
            .arg(if game_addons.is_dir() { &game_addons } else { &dash })
            .arg(&request)
            .arg(self.saved.as_ref().unwrap_or(&dash))
            .output();
        match output {
            Err(err) => error_json(&format!("could not run luajit ({err}). The preview needs LuaJIT on the PATH.")),
            Ok(out) => {
                let text = String::from_utf8_lossy(&out.stdout);
                if out.status.success() && text.trim_start().starts_with('{') {
                    text.into_owned()
                } else {
                    error_json(&format!("{}\n{}", String::from_utf8_lossy(&out.stderr), text))
                }
            }
        }
    }

    /// EllesmereUI's default font from the installed addon, for its look.
    fn eui_font(&self) -> Option<Vec<u8>> {
        let fonts = self.wow.join("Interface").join("AddOns").join("EllesmereUI").join("media").join("fonts");
        std::fs::read(fonts.join("Expressway.TTF")).or_else(|_| std::fs::read(fonts.join("Expressway.ttf"))).ok()
    }

    pub fn serve(&self, port: u16, open: bool) -> Result<()> {
        if !self.host().is_file() || !self.page().is_file() {
            return Err(anyhow!("{} has no preview folder (host.lua and index.html)", self.project.display()));
        }
        let server = Server::http(("127.0.0.1", port)).map_err(|err| anyhow!("could not listen on port {port}: {err}"))?;
        let url = format!("http://127.0.0.1:{port}/");
        println!("TightLines preview at {url}");
        println!("  addon   {}", self.addon.display());
        println!("  It renders again when a file there changes. Ctrl+C stops it.");
        if open {
            let _ = Command::new("cmd").args(["/C", "start", "", &url]).spawn();
        }
        for mut request in server.incoming_requests() {
            let path = request.url().split('?').next().unwrap_or("/").to_string();
            let result = match (request.method(), path.as_str()) {
                (Method::Get, "/") => match std::fs::read(self.page()) {
                    Ok(page) => request.respond(
                        Response::from_data(page)
                            .with_header(header("Content-Type", "text/html; charset=utf-8"))
                            .with_header(header("Cache-Control", "no-store")),
                    ),
                    Err(err) => request.respond(Response::from_string(err.to_string()).with_status_code(500)),
                },
                (Method::Get, "/stamp") => {
                    request.respond(Response::from_string(self.stamp()).with_header(header("Cache-Control", "no-store")))
                }
                (Method::Post, "/render") => {
                    let mut body = String::new();
                    let _ = request.as_reader().read_to_string(&mut body);
                    request.respond(
                        Response::from_string(self.render(&body))
                            .with_header(header("Content-Type", "application/json; charset=utf-8"))
                            .with_header(header("Cache-Control", "no-store")),
                    )
                }
                (Method::Get, "/font/eui") => match self.eui_font() {
                    Some(font) => request.respond(Response::from_data(font).with_header(header("Content-Type", "font/ttf"))),
                    None => request.respond(Response::from_string("no EllesmereUI font").with_status_code(404)),
                },
                _ => request.respond(Response::from_string("not found").with_status_code(404)),
            };
            if let Err(err) = result {
                eprintln!("preview: {err}");
            }
        }
        Ok(())
    }
}
