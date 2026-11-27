//! `/etc/diting/modem-mode`: what `diting-modem-setup` reads at every boot, and
//! what it applies. The file names the technologies the modem may use, the
//! preferred one, and the NAS usage and service domain, in the words of that
//! script. Its vocabulary is the law here: a value the script does not know is
//! silently replaced by a default, so nothing else may be written.

use crate::t;

/// A radio access technology: the word of the file (`2g` to `5g`) and the bit
/// of ModemManager's `MMModemMode` (2G is 1 << 1; 1 << 0 is CS).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rat {
	G2,
	G3,
	G4,
	G5,
}

impl Rat {
	pub const ALL: [Rat; 4] = [Rat::G2, Rat::G3, Rat::G4, Rat::G5];

	pub fn token(self) -> &'static str {
		match self {
			Rat::G2 => "2g",
			Rat::G3 => "3g",
			Rat::G4 => "4g",
			Rat::G5 => "5g",
		}
	}

	pub fn name(self) -> &'static str {
		match self {
			Rat::G2 => "2G",
			Rat::G3 => "3G",
			Rat::G4 => "4G",
			Rat::G5 => "5G",
		}
	}

	pub fn bit(self) -> u32 {
		1 << (self as u32 + 1)
	}

	pub fn from_bit(bit: u32) -> Option<Rat> {
		Self::ALL.into_iter().find(|rat| rat.bit() == bit)
	}

	pub fn from_token(token: &str) -> Option<Rat> {
		Self::ALL.into_iter().find(|rat| rat.token() == token)
	}
}

/// The file's word for a mask of `Rat::bit()`: every known technology of it,
/// in the order 2G, 3G, 4G, 5G.
pub fn tokens(mask: u32) -> String {
	Rat::ALL
		.iter()
		.filter(|rat| mask & rat.bit() != 0)
		.map(|rat| rat.token())
		.collect::<Vec<_>>()
		.join("|")
}

/// The "UE's usage setting" of 3GPP TS 24.301, as the word of the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Usage {
	Voice,
	Data,
}

impl Usage {
	pub fn token(self) -> &'static str {
		match self {
			Usage::Voice => "voice",
			Usage::Data => "data",
		}
	}

	pub fn from_token(token: &str) -> Option<Usage> {
		match token {
			"voice" => Some(Usage::Voice),
			"data" => Some(Usage::Data),
			_ => None,
		}
	}
}

/// The NAS service domain preference, as the word of the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServiceDomain {
	CsOnly,
	PsOnly,
	CsPs,
	PsAttach,
	PsDetach,
}

impl ServiceDomain {
	pub fn token(self) -> &'static str {
		match self {
			ServiceDomain::CsOnly => "cs-only",
			ServiceDomain::PsOnly => "ps-only",
			ServiceDomain::CsPs => "cs-ps",
			ServiceDomain::PsAttach => "cs-attach",
			ServiceDomain::PsDetach => "ps-detach",
		}
	}

	pub fn from_token(token: &str) -> Option<ServiceDomain> {
		match token {
			"cs-only" => Some(ServiceDomain::CsOnly),
			"ps-only" => Some(ServiceDomain::PsOnly),
			"cs-ps" => Some(ServiceDomain::CsPs),
			"cs-attach" => Some(ServiceDomain::PsAttach),
			"ps-detach" => Some(ServiceDomain::PsDetach),
			_ => None,
		}
	}
}

/// What the file says. `None` is the modem's own default: the line is left out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModemMode {
	pub allowed: Vec<Rat>,
	pub preferred: Option<Rat>,
	pub usage: Option<Usage>,
	pub service_domain: Option<ServiceDomain>,
}

impl Default for ModemMode {
	/// What `diting-modem-setup` falls back to without a file: every
	/// technology, none preferred, the modem's own usage and domain.
	fn default() -> Self {
		Self {
			allowed: Rat::ALL.to_vec(),
			preferred: None,
			usage: None,
			service_domain: None,
		}
	}
}

impl ModemMode {
	/// The file, in the only words `diting-modem-setup` reads.
	pub fn to_text(&self) -> String {
		let mut text = String::from(
			"# /etc/diting/modem-mode: read by diting-modem-setup at every boot.\n\
			# Written by Cellular Settings. Keep to key=\"value\" lines.\n",
		);
		text.push_str(&format!(
			"allowed=\"{}\"\n",
			self.allowed.iter().map(|rat| rat.token()).collect::<Vec<_>>().join("|")
		));
		if let Some(preferred) = self.preferred {
			text.push_str(&format!("preferred=\"{}\"\n", preferred.token()));
		}
		if let Some(usage) = self.usage {
			text.push_str(&format!("usage=\"{}\"\n", usage.token()));
		}
		if let Some(domain) = self.service_domain {
			text.push_str(&format!("service_domain=\"{}\"\n", domain.token()));
		}
		text
	}

	/// What `diting-modem-setup` makes of a file. It sources the file as shell
	/// code; this reads the `key="value"` lines only, as a file written by this
	/// program or by hand in the documented form has them. The last assignment
	/// of a variable wins, and a value outside the vocabulary falls back to
	/// what the script falls back to.
	pub fn parse(text: &str) -> ModemMode {
		let mut allowed: Option<String> = None;
		let mut preferred: Option<String> = None;
		let mut usage: Option<String> = None;
		let mut service_domain: Option<String> = None;
		for line in text.lines() {
			let line = line.trim();
			for (key, slot) in [
				("allowed", &mut allowed),
				("preferred", &mut preferred),
				("usage", &mut usage),
				("service_domain", &mut service_domain),
			] {
				if let Some(value) = line.strip_prefix(key).and_then(assign_value) {
					*slot = Some(value);
				}
			}
		}
		// the script: a technology it does not know resets `allowed` to all;
		// an empty value is passed on as it is
		let allowed = match allowed {
			Some(text) => {
				let words: Vec<&str> = text.split('|').filter(|word| !word.is_empty()).collect();
				if words.iter().all(|word| Rat::from_token(word).is_some()) {
					words.iter().filter_map(|word| Rat::from_token(word)).collect()
				} else {
					Rat::ALL.to_vec()
				}
			}
			None => Rat::ALL.to_vec(),
		};
		// the script: a preferred technology is kept only as a word of `allowed`
		let preferred = preferred.and_then(|word| {
			let words = format!("|{}|", tokens(allowed.iter().fold(0, |mask, rat| mask | rat.bit())));
			words.contains(&format!("|{word}|"))
				.then(|| Rat::from_token(&word))
				.flatten()
		});
		ModemMode {
			allowed,
			preferred,
			usage: usage.and_then(|word| Usage::from_token(&word)),
			service_domain: service_domain.and_then(|word| ServiceDomain::from_token(&word)),
		}
	}

	/// The mask of the technologies allowed.
	pub fn mask(&self) -> u32 {
		self.allowed.iter().fold(0, |mask, rat| mask | rat.bit())
	}
}

/// The rest of a `key=value` line after the key, without the quotes; None for
/// anything that is not one plain word in double or single quotes.
fn assign_value(rest: &str) -> Option<String> {
	let rest = rest.trim_start();
	let rest = rest.strip_prefix('=')?.trim_start();
	let (quote, rest) = match rest.chars().next()? {
		'"' => ('"', &rest[1..]),
		'\'' => ('\'', &rest[1..]),
		_ => return None,
	};
	let end = rest.find(quote)?;
	let value = &rest[..end];
	(rest[end + 1..].trim().is_empty() && !value.contains(['\\', '$', '`'])).then(|| value.to_string())
}

/// The EPS "UE mode of operation", as ModemManager numbers it: what
/// `SetEpsUeModeOperation` takes and the `EpsUeModeOperation` property gives.
/// Each is a usage setting and a service domain.
pub mod eps {
	use super::{ServiceDomain, Usage};

	pub const PS_1: u32 = 1;
	pub const PS_2: u32 = 2;
	pub const CSPS_1: u32 = 3;
	pub const CSPS_2: u32 = 4;
	pub const KNOWN: [u32; 4] = [PS_1, PS_2, CSPS_1, CSPS_2];

	pub fn usage(mode: u32) -> Option<Usage> {
		match mode {
			PS_1 | CSPS_1 => Some(Usage::Voice),
			PS_2 | CSPS_2 => Some(Usage::Data),
			_ => None,
		}
	}

	pub fn service_domain(mode: u32) -> Option<ServiceDomain> {
		match mode {
			PS_1 | PS_2 => Some(ServiceDomain::PsOnly),
			CSPS_1 | CSPS_2 => Some(ServiceDomain::CsPs),
			_ => None,
		}
	}

	/// The mode for a usage and a domain; None for any other pair.
	pub fn mode(usage: Usage, service_domain: ServiceDomain) -> Option<u32> {
		match (usage, service_domain) {
			(Usage::Voice, ServiceDomain::PsOnly) => Some(PS_1),
			(Usage::Data, ServiceDomain::PsOnly) => Some(PS_2),
			(Usage::Voice, ServiceDomain::CsPs) => Some(CSPS_1),
			(Usage::Data, ServiceDomain::CsPs) => Some(CSPS_2),
			_ => None,
		}
	}
}

/// One network mode offered in the list: the technologies allowed, and the
/// preferred one among them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preset {
	pub allowed: u32,
	pub preferred: Option<Rat>,
}

const fn mask(rats: &[Rat]) -> u32 {
	let mut mask = 0;
	let mut i = 0;
	while i < rats.len() {
		mask |= 1 << (rats[i] as u32 + 1);
		i += 1;
	}
	mask
}

/// The list the Network page offers: what GNOME Settings lists, and the 4G and
/// 5G pairs it leaves out. A pair with each of its technologies preferred,
/// then with none.
pub const PRESETS: [Preset; 19] = [
	Preset { allowed: mask(&Rat::ALL), preferred: Some(Rat::G5) },
	Preset { allowed: mask(&Rat::ALL), preferred: Some(Rat::G4) },
	Preset { allowed: mask(&Rat::ALL), preferred: None },
	Preset { allowed: mask(&[Rat::G3, Rat::G4, Rat::G5]), preferred: Some(Rat::G5) },
	Preset { allowed: mask(&[Rat::G3, Rat::G4, Rat::G5]), preferred: Some(Rat::G4) },
	Preset { allowed: mask(&[Rat::G3, Rat::G4, Rat::G5]), preferred: None },
	Preset { allowed: mask(&[Rat::G4, Rat::G5]), preferred: Some(Rat::G5) },
	Preset { allowed: mask(&[Rat::G4, Rat::G5]), preferred: Some(Rat::G4) },
	Preset { allowed: mask(&[Rat::G4, Rat::G5]), preferred: None },
	Preset { allowed: mask(&[Rat::G2, Rat::G3, Rat::G4]), preferred: Some(Rat::G4) },
	Preset { allowed: mask(&[Rat::G2, Rat::G3, Rat::G4]), preferred: None },
	Preset { allowed: mask(&[Rat::G3, Rat::G4]), preferred: Some(Rat::G4) },
	Preset { allowed: mask(&[Rat::G3, Rat::G4]), preferred: None },
	Preset { allowed: mask(&[Rat::G2, Rat::G3]), preferred: Some(Rat::G3) },
	Preset { allowed: mask(&[Rat::G2, Rat::G3]), preferred: None },
	Preset { allowed: mask(&[Rat::G5]), preferred: None },
	Preset { allowed: mask(&[Rat::G4]), preferred: None },
	Preset { allowed: mask(&[Rat::G3]), preferred: None },
	Preset { allowed: mask(&[Rat::G2]), preferred: None },
];

impl Preset {
	/// The preset of a current mode of the modem: the same technologies and
	/// the same preferred one; failing that, the same technologies with
	/// another preferred one; failing that, with none.
	pub fn index_of(allowed: u32, preferred: u32) -> Option<usize> {
		let preferred = Rat::from_bit(preferred);
		let same: Vec<usize> = PRESETS
			.iter()
			.enumerate()
			.filter(|(_, preset)| preset.allowed == allowed)
			.map(|(index, _)| index)
			.collect();
		same.iter()
			.copied()
			.find(|index| PRESETS[*index].preferred == preferred)
			.or_else(|| same.first().copied())
	}
}

/// "3G, 4G (Preferred), 5G" for the technologies a mask allows.
pub fn mode_label(allowed: u32, preferred: u32) -> String {
	let rats: Vec<Rat> = Rat::ALL.into_iter().filter(|rat| allowed & rat.bit() != 0).collect();
	if rats.is_empty() {
		return t!("None");
	}
	let preferred = Rat::from_bit(preferred);
	if rats.len() == 1 && preferred == Some(rats[0]) {
		return t!("{} Only", rats[0].name());
	}
	rats.iter()
		.map(|rat| {
			if Some(*rat) == preferred {
				t!("{} (Preferred)", rat.name())
			} else {
				rat.name().to_string()
			}
		})
		.collect::<Vec<_>>()
		.join(", ")
}

#[cfg(test)]
mod tests {
	use super::*;

	const ALL: u32 = 2 | 4 | 8 | 16;

	#[test]
	fn bits_are_those_of_modemmanager() {
		assert_eq!(Rat::G2.bit(), 1 << 1);
		assert_eq!(Rat::G5.bit(), 1 << 4);
		assert_eq!([Rat::G3, Rat::G4, Rat::G5].iter().fold(0, |mask, rat| mask | rat.bit()), 4 | 8 | 16);
		assert_eq!(tokens(ALL), "2g|3g|4g|5g");
		assert_eq!(tokens(16 | 8), "4g|5g");
	}

	#[test]
	fn the_file_is_what_diting_modem_setup_reads() {
		let mode = ModemMode {
			allowed: vec![Rat::G3, Rat::G4, Rat::G5],
			preferred: Some(Rat::G5),
			usage: Some(Usage::Data),
			service_domain: Some(ServiceDomain::PsOnly),
		};
		let text = mode.to_text();
		for line in ["allowed=\"3g|4g|5g\"", "preferred=\"5g\"", "usage=\"data\"", "service_domain=\"ps-only\""] {
			assert!(text.lines().any(|l| l == line), "{text}");
		}
		// every line but the comments is one of the four assignments in double quotes
		assert!(text.lines().filter(|l| !l.starts_with('#')).all(|l| {
			["allowed=", "preferred=", "usage=", "service_domain="].iter().any(|k| l.starts_with(k))
				&& l.ends_with('"')
				&& !l.contains(' ')
		}));
		assert_eq!(ModemMode::parse(&text), mode);
	}

	#[test]
	fn a_hand_written_file_reads_as_the_script_reads_it() {
		// the form the documentation gives
		let mode = ModemMode::parse("allowed=\"3g|4g|5g\"\npreferred=\"5g\"\nusage=\"data\"\nservice_domain=\"ps-only\"\n");
		assert_eq!(mode.mask(), 4 | 8 | 16);
		assert_eq!(mode.preferred, Some(Rat::G5));
		assert_eq!(mode.usage, Some(Usage::Data));
		assert_eq!(mode.service_domain, Some(ServiceDomain::PsOnly));
		// a value the script does not know resets `allowed` to all, which has 5G
		let mode = ModemMode::parse("allowed=\"3g|6g\"\npreferred=\"5g\"\n");
		assert_eq!(mode.allowed, Rat::ALL.to_vec());
		assert_eq!(mode.preferred, Some(Rat::G5));
		// a word that is no technology is dropped
		let mode = ModemMode::parse("allowed=\"4g\"\npreferred=\"6g\"\n");
		assert_eq!(mode.preferred, None);
		assert_eq!(mode.allowed, vec![Rat::G4]);
		// a preferred technology that is not allowed is dropped
		let mode = ModemMode::parse("allowed=\"4g\"\npreferred=\"5g\"\nusage=\"data\"\n");
		assert_eq!(mode.preferred, None);
		assert_eq!(mode.usage, Some(Usage::Data));
		// the last assignment wins
		let mode = ModemMode::parse("allowed=\"4g\"\nallowed=\"5g\"\n");
		assert_eq!(mode.allowed, vec![Rat::G5]);
		// a comment and an empty file are the defaults
		assert_eq!(ModemMode::parse("# nothing\n"), ModemMode::default());
		assert_eq!(ModemMode::parse(""), ModemMode::default());
	}

	#[test]
	fn eps_modes_are_usage_and_domain() {
		for mode in eps::KNOWN {
			let usage = eps::usage(mode).unwrap();
			let domain = eps::service_domain(mode).unwrap();
			assert_eq!(eps::mode(usage, domain), Some(mode));
		}
		assert_eq!(eps::usage(0), None);
		assert_eq!(eps::mode(Usage::Data, ServiceDomain::CsOnly), None);
		// the fix for an LTE-only carrier is PS mode 2
		assert_eq!(eps::mode(Usage::Data, ServiceDomain::PsOnly), Some(eps::PS_2));
	}

	#[test]
	fn presets_have_4g_and_5g_alone() {
		let index = Preset::index_of(4 | 8 | 16, 16).expect("3G, 4G, 5G with 5G preferred");
		assert_eq!(PRESETS[index].preferred, Some(Rat::G5));
		// the pairs GNOME Settings does not offer. They are shown only where
		// ModemManager lists them for the modem (main.rs): it refuses the rest.
		assert_eq!(PRESETS[Preset::index_of(8 | 16, 16).unwrap()].preferred, Some(Rat::G5));
		assert_eq!(PRESETS[Preset::index_of(8 | 16, 8).unwrap()].preferred, Some(Rat::G4));
		assert_eq!(PRESETS[Preset::index_of(8 | 16, 0).unwrap()].preferred, None);
		// a modem without 5G: the preset of its modes is one without it
		let wanted = PRESETS[Preset::index_of(2 | 4 | 8, 8).unwrap()];
		assert_eq!((wanted.allowed, wanted.preferred), (2 | 4 | 8, Some(Rat::G4)));
		// every preset is distinct
		for (i, a) in PRESETS.iter().enumerate() {
			assert!(PRESETS.iter().enumerate().all(|(j, b)| i == j || a != b), "{a:?} twice");
		}
	}

	#[test]
	fn labels_name_every_technology_and_the_preferred_one() {
		assert_eq!(mode_label(4 | 8 | 16, 16), "3G, 4G, 5G (Preferred)");
		assert_eq!(mode_label(4 | 8 | 16, 8), "3G, 4G (Preferred), 5G");
		assert_eq!(mode_label(ALL, 0), "2G, 3G, 4G, 5G");
		assert_eq!(mode_label(16, 16), "5G Only");
		assert_eq!(mode_label(16, 0), "5G");
		assert_eq!(mode_label(0, 0), "None");
	}
}
