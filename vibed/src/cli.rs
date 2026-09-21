use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use serde_json::json;

fn usage() -> ! {
    eprintln!("usage: vibed-cli push <prompt> | vibed-cli status");
    std::process::exit(2)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let msg = match args.len() {
        2 if args[1] == "status" => json!({"op":"status"}),
        3 if args[1] == "push" => json!({"op":"push","prompt":args[2]}),
        _ => usage(),
    };
    let path = std::env::var("VIBED_SOCK").unwrap_or_else(|_| "/run/vibed.sock".to_string());
    let mut stream = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("vibed-cli: connect {path}: {e}");
            std::process::exit(1)
        }
    };
    let line = serde_json::to_string(&msg).expect("serialise");
    if let Err(e) = stream
        .write_all(line.as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .and_then(|_| stream.flush())
    {
        eprintln!("vibed-cli: write: {e}");
        std::process::exit(1)
    }
    // Half-close: the daemon replies, sees EOF and closes, so we see EOF too.
    let _ = stream.shutdown(std::net::Shutdown::Write);
    for l in BufReader::new(stream).lines() {
        match l {
            Ok(l) => println!("{l}"),
            Err(_) => break,
        }
    }
}
