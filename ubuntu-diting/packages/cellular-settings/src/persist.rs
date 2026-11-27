//! `/etc/diting/modem-mode`, the file `diting-modem-setup` reads at every
//! boot. Reading it needs no privilege; writing it needs root, and that goes
//! through pkexec and the helper of the package, which checks what it is
//! given: the file is sourced as shell code, by root, once a minute.
//!
//! Only a phone with `diting-modem-setup` has the file; elsewhere the page
//! does without the "next boot" part.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

pub const FILE: &str = "/etc/diting/modem-mode";
pub const HELPER: &str = "/usr/libexec/cellular-settings-write-modem-mode";
/// the program that reads the file: without it there is nothing to save for
const SETUP: &str = "/usr/lib/diting/diting-modem-setup";

pub fn available() -> bool {
	Path::new(SETUP).is_file() && Path::new(HELPER).is_file()
}

/// The file as it is; None when there is none.
pub fn read() -> Result<Option<String>, String> {
	match std::fs::read_to_string(FILE) {
		Ok(text) => Ok(Some(text)),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
		Err(error) => Err(error.to_string()),
	}
}

/// Run the helper as root through pkexec, the new file on its standard input.
/// polkit lets the desktop session do so without a password; over SSH it is
/// refused, and that answer is passed on.
fn pkexec(arguments: &[&str], input: Option<&str>) -> Result<(), String> {
	let mut command = Command::new("pkexec");
	command.arg(HELPER).args(arguments).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
	let mut child = command.spawn().map_err(|error| format!("pkexec: {error}"))?;
	// The file is a few lines: it fits in the pipe, and the helper reads all
	// of it before it answers.
	if let Some(text) = input {
		if let Some(mut stdin) = child.stdin.take() {
			let bytes = text.as_bytes().to_vec();
			std::thread::spawn(move || {
				let _ = stdin.write_all(&bytes);
			});
		}
	}
	let output = child.wait_with_output().map_err(|error| format!("pkexec: {error}"))?;
	if output.status.success() {
		Ok(())
	} else {
		let said = String::from_utf8_lossy(&output.stderr).trim().to_string();
		let said = if said.is_empty() { String::from_utf8_lossy(&output.stdout).trim().to_string() } else { said };
		Err(match output.status.code() {
			// the convention of pkexec: the authorization was refused
			Some(127) if said.is_empty() => "pkexec: not authorized".to_string(),
			_ if said.is_empty() => format!("pkexec: exited with {}", output.status),
			_ => said,
		})
	}
}

/// Write the file. `text` is what `ModemMode::to_text` writes.
pub fn write(text: &str) -> Result<(), String> {
	pkexec(&[], Some(text))
}

/// Remove the file; nothing saved is the modem's own defaults at boot.
pub fn forget() -> Result<(), String> {
	pkexec(&["--delete"], None)
}
