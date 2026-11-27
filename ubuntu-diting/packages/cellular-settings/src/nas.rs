//! How the modem asks the network for service. Its NAS "system selection
//! preference" has the usage (voice-centric or data-centric) and the service
//! domain (CS and PS, or PS only); the two are the EPS "UE mode of operation".
//!
//! `diting-nas-pref`, from the device package, sends them to the modem over
//! QMI and, after setting them, reads them back until the modem agrees. It
//! needs no privilege, and what it reads is the modem's. It is used where it
//! is. Otherwise there is ModemManager's `SetEpsUeModeOperation`, which on
//! this modem answered "successfully set" twice while the modem had not
//! changed (2026-11-26): the fallback, and not what the Status page shows
//! where the tool is.

use std::path::Path;
use std::process::Command;

use crate::modemmode::{eps, ServiceDomain, Usage};

pub const TOOL: &str = "/usr/lib/diting/diting-nas-pref";

pub fn available() -> bool {
	Path::new(TOOL).is_file()
}

/// What the modem reports. `None` where it reports none.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Preference {
	pub usage: Option<Usage>,
	pub service_domain: Option<ServiceDomain>,
}

impl Preference {
	/// The EPS "UE mode of operation" these two are; None for any other pair.
	pub fn ue_mode(self) -> Option<u32> {
		self.usage.zip(self.service_domain).and_then(|(usage, domain)| eps::mode(usage, domain))
	}
}

fn run(arguments: &[&str]) -> Result<String, String> {
	let output = Command::new(TOOL)
		.args(arguments)
		.output()
		.map_err(|error| format!("{TOOL}: {error}"))?;
	let said = String::from_utf8_lossy(&output.stdout).trim().to_string();
	let complained = String::from_utf8_lossy(&output.stderr).trim().to_string();
	if output.status.success() {
		Ok(said)
	} else {
		Err(if complained.is_empty() { said } else { complained })
	}
}

/// Ask the modem. A process with a QMI client of its own: a moment, not nothing.
pub fn read() -> Result<Preference, String> {
	let text = run(&[])?;
	let field = |name: &str| {
		text.lines().find_map(|line| line.strip_prefix(name)).map(|value| value.trim().to_string())
	};
	let usage = field("usage:").ok_or_else(|| format!("{}: no usage in its answer", TOOL))?;
	let service_domain = field("service-domain:").ok_or_else(|| format!("{}: no service domain in its answer", TOOL))?;
	Ok(Preference {
		usage: usage.strip_suffix("-centric").and_then(|word| Usage::from_token(word)),
		service_domain: ServiceDomain::from_token(&service_domain),
	})
}

/// Apply, and wait for the modem: the tool reads the preference back until
/// it is what was asked for, and fails if it never is (six seconds, thirty at
/// the most).
pub fn apply(usage: Usage, service_domain: ServiceDomain) -> Result<(), String> {
	run(&[&format!("usage={}", usage.token()), &format!("service-domain={}", service_domain.token())]).map(|_| ())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_tool_s_answer_is_read() {
		// what it prints with no argument: the three fields
		let text = "usage: data-centric\nvoice-domain: cs-preferred\nservice-domain: ps-only\n";
		let run = |text: &str| {
			let field = |name: &str| {
				text.lines().find_map(|line| line.strip_prefix(name)).map(|value| value.trim().to_string())
			};
			Preference {
				usage: field("usage:").unwrap().strip_suffix("-centric").and_then(Usage::from_token),
				service_domain: ServiceDomain::from_token(&field("service-domain:").unwrap()),
			}
		};
		assert_eq!(run(text).ue_mode(), Some(eps::PS_2));
		assert_eq!(run("usage: voice-centric\nvoice-domain: cs-preferred\nservice-domain: cs-ps\n").ue_mode(), Some(eps::CSPS_1));
		assert_eq!(run("usage: unknown\nvoice-domain: unknown\nservice-domain: unknown\n").ue_mode(), None);
	}
}
