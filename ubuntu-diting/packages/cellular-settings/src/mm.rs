//! ModemManager over D-Bus: what the Status and the Network pages read, and
//! the two calls that change the modem. Blocking calls, to be made off the
//! thread of the window; every function takes the connection to use.

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::OwnedValue;

use std::collections::HashMap;

pub const NAME: &str = "org.freedesktop.ModemManager1";
pub const ROOT: &str = "/org/freedesktop/ModemManager1";
pub const IFACE_MODEM: &str = "org.freedesktop.ModemManager1.Modem";
pub const IFACE_3GPP: &str = "org.freedesktop.ModemManager1.Modem.Modem3gpp";

/// `org.freedesktop.ModemManager1.Modem`
#[derive(Clone, Debug, Default)]
pub struct Modem {
	pub path: String,
	pub state: u32,
	pub failed_reason: u32,
	pub access_technologies: u32,
	pub signal_quality: u32,
	/// allowed and preferred, the bits of `MMModemMode`
	pub current_modes: (u32, u32),
	pub supported_modes: Vec<(u32, u32)>,
	pub power_state: u32,
	pub model: String,
	pub revision: String,
}

/// `org.freedesktop.ModemManager1.Modem.Modem3gpp`
#[derive(Clone, Debug, Default)]
pub struct Modem3gpp {
	pub registration_state: u32,
	pub operator_code: String,
	pub operator_name: String,
	pub rejection: Option<Rejection>,
	pub eps_ue_mode: u32,
	pub packet_service_state: u32,
}

/// The `NetworkRejection` property: the last rejection of the network, as
/// `a{sv}` with `error` and whatever else the modem reported.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Rejection {
	pub error: u32,
	pub operator_id: String,
	pub operator_name: String,
	pub access_technology: u32,
}

fn proxy<'a>(conn: &'a Connection, path: &'a str, iface: &'a str) -> zbus::Result<Proxy<'a>> {
	Proxy::new(conn, NAME, path, iface)
}

/// The modems, as their object paths, in the order of their paths.
///
/// Through the ObjectManager, not `GetModems`: the policy of the system bus
/// lets a process that is not root call ModemManager for
/// `org.freedesktop.DBus.Properties`, `org.freedesktop.DBus.ObjectManager` and
/// a list of members (`SetCurrentModes`, `SetEpsUeModeOperation`, ...), and
/// nothing else. A call outside it is refused by dbus-daemon with AccessDenied.
pub fn modem_paths(conn: &Connection) -> zbus::Result<Vec<String>> {
	let reply = proxy(conn, ROOT, "org.freedesktop.DBus.ObjectManager")?.call_method("GetManagedObjects", &())?;
	let objects: HashMap<zbus::zvariant::OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>> =
		reply.body().deserialize()?;
	let mut paths: Vec<String> = objects
		.iter()
		.filter(|(_, interfaces)| interfaces.contains_key(IFACE_MODEM))
		.map(|(path, _)| path.to_string())
		.collect();
	paths.sort();
	Ok(paths)
}

/// `State` comes as an int32 from this ModemManager and as a uint32 from
/// others: either is the number.
fn state_of(proxy: &Proxy) -> zbus::Result<u32> {
	match proxy.get_property::<u32>("State") {
		Ok(state) => Ok(state),
		Err(_) => Ok(proxy.get_property::<i32>("State")? as u32),
	}
}

fn modem(conn: &Connection, path: &str) -> zbus::Result<Modem> {
	let proxy = proxy(conn, path, IFACE_MODEM)?;
	Ok(Modem {
		path: path.to_string(),
		state: state_of(&proxy)?,
		failed_reason: proxy.get_property("StateFailedReason")?,
		access_technologies: proxy.get_property("AccessTechnologies")?,
		signal_quality: proxy.get_property::<(u32, bool)>("SignalQuality")?.0,
		current_modes: proxy.get_property("CurrentModes")?,
		supported_modes: proxy.get_property("SupportedModes")?,
		power_state: proxy.get_property("PowerState")?,
		model: proxy.get_property("Model")?,
		revision: proxy.get_property("Revision")?,
	})
}

fn modem_3gpp(conn: &Connection, path: &str) -> zbus::Result<Modem3gpp> {
	let proxy = proxy(conn, path, IFACE_3GPP)?;
	let rejection: HashMap<String, OwnedValue> = proxy.get_property("NetworkRejection")?;
	let number = |key: &str| rejection.get(key).and_then(|value| value.downcast_ref::<u32>().ok());
	let text = |key: &str| {
		rejection
			.get(key)
			.and_then(|value| value.downcast_ref::<String>().ok())
	};
	Ok(Modem3gpp {
		registration_state: proxy.get_property("RegistrationState")?,
		operator_code: proxy.get_property("OperatorCode")?,
		operator_name: proxy.get_property("OperatorName")?,
		rejection: number("error").map(|error| Rejection {
			error,
			operator_id: text("operator-id").unwrap_or_default(),
			operator_name: text("operator-name").unwrap_or_default(),
			access_technology: number("access-technology").unwrap_or(0),
		}),
		eps_ue_mode: proxy.get_property("EpsUeModeOperation")?,
		packet_service_state: proxy.get_property("PacketServiceState")?,
	})
}

/// The first modem, with its 3GPP interface. A phone has one.
pub fn first_modem(conn: &Connection) -> zbus::Result<(Modem, Modem3gpp)> {
	let path = modem_paths(conn)?.into_iter().next().ok_or_else(|| zbus::Error::Failure("no modem".to_string()))?;
	Ok((modem(conn, &path)?, modem_3gpp(conn, &path)?))
}

/// `SetEpsUeModeOperation`: the usage setting and the service domain of the
/// modem, in one number. ModemManager reads the preference back before it
/// answers, so an answer is the modem's.
pub fn set_eps_ue_mode(conn: &Connection, path: &str, mode: u32) -> zbus::Result<()> {
	let proxy = proxy(conn, path, IFACE_3GPP)?;
	proxy.call_method("SetEpsUeModeOperation", &(mode,))?;
	Ok(())
}

/// `SetCurrentModes`: the technologies allowed and the preferred one.
pub fn set_modes(conn: &Connection, path: &str, allowed: u32, preferred: u32) -> zbus::Result<()> {
	let proxy = proxy(conn, path, IFACE_MODEM)?;
	proxy.call_method("SetCurrentModes", &(allowed, preferred))?;
	Ok(())
}
