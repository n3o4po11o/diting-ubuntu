//! Tell the window when something changed on the bus, so that it reads the
//! state again: a property of the modem, of its 3GPP interface, of the device
//! or of NetworkManager; and a service that restarted.

use std::collections::HashSet;
use std::time::Duration;

use async_channel::Sender;
use zbus::blocking::{Connection, Proxy};

use crate::{mm, Msg, nm};

/// destination, path, interface
type Key = (String, String, String);

/// One thread, for the life of the window. Every few seconds it looks which
/// objects there are and has each one watched by a thread of its own; a
/// watcher sends `Msg::Refresh` at every `PropertiesChanged`.
pub fn start(tx: Sender<Msg>) {
	std::thread::spawn(move || {
		let conn = match crate::bus() {
			Ok(conn) => conn,
			Err(error) => {
				let _ = tx.send_blocking(Msg::Bus(error.to_string()));
				return;
			}
		};
		names(conn.clone(), tx.clone());
		let mut watched: HashSet<Key> = HashSet::new();
		loop {
			let mut now: HashSet<Key> = HashSet::new();
			now.insert((mm::NAME.to_string(), mm::ROOT.to_string(), mm::NAME.to_string()));
			now.insert((nm::NAME.to_string(), nm::ROOT.to_string(), nm::IFACE_MANAGER.to_string()));
			if let Ok(paths) = mm::modem_paths(&conn) {
				for path in paths {
					now.insert((mm::NAME.to_string(), path.clone(), mm::IFACE_MODEM.to_string()));
					now.insert((mm::NAME.to_string(), path, mm::IFACE_3GPP.to_string()));
				}
			}
			if let Ok(paths) = nm::modem_device_paths(&conn) {
				for path in paths {
					now.insert((nm::NAME.to_string(), path, nm::IFACE_DEVICE.to_string()));
				}
			}
			for key in now.difference(&watched) {
				properties(conn.clone(), key.clone(), tx.clone());
			}
			watched = now;
			std::thread::sleep(Duration::from_secs(5));
		}
	});
}

/// PropertiesChanged of one interface, for as long as the object exists. When
/// the object goes away the thread stays, parked on the socket: a few dozen
/// parked threads are what a day of restarts costs.
fn properties(conn: Connection, key: Key, tx: Sender<Msg>) {
	std::thread::spawn(move || {
		let (destination, path, interface) = key;
		let Ok(proxy) = Proxy::new(&conn, destination.as_str(), path.as_str(), interface.as_str()) else {
			return;
		};
		let Ok(signals) = proxy.receive_signal("PropertiesChanged") else {
			return;
		};
		// A change comes in bursts (state, access technology, signal): the
		// window makes one reading of many messages.
		for _ in signals {
			if tx.send_blocking(Msg::Refresh).is_err() {
				break;
			}
		}
	});
}

/// NameOwnerChanged of the two services: one that restarted is read again.
fn names(conn: Connection, tx: Sender<Msg>) {
	std::thread::spawn(move || {
		let Ok(proxy) = Proxy::new(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus")
		else {
			return;
		};
		let Ok(signals) = proxy.receive_signal("NameOwnerChanged") else {
			return;
		};
		for signal in signals {
			let Ok((name, _, _)) = signal.body().deserialize::<(String, String, String)>() else {
				continue;
			};
			if name == mm::NAME || name == nm::NAME {
				let _ = tx.send_blocking(Msg::Refresh);
			}
		}
	});
}
