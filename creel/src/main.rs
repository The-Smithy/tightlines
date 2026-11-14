//! creel: the tool side of TightLines.
//!
//! The project folder holds the addon's source (`addon/TightLines`) and this
//! tool. The game folder is only where the addon is installed to and where
//! the game writes the addon's SavedVariables file. creel
//!   - reads the fishing journal out of that SavedVariables file into a
//!     SQLite database (`ingest`),
//!   - writes the addon's `Generated.lua` from everything stored (`build`),
//!   - copies the addon into the game (`install`).

mod analyze;
mod lua;
mod preview;
mod store;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(name = "creel", version, about = "Stores TightLines' fishing journal in SQLite, builds the addon's Generated.lua and installs the addon")]
struct Cli {
    /// The game folder that holds WTF and Interface
    #[arg(long, global = true, env = "CREEL_WOW", default_value = r"C:\Program Files (x86)\World of Warcraft\_forever_")]
    wow: PathBuf,

    /// The database file [default: %LOCALAPPDATA%\creel\creel.db]
    #[arg(long, global = true, env = "CREEL_DB")]
    db: Option<PathBuf>,

    /// The addon's source folder [default: addon\TightLines beside this tool's source]
    #[arg(long, global = true, env = "CREEL_ADDON")]
    addon: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Read the journals, then rebuild Generated.lua (what running creel alone does)
    Sync,
    /// Read every account's TightLines journal into the database
    Ingest {
        /// Read this SavedVariables file instead of looking under the game folder
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// Write Generated.lua from the database
    Build {
        /// Write only this file, instead of the addon source and the installed copy
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Copy the addon from the project folder into the game
    Install,
    /// Show the addon's window in a web browser, re-rendered whenever a file changes
    Preview {
        #[arg(long, default_value_t = 7878)]
        port: u16,
        /// Don't open the browser
        #[arg(long)]
        no_open: bool,
    },
    /// Compare what the logs say with what the guide says
    Report,
    /// List stored fishing trips, newest first
    Trips {
        /// Only characters whose name contains this
        #[arg(long)]
        character: Option<String>,
        #[arg(long, default_value_t = 30)]
        limit: usize,
    },
    /// Show the folders and files creel uses
    Paths,
}

fn default_db() -> PathBuf {
    match std::env::var_os("LOCALAPPDATA") {
        Some(dir) => PathBuf::from(dir).join("creel").join("creel.db"),
        None => PathBuf::from("creel.db"),
    }
}

/// The addon source in the project folder this tool was built from.
fn default_addon() -> PathBuf {
    let tool = Path::new(env!("CARGO_MANIFEST_DIR"));
    tool.parent().unwrap_or(tool).join("addon").join("TightLines")
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn ingest(conn: &mut rusqlite::Connection, wow: &Path, file: Option<&Path>) -> Result<()> {
    let files = match file {
        Some(file) => vec![("file".to_string(), file.to_path_buf())],
        None => store::find_saved_variables(wow),
    };
    if files.is_empty() {
        println!("No TightLines.lua found under {}.", wow.join("WTF").join("Account").display());
        println!("Log in with TightLines enabled, fish, then log out (the game writes the file on logout or /reload).");
        return Ok(());
    }
    for (account, path) in files {
        match store::ingest_file(conn, &account, &path) {
            Ok(result) => match result.note {
                Some(note) => println!("{account}: {note}"),
                None => println!(
                    "{account}: {} new events of {} in the file, {} trips",
                    result.events_new, result.events_in_file, result.trips
                ),
            },
            // One unreadable file must not stop the others
            Err(err) => println!("{account}: could not read it: {err:#}"),
        }
    }
    Ok(())
}

/// Writes beside the target and renames, so the game never reads half a file.
fn write_file(path: &Path, text: &str) -> Result<()> {
    let temp = path.with_extension("lua.tmp");
    std::fs::write(&temp, text).with_context(|| format!("writing {}", temp.display()))?;
    std::fs::rename(&temp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// Writes Generated.lua to each of `targets` whose folder exists.
fn build(conn: &rusqlite::Connection, targets: &[PathBuf]) -> Result<()> {
    let generated = analyze::build(conn, now())?;
    let text = analyze::to_lua(&generated);
    let mut written = 0;
    for target in targets {
        let dir = target.parent().unwrap_or(Path::new("."));
        if !dir.as_os_str().is_empty() && !dir.is_dir() {
            continue;
        }
        write_file(target, &text)?;
        println!("Wrote {}", target.display());
        written += 1;
    }
    if written == 0 {
        bail!("nowhere to write Generated.lua: {} does not exist (--addon says where the addon source is)", targets[0].parent().unwrap_or(Path::new(".")).display());
    }
    println!(
        "{} events, {} zones, {} kinds of catch, {} pools.",
        generated.events,
        generated.zones.len(),
        generated.fish.len(),
        generated.pools.len()
    );
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> Result<usize> {
    std::fs::create_dir_all(to).with_context(|| format!("creating {}", to.display()))?;
    let mut copied = 0;
    for entry in std::fs::read_dir(from).with_context(|| format!("reading {}", from.display()))? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copied += copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target).with_context(|| format!("copying to {}", target.display()))?;
            copied += 1;
        }
    }
    Ok(copied)
}

/// Copies the addon source into the game, and removes addon files there that
/// the source no longer has.
fn install(source: &Path, installed: &Path) -> Result<()> {
    if !source.join("TightLines.toc").is_file() {
        bail!("{} is not the addon source (no TightLines.toc there)", source.display());
    }
    let addons = installed.parent().unwrap_or(installed);
    if !addons.is_dir() {
        bail!("{} does not exist: is --wow the game folder?", addons.display());
    }
    let copied = copy_dir(source, installed)?;
    let mut removed = 0;
    for entry in std::fs::read_dir(installed)?.flatten() {
        let path = entry.path();
        let stale = matches!(path.extension().and_then(|e| e.to_str()), Some("lua" | "toc" | "xml"))
            && !source.join(entry.file_name()).exists();
        if stale && std::fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    println!("Installed {copied} files to {}{}.", installed.display(), if removed > 0 { format!(" ({removed} old removed)") } else { String::new() });
    println!("In the game: /reload to pick up changed files; restart the game if files were added.");
    Ok(())
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let db_path = cli.db.clone().unwrap_or_else(default_db);
    let source = cli.addon.clone().unwrap_or_else(default_addon);
    let installed = cli.wow.join("Interface").join("AddOns").join("TightLines");
    // Generated.lua goes to the source, and to the installed copy when there is one
    let mut generated = vec![source.join("Generated.lua")];
    if installed != source {
        generated.push(installed.join("Generated.lua"));
    }

    match cli.command {
        Some(Command::Paths) => {
            println!("addon source  {}", source.display());
            println!("installed to  {}{}", installed.display(), if installed.is_dir() { "" } else { "  (not installed)" });
            println!("game folder   {}", cli.wow.display());
            println!("database      {}", db_path.display());
            for (account, path) in store::find_saved_variables(&cli.wow) {
                println!("journal       {} ({account})", path.display());
            }
            return Ok(());
        }
        Some(Command::Install) => return install(&source, &installed),
        Some(Command::Preview { port, no_open }) => {
            let tool = Path::new(env!("CARGO_MANIFEST_DIR"));
            let preview = preview::Preview {
                project: tool.parent().unwrap_or(tool).to_path_buf(),
                addon: source,
                saved: store::find_saved_variables(&cli.wow).into_iter().next().map(|(_, path)| path),
                wow: cli.wow,
            };
            return preview.serve(port, !no_open);
        }
        _ => {}
    }

    let mut conn = store::open(&db_path)?;
    match cli.command.unwrap_or(Command::Sync) {
        Command::Sync => {
            ingest(&mut conn, &cli.wow, None)?;
            build(&conn, &generated)?;
            println!("The addon reads Generated.lua at the next login or /reload.");
        }
        Command::Ingest { file } => ingest(&mut conn, &cli.wow, file.as_deref())?,
        Command::Build { out } => build(&conn, &out.map(|o| vec![o]).unwrap_or(generated))?,
        Command::Report => print!("{}", analyze::report(&conn)?),
        Command::Trips { character, limit } => print!("{}", analyze::trips(&conn, character.as_deref(), limit)?),
        Command::Install | Command::Paths | Command::Preview { .. } => {}
    }
    Ok(())
}
