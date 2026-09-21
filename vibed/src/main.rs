use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

/// Child stdio and the single serialised ACP channel.
struct Acp {
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    next_id: u64,
    session_id: Option<String>,
}

fn fatal(msg: &str) -> ! {
    eprintln!("vibed: {msg}");
    std::process::exit(1)
}

impl Acp {
    fn spawn() -> Acp {
        let mut child = Command::new("vibe-acp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap_or_else(|e| fatal(&format!("spawn vibe-acp: {e}")));
        let pid = child.id();
        let stdin = child.stdin.take().expect("stdin");
        let out = BufReader::new(child.stdout.take().expect("stdout"));
        eprintln!("vibed: spawned vibe-acp (pid {pid})");
        // Watcher: exits the daemon the moment the child dies.
        std::thread::spawn(move || match child.wait() {
            Ok(status) => fatal(&format!("vibe-acp exited: {status}")),
            Err(e) => fatal(&format!("vibe-acp wait failed: {e}")),
        });
        Acp {
            stdin,
            out,
            next_id: 1,
            session_id: None,
        }
    }

    fn write_msg(&mut self, v: &Value) {
        let line = v.to_string();
        if let Err(e) = writeln!(self.stdin, "{line}").and_then(|_| self.stdin.flush()) {
            fatal(&format!("acp write failed: {e}"));
        }
    }

    fn read_msg(&mut self) -> Value {
        loop {
            let mut line = String::new();
            match self.out.read_line(&mut line) {
                Ok(0) => fatal("acp child closed stdout"),
                Ok(_) => {}
                Err(e) => fatal(&format!("acp read failed: {e}")),
            }
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                return v;
            }
        }
    }

    // One call in flight at a time (the Mutex guarantees this).
    fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.write_msg(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}));
        loop {
            let msg = self.read_msg();
            if let (Some(_), Some(rid)) = (msg.get("method"), msg.get("id").cloned()) {
                // Server-to-client request: refuse and keep reading.
                self.write_msg(&json!({"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"MethodNotFound"}}));
                continue;
            }
            if msg.get("method").is_some() {
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

fn dispatch(state: &Arc<Mutex<Acp>>, v: Value) -> Value {
    match v.get("op").and_then(|o| o.as_str()) {
        Some("status") => {
            let acp = state.lock().unwrap_or_else(|p| p.into_inner());
            json!({"ok":true,"session":acp.session_id})
        }
        Some("push") => {
            let Some(text) = v.get("prompt").and_then(|p| p.as_str()) else {
                return json!({"ok":false,"error":"missing prompt"});
            };
            let mut acp = state.lock().unwrap_or_else(|p| p.into_inner());
            let Some(sid) = acp.session_id.clone() else {
                return json!({"ok":false,"error":"no session"});
            };
            let params = json!({"sessionId":sid,"prompt":[{"type":"text","text":text}]});
            match acp.call("session/prompt", params) {
                Ok(res) => json!({"ok":true,"stopReason":res.get("stopReason").cloned().unwrap_or(Value::Null)}),
                Err(e) => json!({"ok":false,"error":e}),
            }
        }
        _ => json!({"ok":false,"error":"unknown op"}),
    }
}

fn handle_conn(state: &Arc<Mutex<Acp>>, stream: UnixStream) {
    let mut reader = match stream.try_clone() {
        Ok(r) => BufReader::new(r),
        Err(_) => return,
    };
    let mut writer = stream;
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(trimmed) {
            Ok(v) => dispatch(state, v),
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
    let mut acp = Acp::spawn();
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}},
        "clientInfo": {"name": "vibed", "version": "0.1.0"}
    });
    if let Err(e) = acp.call("initialize", init) {
        fatal(&format!("initialize failed: {e}"));
    }
    match acp.call("session/new", json!({"cwd":"/root","mcpServers":[]})) {
        Ok(res) => match res.get("sessionId").and_then(|s| s.as_str()) {
            Some(s) => acp.session_id = Some(s.to_string()),
            None => fatal("session/new: no sessionId in result"),
        },
        Err(e) => fatal(&format!("session/new failed: {e}")),
    }
    let sock = std::env::var("VIBED_SOCK").unwrap_or_else(|_| "/run/vibed.sock".to_string());
    let _ = std::fs::remove_file(&sock);
    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => fatal(&format!("bind {sock}: {e}")),
    };
    eprintln!("vibed listening on {sock}");
    let state = Arc::new(Mutex::new(acp));
    for stream in listener.incoming() {
        if let Ok(s) = stream {
            let st = Arc::clone(&state);
            let _ = std::thread::spawn(move || handle_conn(&st, s));
        }
    }
}
