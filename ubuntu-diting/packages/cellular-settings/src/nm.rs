//! NetworkManager over D-Bus: the mobile data connections (the profiles of
//! type `gsm`), the device of the modem, and the calls that change them. The
//! session user may do all of it: the rule of NetworkManager lets an active
//! local session of a user in the `sudo` or `netdev` group modify system
//! connections. Blocking calls, to be made off the thread of the window.

use std::collections::HashMap;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::OwnedObjectPath;
use zbus::zvariant::OwnedValue;

pub const NAME: &str = "org.freedesktop.NetworkManager";
pub const ROOT: &str = "/org/freedesktop/NetworkManager";
pub const SETTINGS: &str = "/org/freedesktop/NetworkManager/Settings";
pub const IFACE_MANAGER: &str = "org.freedesktop.NetworkManager";
pub const IFACE_SETTINGS: &str = "org.freedesktop.NetworkManager.Settings";
pub const IFACE_CONNECTION: &str = "org.freedesktop.NetworkManager.Settings.Connection";
pub const IFACE_DEVICE: &str = "org.freedesktop.NetworkManager.Device";

/// `NM_DEVICE_TYPE_MODEM`: a modem, here the one ModemManager runs.
pub const DEVICE_TYPE_MODEM: u32 = 8;

/// `connection.autoconnect-retries` when the key is not set: NetworkManager's
/// own default, four.
pub const DEFAULT_RETRIES: i32 = 4;

/// a{sv}
pub type Dict = HashMap<String, OwnedValue>;
/// a{sa{sv}}: the settings of a profile, by group
pub type Settings = HashMap<String, Dict>;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Device {
	pub path: String,
	pub interface: String,
	pub device_type: u32,
	/// for a modem, the object path of the modem in ModemManager
	pub udi: String,
	pub state: u32,
	/// why NetworkManager put it in that state: `NMDeviceStateReason`
	pub reason: u32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Profile {
	pub path: String,
	pub settings: Settings,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Active {
	pub path: String,
	/// the settings connection this activation uses
	pub connection: String,
	pub state: u32,
}

/// Everything the Mobile data page shows.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
	pub device: Option<Device>,
	/// the profiles of type `gsm`, in the order NetworkManager lists them
	pub connections: Vec<Profile>,
	pub active: Vec<Active>,
}

fn proxy<'a>(conn: &'a Connection, path: &'a str, iface: &'a str) -> zbus::Result<Proxy<'a>> {
	Proxy::new(conn, NAME, path, iface)
}

pub fn string(settings: &Settings, group: &str, key: &str) -> Option<String> {
	settings.get(group)?.get(key).and_then(|value| value.downcast_ref::<String>().ok())
}

pub fn boolean(settings: &Settings, group: &str, key: &str) -> Option<bool> {
	settings.get(group)?.get(key).and_then(|value| value.downcast_ref::<bool>().ok())
}

pub fn i32(settings: &Settings, group: &str, key: &str) -> Option<i32> {
	settings.get(group)?.get(key).and_then(|value| value.downcast_ref::<i32>().ok())
}

/// What a settings connection is: `connection.type`.
pub fn kind(settings: &Settings) -> String {
	string(settings, "connection", "type").unwrap_or_default()
}

fn object_paths(conn: &Connection, path: &str, iface: &str, property: &str) -> zbus::Result<Vec<String>> {
	let paths: Vec<OwnedObjectPath> = proxy(conn, path, iface)?.get_property(property)?;
	Ok(paths.into_iter().map(|path| path.to_string()).collect())
}

fn device(conn: &Connection, path: &str) -> zbus::Result<Device> {
	let proxy = proxy(conn, path, IFACE_DEVICE)?;
	Ok(Device {
		path: path.to_string(),
		interface: proxy.get_property("Interface")?,
		device_type: proxy.get_property("DeviceType")?,
		udi: proxy.get_property("Udi")?,
		state: proxy.get_property("State")?,
		// (state, reason): the state it was in when the reason was given
		reason: proxy.get_property::<(u32, u32)>("StateReason")?.1,
	})
}

fn active(conn: &Connection, path: &str) -> zbus::Result<Active> {
	let proxy = proxy(conn, path, "org.freedesktop.NetworkManager.Connection.Active")?;
	Ok(Active {
		path: path.to_string(),
		connection: proxy.get_property::<OwnedObjectPath>("Connection")?.to_string(),
		state: proxy.get_property("State")?,
	})
}

/// The object paths of the devices of type modem: here the one ModemManager
/// runs (`qrtr0`).
pub fn modem_device_paths(conn: &Connection) -> zbus::Result<Vec<String>> {
	let paths = object_paths(conn, ROOT, IFACE_MANAGER, "Devices")?;
	let mut modems = Vec::new();
	for path in paths {
		if let Ok(device) = device(conn, &path) {
			if device.device_type == DEVICE_TYPE_MODEM {
				modems.push(path);
			}
		}
	}
	Ok(modems)
}

/// The device of the modem, if NetworkManager has one.
pub fn modem_device(conn: &Connection) -> zbus::Result<Option<Device>> {
	modem_device_paths(conn)?
		.first()
		.map(|path| device(conn, path))
		.transpose()
}

fn profile(conn: &Connection, path: &str) -> zbus::Result<Profile> {
	let reply = proxy(conn, path, IFACE_CONNECTION)?.call_method("GetSettings", &())?;
	Ok(Profile { path: path.to_string(), settings: reply.body().deserialize()? })
}

/// The whole state, in a handful of calls.
pub fn state(conn: &Connection) -> zbus::Result<State> {
	let reply = proxy(conn, SETTINGS, IFACE_SETTINGS)?.call_method("ListConnections", &())?;
	let paths: Vec<OwnedObjectPath> = reply.body().deserialize()?;
	let mut connections = Vec::new();
	for path in paths {
		let profile = profile(conn, &path.to_string())?;
		if kind(&profile.settings) == "gsm" {
			connections.push(profile);
		}
	}
	let active_paths = object_paths(conn, ROOT, IFACE_MANAGER, "ActiveConnections")?;
	let mut activations = Vec::new();
	for path in active_paths {
		// an activation may end between the list and the read
		if let Ok(one) = active(conn, &path) {
			activations.push(one);
		}
	}
	Ok(State { device: modem_device(conn)?, connections, active: activations })
}

/// Which address families the network gives: `gsm.ip-type`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum IpType {
	/// no `ip-type`: the modem tries IPv4 and IPv6, then each alone
	#[default]
	Auto,
	Ipv4,
	Ipv6,
	Ipv4v6,
}

impl IpType {
	pub const ALL: [IpType; 4] = [IpType::Auto, IpType::Ipv4, IpType::Ipv6, IpType::Ipv4v6];

	pub fn token(self) -> Option<&'static str> {
		match self {
			IpType::Auto => None,
			IpType::Ipv4 => Some("ipv4"),
			IpType::Ipv6 => Some("ipv6"),
			IpType::Ipv4v6 => Some("ipv4v6"),
		}
	}

	pub fn of(settings: &Settings) -> IpType {
		match string(settings, "gsm", "ip-type").as_deref() {
			Some("ipv4") => IpType::Ipv4,
			Some("ipv6") => IpType::Ipv6,
			Some("ipv4v6") => IpType::Ipv4v6,
			_ => IpType::Auto,
		}
	}
}

/// What the form of a connection has.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Form {
	pub id: String,
	pub apn: String,
	pub ip_type: IpType,
	pub autoconnect: bool,
	pub autoconnect_retries: i32,
	pub home_only: bool,
	/// empty: none
	pub username: String,
	/// None: as it is; Some(empty): removed; Some(password): that one
	pub password: Option<String>,
}

fn put(dict: &mut Dict, key: &str, value: impl Into<zbus::zvariant::Value<'static>>) {
	dict.insert(key.to_string(), value.into().try_to_owned().expect("a value that can be owned"));
}

/// Remove a key, or set it: None removes.
fn put_or_remove<T: Into<zbus::zvariant::Value<'static>>>(dict: &mut Dict, key: &str, value: Option<T>) {
	match value {
		Some(value) => put(dict, key, value),
		None => {
			dict.remove(key);
		}
	}
}

/// The form of an existing profile.
pub fn form_of(profile: &Profile) -> Form {
	let settings = &profile.settings;
	let text = |key: &str| string(settings, "gsm", key).unwrap_or_default();
	Form {
		id: string(settings, "connection", "id").unwrap_or_default(),
		apn: text("apn"),
		ip_type: IpType::of(settings),
		autoconnect: boolean(settings, "connection", "autoconnect").unwrap_or(true),
		autoconnect_retries: i32(settings, "connection", "autoconnect-retries")
			.filter(|retries| *retries >= 0)
			.unwrap_or(DEFAULT_RETRIES),
		home_only: boolean(settings, "gsm", "home-only").unwrap_or(false),
		username: text("username"),
		password: None,
	}
}

/// A new profile of type `gsm` from a form.
pub fn new_settings(form: &Form, uuid: &str) -> Settings {
	let mut settings = Settings::new();
	let mut identity = Dict::new();
	put(&mut identity, "id", form.id.clone());
	put(&mut identity, "uuid", uuid.to_string());
	put(&mut identity, "type", "gsm".to_string());
	settings.insert("connection".to_string(), identity);
	for group in ["ipv4", "ipv6"] {
		let mut ip = Dict::new();
		put(&mut ip, "method", "auto".to_string());
		settings.insert(group.to_string(), ip);
	}
	apply_form(&mut settings, form);
	settings
}

/// Write the form into the settings of a profile: what the form names, and
/// nothing else. What it does not name (the uuid, a SIM the profile is bound
/// to, route metrics, the secrets) stays as it was.
pub fn apply_form(settings: &mut Settings, form: &Form) {
	let connection = settings.entry("connection".to_string()).or_default();
	put(connection, "id", form.id.clone());
	put(connection, "type", "gsm".to_string());
	put(connection, "autoconnect", form.autoconnect);
	put(connection, "autoconnect-retries", form.autoconnect_retries);

	let gsm = settings.entry("gsm".to_string()).or_default();
	put(gsm, "apn", form.apn.clone());
	put(gsm, "home-only", form.home_only);
	put_or_remove(gsm, "ip-type", form.ip_type.token());
	put_or_remove(gsm, "username", (!form.username.is_empty()).then(|| form.username.clone()));
	match &form.password {
		Some(password) if password.is_empty() => {
			gsm.remove("password");
		}
		Some(password) => put(gsm, "password", password.clone()),
		None => {}
	}

	for group in ["ipv4", "ipv6"] {
		let ip = settings.entry(group.to_string()).or_default();
		if !ip.contains_key("method") {
			put(ip, "method", "auto".to_string());
		}
	}
}

/// Save a form: a new profile, or the profile at `path`.
pub fn save_form(conn: &Connection, form: &Form, path: Option<&str>) -> zbus::Result<()> {
	match path {
		Some(path) => {
			let mut settings = profile(conn, path)?.settings;
			apply_form(&mut settings, form);
			proxy(conn, path, IFACE_CONNECTION)?.call_method("Update", &settings)?;
		}
		None => {
			let settings = new_settings(form, &gtk::glib::uuid_string_random());
			let proxy = proxy(conn, SETTINGS, IFACE_SETTINGS)?;
			let reply = proxy.call_method("AddConnection", &settings)?;
			let _: OwnedObjectPath = reply.body().deserialize()?;
		}
	}
	Ok(())
}

pub fn delete_connection(conn: &Connection, path: &str) -> zbus::Result<()> {
	proxy(conn, path, IFACE_CONNECTION)?.call_method("Delete", &())?;
	Ok(())
}

/// Dial a profile on the modem device. The answer comes when the activation
/// starts, not when it is done: the device state tells how it went.
pub fn activate(conn: &Connection, profile: &str, device: &str) -> zbus::Result<()> {
	let profile = OwnedObjectPath::try_from(profile.to_string())?;
	let device = OwnedObjectPath::try_from(device.to_string())?;
	let none = OwnedObjectPath::try_from("/".to_string())?;
	let reply = proxy(conn, ROOT, IFACE_MANAGER)?.call_method("ActivateConnection", &(profile, device, none))?;
	let _: OwnedObjectPath = reply.body().deserialize()?;
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;

	fn form() -> Form {
		Form {
			id: "ctnet".to_string(),
			apn: "ctnet".to_string(),
			ip_type: IpType::Ipv4v6,
			autoconnect: true,
			autoconnect_retries: 1,
			home_only: false,
			username: String::new(),
			password: None,
		}
	}

	#[test]
	fn a_new_profile_is_a_gsm_connection() {
		let settings = new_settings(&form(), "uuid-1");
		assert_eq!(kind(&settings), "gsm");
		assert_eq!(string(&settings, "connection", "uuid").as_deref(), Some("uuid-1"));
		assert_eq!(string(&settings, "gsm", "apn").as_deref(), Some("ctnet"));
		assert_eq!(string(&settings, "gsm", "ip-type").as_deref(), Some("ipv4v6"));
		assert_eq!(boolean(&settings, "connection", "autoconnect"), Some(true));
		assert_eq!(i32(&settings, "connection", "autoconnect-retries"), Some(1));
		assert_eq!(boolean(&settings, "gsm", "home-only"), Some(false));
		assert_eq!(string(&settings, "ipv4", "method").as_deref(), Some("auto"));
		assert_eq!(string(&settings, "ipv6", "method").as_deref(), Some("auto"));
		// no username, no password: the keys are not there
		assert!(!settings["gsm"].contains_key("username"));
		assert!(!settings["gsm"].contains_key("password"));
	}

	#[test]
	fn the_form_reads_back_from_its_own_settings() {
		let form = Form { username: "user".to_string(), ip_type: IpType::Ipv4, ..form() };
		let settings = new_settings(&form, "uuid-1");
		let profile = Profile { path: String::new(), settings };
		let read = form_of(&profile);
		assert_eq!((read.id, read.apn, read.username), (form.id.clone(), form.apn.clone(), "user".to_string()));
		assert_eq!((read.ip_type, read.autoconnect, read.autoconnect_retries, read.home_only), (IpType::Ipv4, true, 1, false));
		// the password is never read back
		assert_eq!(read.password, None);
		// a profile without the retries key has NetworkManager's default
		let bare = Form { autoconnect_retries: -1, ..form.clone() };
		let settings = new_settings(&bare, "uuid-2");
		assert_eq!(form_of(&Profile { path: String::new(), settings }).autoconnect_retries, DEFAULT_RETRIES);
	}

	#[test]
	fn editing_changes_what_the_form_names_and_nothing_else() {
		// a profile with what the form does not name: a SIM it is bound to, a
		// metric, a stored password, a username
		let mut settings = new_settings(&Form { username: "old".to_string(), ..form() }, "uuid-keep");
		put(settings.get_mut("gsm").unwrap(), "sim-id", "8986".to_string());
		put(settings.get_mut("gsm").unwrap(), "password", "secret".to_string());
		put(settings.get_mut("ipv4").unwrap(), "route-metric", 1050i32);
		// the form: another name, automatic, and a password left as it is
		let edited = Form {
			id: "China Telecom".to_string(),
			autoconnect: false,
			autoconnect_retries: 3,
			password: None,
			..Form { username: String::new(), ..form() }
		};
		apply_form(&mut settings, &edited);
		assert_eq!(string(&settings, "connection", "id").as_deref(), Some("China Telecom"));
		assert_eq!(string(&settings, "connection", "uuid").as_deref(), Some("uuid-keep"));
		assert_eq!(boolean(&settings, "connection", "autoconnect"), Some(false));
		assert_eq!(i32(&settings, "connection", "autoconnect-retries"), Some(3));
		assert_eq!(string(&settings, "gsm", "sim-id").as_deref(), Some("8986"));
		assert_eq!(string(&settings, "gsm", "password").as_deref(), Some("secret"));
		assert_eq!(i32(&settings, "ipv4", "route-metric"), Some(1050));
		// the username was cleared: the key goes
		assert!(!settings["gsm"].contains_key("username"));
		// a password given is written, an empty one removes the stored one
		apply_form(&mut settings, &Form { password: Some("new".to_string()), ..edited.clone() });
		assert_eq!(string(&settings, "gsm", "password").as_deref(), Some("new"));
		apply_form(&mut settings, &Form { password: Some(String::new()), ..edited });
		assert!(!settings["gsm"].contains_key("password"));
		// "automatic" removes the ip-type key
		apply_form(&mut settings, &Form { ip_type: IpType::Auto, ..form() });
		assert!(!settings["gsm"].contains_key("ip-type"));
	}

	#[test]
	fn the_ip_type_words_are_networkmanager_s() {
		assert_eq!(IpType::ALL.map(|ip| ip.token()), [None, Some("ipv4"), Some("ipv6"), Some("ipv4v6")]);
	}
}
