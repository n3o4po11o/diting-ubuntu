//! The names of what ModemManager and NetworkManager number, translated.

use crate::t;

/// `MMNetworkError`: the 3GPP cause of a network rejection.
pub const CS_DOMAIN_NOT_AVAILABLE: u32 = 18;

fn unknown(value: u32) -> String {
	t!("Unknown ({})", value)
}

/// `MMModemState`
pub fn modem_state(state: u32) -> String {
	match state {
		0 => t!("Unknown"),
		1 => t!("Initializing"),
		2 => t!("Locked"),
		3 => t!("Disabled"),
		4 => t!("Disabling"),
		5 => t!("Enabling"),
		6 => t!("Enabled"),
		7 => t!("Searching"),
		8 => t!("Registered"),
		9 => t!("Disconnecting"),
		10 => t!("Connecting"),
		11 => t!("Connected"),
		_ => unknown(state),
	}
}

/// `MMModemStateFailedReason`
pub fn failed_reason(reason: u32) -> Option<String> {
	match reason {
		0 => None,
		1 => Some(t!("Unknown")),
		2 => Some(t!("SIM missing")),
		3 => Some(t!("SIM error")),
		4 => Some(t!("Capabilities unknown")),
		5 => Some(t!("eSIM without profiles")),
		_ => Some(unknown(reason)),
	}
}

/// `MMModemAccessTechnology`, every technology of the mask
pub fn access_technology(mask: u32) -> String {
	const NAMES: [(u32, &str); 17] = [
		(1 << 1, "GSM"),
		(1 << 2, "GSM Compact"),
		(1 << 3, "GPRS"),
		(1 << 4, "EDGE"),
		(1 << 5, "UMTS"),
		(1 << 6, "HSDPA"),
		(1 << 7, "HSUPA"),
		(1 << 8, "HSPA"),
		(1 << 9, "HSPA+"),
		(1 << 10, "1xRTT"),
		(1 << 11, "EVDO0"),
		(1 << 12, "EVDO-A"),
		(1 << 13, "EVDO-B"),
		(1 << 14, "LTE"),
		(1 << 15, "5G"),
		(1 << 16, "LTE Cat-M"),
		(1 << 17, "LTE NB-IoT"),
	];
	let names: Vec<&str> = NAMES.iter().filter(|(bit, _)| mask & bit != 0).map(|(_, name)| *name).collect();
	if names.is_empty() {
		t!("Unknown")
	} else {
		names.join(", ")
	}
}

/// `MMModem3gppRegistrationState`
pub fn registration(state: u32) -> String {
	match state {
		0 => t!("Idle"),
		1 => t!("Home"),
		2 => t!("Searching"),
		3 => t!("Denied"),
		4 => t!("Unknown"),
		5 => t!("Roaming"),
		6 => t!("Home (SMS only)"),
		7 => t!("Roaming (SMS only)"),
		8 => t!("Emergency only"),
		9 => t!("Home (CSFB not preferred)"),
		10 => t!("Roaming (CSFB not preferred)"),
		11 => t!("Attached (restricted local operation)"),
		_ => unknown(state),
	}
}

/// `MMModem3gppPacketServiceState`
pub fn packet_service(state: u32) -> String {
	match state {
		0 => t!("Unknown"),
		1 => t!("Detached"),
		2 => t!("Attached"),
		_ => unknown(state),
	}
}

/// `MMModemPowerState`
pub fn power_state(state: u32) -> String {
	match state {
		0 => t!("Unknown"),
		1 => t!("Off"),
		2 => t!("Low"),
		3 => t!("On"),
		_ => unknown(state),
	}
}

/// `MMModem3gppEpsUeModeOperation`, in the words of the 3GPP spec
pub fn eps_ue_mode(mode: u32) -> String {
	match mode {
		0 => t!("Unknown"),
		1 => t!("EPS only, voice-centric"),
		2 => t!("EPS only, data-centric"),
		3 => t!("EPS and non-EPS, voice-centric"),
		4 => t!("EPS and non-EPS, data-centric"),
		_ => unknown(mode),
	}
}

/// `MMNetworkError`: the causes a phone meets, by their number
pub fn network_error(error: u32) -> String {
	match error {
		0 => t!("None"),
		2 => t!("IMSI unknown in the HLR"),
		3 => t!("Illegal MS"),
		4 => t!("IMSI unknown in the VLR"),
		5 => t!("IMEI not accepted"),
		6 => t!("Illegal ME"),
		7 => t!("GPRS not allowed"),
		8 => t!("GPRS and non-GPRS not allowed"),
		10 => t!("Implicitly detached"),
		11 => t!("PLMN not allowed"),
		12 => t!("Location area not allowed"),
		13 => t!("Roaming not allowed in this location area"),
		15 => t!("No cells in location area"),
		17 => t!("Network failure"),
		CS_DOMAIN_NOT_AVAILABLE => t!("CS domain not available"),
		19 => t!("ESM failure"),
		22 => t!("Congestion"),
		26 => t!("Insufficient resources"),
		27 => t!("Missing or unknown APN"),
		28 => t!("Unknown PDP address or type"),
		29 => t!("User authentication failed"),
		30 => t!("Activation rejected by the gateway"),
		31 => t!("Redirection to 5GCN required"),
		32 => t!("Service option not supported"),
		33 => t!("Requested service option not subscribed"),
		34 => t!("Service option temporarily out of order"),
		_ => t!("Network error {}", error),
	}
}

/// `NMDeviceState`
pub fn device_state(state: u32) -> String {
	match state {
		0 => t!("Unknown"),
		10 => t!("Unmanaged"),
		20 => t!("Unavailable"),
		30 => t!("Disconnected"),
		40 => t!("Preparing"),
		50 => t!("Configuring"),
		60 => t!("Needs authentication"),
		70 => t!("Configuring IP"),
		80 => t!("Connected"),
		90 => t!("Disconnecting"),
		100 => t!("Failed"),
		_ => unknown(state),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn numbers_outside_the_enumerations_are_named_by_number() {
		assert_eq!(modem_state(99), "Unknown (99)");
		assert_eq!(network_error(99), "Network error 99");
		assert_eq!(access_technology(0), "Unknown");
	}

	#[test]
	fn known_numbers_have_names() {
		assert_eq!(modem_state(11), "Connected");
		assert_eq!(access_technology(1 << 14 | 1 << 15), "LTE, 5G");
		assert_eq!(access_technology(1 << 15), "5G");
		assert_eq!(network_error(CS_DOMAIN_NOT_AVAILABLE), "CS domain not available");
		assert_eq!(eps_ue_mode(2), "EPS only, data-centric");
		assert_eq!(failed_reason(0), None);
		assert_eq!(failed_reason(2).as_deref(), Some("SIM missing"));
		assert_eq!(device_state(80), "Connected");
	}
}
