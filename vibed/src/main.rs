use std::fs::{File, Permissions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

const BACKOFF_START: u64 = 5;
const BACKOFF_MAX: u64 = 300;
const CLEAN_RESET: u64 = 3600;
const LINE_CAP: u64 = 64 << 20;

/// Child stdio and the single serialised ACP channel.
struct Acp {
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    next_id: u64,
    session_id: Option<String>,
}

/// Shared daemon state: the live ACP channel (None while the child is down)
/// and the respawn count.
struct Shared {
    acp: Option<Acp>,
    restarts: u64,
}

fn fatal(msg: &str) -> ! {
    eprintln!("vibed: {msg}");
    std::process::exit(1)
}

fn session_state_path() -> PathBuf {
    std::env::var("VIBED_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/lib/vibed/session_id"))
}

fn load_saved_id() -> Option<String> {
    std::fs::read_to_string(session_state_path())
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Atomic persist: write `<file>.tmp`, then rename over `<file>`.
fn persist_session_id(id: &str) {
    let path = session_state_path();
    if let Some(dir) = path.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("vibed: create_dir_all {}: {e}", dir.display());
            return;
        }
    }
    let tmp = PathBuf::from(format!("{}.tmp", path.display()));
    if let Err(e) = std::fs::write(&tmp, id) {
        eprintln!("vibed: write {}: {e}", tmp.display());
        return;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        eprintln!("vibed: rename {} -> {}: {e}", tmp.display(), path.display());
    }
}

impl Acp {
    fn from_child(child: &mut Child) -> Acp {
        let stdin = child.stdin.take().expect("stdin");
        let out = BufReader::new(child.stdout.take().expect("stdout"));
        Acp {
            stdin,
            out,
            next_id: 1,
            session_id: None,
        }
    }

    fn try_write(&mut self, v: &Value, io_dead: &AtomicBool) -> Result<(), String> {
        let line = v.to_string();
        if let Err(e) = writeln!(self.stdin, "{line}").and_then(|_| self.stdin.flush()) {
            io_dead.store(true, Ordering::SeqCst);
            return Err(format!("acp write failed: {e}"));
        }
        Ok(())
    }

    /// Read one line, capped at LINE_CAP bytes. Overflow, EOF and I/O errors
    /// are fatal for this child: flagged via `io_dead` for the supervisor.
    fn read_msg(&mut self, io_dead: &AtomicBool) -> Result<Value, String> {
        loop {
            let mut buf = Vec::new();
            let mut limited = self.out.by_ref().take(LINE_CAP + 1);
            let n = match limited.read_until(b'\n', &mut buf) {
                Ok(n) => n,
                Err(e) => {
                    io_dead.store(true, Ordering::SeqCst);
                    return Err(format!("acp read failed: {e}"));
                }
            };
            if n == 0 {
                io_dead.store(true, Ordering::SeqCst);
                return Err("acp child closed stdout".to_string());
            }
            if buf.len() as u64 > LINE_CAP {
                io_dead.store(true, Ordering::SeqCst);
                return Err("acp line exceeds 64 MiB cap".to_string());
            }
            match serde_json::from_slice::<Value>(&buf) {
                Ok(v) => return Ok(v),
                Err(_) => eprintln!("vibed: acp non-json line ({n} bytes) discarded"),
            }
        }
    }

    // One call in flight at a time (the Mutex guarantees this).
    fn call(&mut self, method: &str, params: Value, io_dead: &AtomicBool) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.try_write(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}), io_dead)?;
        loop {
            let msg = self.read_msg(io_dead)?;
            if let (Some(method), Some(rid)) = (msg.get("method"), msg.get("id").cloned()) {
                let method = method.as_str().unwrap_or("?");
                let bytes = msg.to_string().len();
                eprintln!("vibed: acp request method={method} id={rid} bytes={bytes}");
                // Server-to-client request: refuse and keep reading.
                self.try_write(
                    &json!({"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"MethodNotFound"}}),
                    io_dead,
                )?;
                continue;
            }
            if let Some(method) = msg.get("method") {
                let method = method.as_str().unwrap_or("?");
                let bytes = msg.to_string().len();
                eprintln!("vibed: acp notification method={method} bytes={bytes}");
                continue; // Notification: discard.
            }
            match msg.get("id") {
                Some(rid) if *rid == json!(id) => {
                    if let Some(err) = msg.get("error") {
                        let m = err.get("message").and_then(|m| m.as_str()).unwrap_or("unknown error");
                        return Err(m.to_string());
                    }
                    return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
                }
                _ => continue, // Response with an unexpected id: discard.
            }
        }
    }
}

/// Handshake a freshly spawned child: initialize (with the STOCK GAP check),
/// then session/load from the saved id, falling back to session/new.
fn handshake(acp: &mut Acp, io_dead: &AtomicBool) -> Result<(), String> {
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}},
        "clientInfo": {"name": "vibed", "version": "0.1.0"}
    });
    let res = acp.call("initialize", init, io_dead)?;
    let caps = res.get("agentCapabilities").cloned();
    let loads = caps
        .as_ref()
        .and_then(|c| c.get("loadSession"))
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    if !loads {
        let raw = caps.unwrap_or_else(|| res.clone());
        eprintln!("STOCK GAP: initialize result does not advertise agentCapabilities.loadSession=true; raw capability object: {raw}");
        std::process::exit(1);
    }
    if let Some(saved) = load_saved_id() {
        eprintln!("vibed: saved session id found, trying session/load");
        let cwd = std::env::var("VIBED_WORKDIR").unwrap_or_else(|_| "/root".to_string());
        match acp.call(
            "session/load",
            json!({"sessionId": saved, "cwd": cwd, "mcpServers": []}),
            io_dead,
        ) {
            Ok(res) => {
                // Stock LoadSessionResponse carries no sessionId field (ACP
                // protocol: a loaded session keeps its id). Prefer an echoed
                // sessionId if present, else the id we sent.
                if let Some(s) = res.get("sessionId").and_then(|s| s.as_str()) {
                    acp.session_id = Some(s.to_string());
                    persist_session_id(s);
                } else {
                    acp.session_id = Some(saved.clone());
                    persist_session_id(&saved);
                }
                eprintln!("vibed: session/load ok");
                return Ok(());
            }
            Err(e) => eprintln!("vibed: session/load failed: {e}; falling back to session/new"),
        }
    }
    let cwd = std::env::var("VIBED_WORKDIR").unwrap_or_else(|_| "/root".to_string());
    let res = acp.call("session/new", json!({"cwd": cwd, "mcpServers": []}), io_dead)?;
    match res.get("sessionId").and_then(|s| s.as_str()) {
        Some(s) => {
            acp.session_id = Some(s.to_string());
            persist_session_id(s);
            eprintln!("vibed: session/new ok");
            Ok(())
        }
        None => Err("session/new: no sessionId in result".to_string()),
    }
}

/// Supervisor: owns the child lifecycle. spawn -> handshake -> serve until the
/// child exits, stdout EOFs or ACP I/O fails; then teardown, backoff, respawn.
fn supervise(state: Arc<Mutex<Shared>>, io_dead: Arc<AtomicBool>) {
    let mut backoff = BACKOFF_START;
    loop {
        io_dead.store(false, Ordering::SeqCst);
        let mut child = match Command::new("vibe-acp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => fatal(&format!("spawn vibe-acp: {e}")),
        };
        eprintln!("vibed: spawned vibe-acp (pid {})", child.id());
        let mut acp = Acp::from_child(&mut child);
        if let Err(e) = handshake(&mut acp, &io_dead) {
            eprintln!("vibed: handshake failed: {e}");
            let _ = child.kill();
            let _ = child.wait();
            state.lock().unwrap_or_else(|p| p.into_inner()).restarts += 1;
            eprintln!("vibed: vibe-acp respawn in {backoff}s");
            std::thread::sleep(Duration::from_secs(backoff));
            backoff = (backoff * 2).min(BACKOFF_MAX);
            continue;
        }
        state.lock().unwrap_or_else(|p| p.into_inner()).acp = Some(acp);
        eprintln!("vibed: session ready");
        let up_since = Instant::now();
        let reason = loop {
            std::thread::sleep(Duration::from_millis(200));
            if io_dead.load(Ordering::SeqCst) {
                break "acp i/o failure".to_string();
            }
            match child.try_wait() {
                Ok(Some(status)) => break format!("vibe-acp exited: {status}"),
                Ok(None) => {}
                Err(e) => break format!("vibe-acp wait failed: {e}"),
            }
            if up_since.elapsed() >= Duration::from_secs(CLEAN_RESET) {
                backoff = BACKOFF_START;
            }
        };
        eprintln!("vibed: {reason}");
        // Teardown child state: drop the pipes, make sure the process is gone.
        {
            let mut sh = state.lock().unwrap_or_else(|p| p.into_inner());
            sh.acp = None;
            sh.restarts += 1;
        }
        let _ = child.kill();
        let _ = child.wait();
        eprintln!("vibed: vibe-acp respawn in {backoff}s");
        std::thread::sleep(Duration::from_secs(backoff));
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

fn dispatch(state: &Arc<Mutex<Shared>>, io_dead: &AtomicBool, v: Value) -> Value {
    match v.get("op").and_then(|o| o.as_str()) {
        Some("status") => {
            let sh = state.lock().unwrap_or_else(|p| p.into_inner());
            let session = sh.acp.as_ref().and_then(|a| a.session_id.clone());
            json!({"ok":true,"up":sh.acp.is_some(),"session":session,"restarts":sh.restarts})
        }
        Some("push") => {
            let Some(text) = v.get("prompt").and_then(|p| p.as_str()) else {
                return json!({"ok":false,"error":"missing prompt"});
            };
            let mut sh = state.lock().unwrap_or_else(|p| p.into_inner());
            let Some(acp) = sh.acp.as_mut() else {
                return json!({"ok":false,"error":"session not ready (child restarting)"});
            };
            let Some(sid) = acp.session_id.clone() else {
                return json!({"ok":false,"error":"session not ready (child restarting)"});
            };
            let params = json!({"sessionId":sid,"prompt":[{"type":"text","text":text}]});
            match acp.call("session/prompt", params, io_dead) {
                // Any completed session/prompt response is ok; stopReason passes
                // through regardless of value.
                Ok(res) => json!({"ok":true,"stopReason":res.get("stopReason").cloned().unwrap_or(Value::Null)}),
                Err(e) => json!({"ok":false,"error":e}),
            }
        }
        _ => json!({"ok":false,"error":"unknown op"}),
    }
}

/// Read one line capped at LINE_CAP bytes; None on EOF, Some on data.
/// Overflow is reported as an error.
fn read_line_capped<R: BufRead>(r: &mut R) -> std::io::Result<Option<Vec<u8>>> {
    let mut buf = Vec::new();
    let mut limited = r.by_ref().take(LINE_CAP + 1);
    let n = limited.read_until(b'\n', &mut buf)?;
    if n == 0 {
        return Ok(None);
    }
    if buf.len() as u64 > LINE_CAP {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "line exceeds 64 MiB cap",
        ));
    }
    Ok(Some(buf))
}

fn handle_conn(state: &Arc<Mutex<Shared>>, io_dead: &AtomicBool, stream: UnixStream) {
    let mut reader = match stream.try_clone() {
        Ok(r) => BufReader::new(r),
        Err(_) => return,
    };
    let mut writer = stream;
    loop {
        let line = match read_line_capped(&mut reader) {
            Ok(Some(l)) => l,
            Ok(None) => break,
            Err(_) => break,
        };
        let trimmed = String::from_utf8_lossy(&line);
        let trimmed = trimmed.trim();
        if trimmed.is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(trimmed) {
            Ok(v) => dispatch(state, io_dead, v),
            Err(_) => json!({"ok":false,"error":"bad json"}),
        };
        let mut out = reply.to_string().into_bytes();
        out.push(b'\n');
        if writer.write_all(&out).is_err() {
            break;
        }
        let _ = writer.flush();
    }
}

fn main() {
    // flock split-brain guard, held for the daemon's lifetime, taken before
    // any child is spawned.
    let lock_path =
        std::env::var("VIBED_LOCK").unwrap_or_else(|_| "/run/vibed.lock".to_string());
    let lock = match File::create(&lock_path) {
        Ok(f) => f,
        Err(e) => fatal(&format!("open {lock_path}: {e}")),
    };
    let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        eprintln!("vibed: another vibed holds {lock_path}");
        std::process::exit(1)
    }

    let sock = std::env::var("VIBED_SOCK").unwrap_or_else(|_| "/run/vibed.sock".to_string());
    let _ = std::fs::remove_file(&sock);
    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => fatal(&format!("bind {sock}: {e}")),
    };
    if let Err(e) = std::fs::set_permissions(&sock, Permissions::from_mode(0o600)) {
        eprintln!("vibed: chmod {sock} 0600: {e}");
    }
    eprintln!("vibed listening on {sock}");

    let io_dead = Arc::new(AtomicBool::new(false));
    let state = Arc::new(Mutex::new(Shared {
        acp: None,
        restarts: 0,
    }));
    {
        let st = Arc::clone(&state);
        let d = Arc::clone(&io_dead);
        std::thread::spawn(move || supervise(st, d));
    }
    for stream in listener.incoming() {
        if let Ok(s) = stream {
            let st = Arc::clone(&state);
            let d = Arc::clone(&io_dead);
            std::thread::spawn(move || handle_conn(&st, &d, s));
        }
    }
}
