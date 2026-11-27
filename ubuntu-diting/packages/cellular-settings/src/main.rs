//! Cellular Settings: the network mode, the network preference and the mobile
//! data connections of the modem, where the desktop's settings leave them out.
//! GTK 4 and libadwaita; ModemManager and NetworkManager over D-Bus, and for
//! how the modem asks for service, the tool of the device package.
//!
//!   cellular-settings                    the window
//!   CELLULAR_SETTINGS_SNAPSHOT=DIR cellular-settings
//!   CELLULAR_SETTINGS_SNAPSHOT=DIR/NAME@network cellular-settings
//!       a page as DIR/NAME.png (the Status page, or the one named), then
//!       quit: to look at the window without a hand on the phone. An
//!       environment variable, not an option: GLib parses the command line
//!       first and refuses what it does not know.

mod i18n;
mod mm;
mod modemmode;
mod names;
mod nas;
mod nm;
mod persist;
mod ui;
mod watch;

use std::cell::Cell;
use std::rc::Rc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use adw::prelude::*;
use async_channel::Sender;
use gtk::glib;

use crate::modemmode::{eps, mode_label, ModemMode, Preset, Rat};
use crate::nas::Preference as NasPreference;

const APP_ID: &str = "io.github.n3o4po11o.cellular-settings";

/// How long what was read from the modem itself counts as current: asking
/// it is a process with a QMI client of its own, not to be run at every change
/// of the signal strength.
const NAS_AGE: Duration = Duration::from_secs(20);

/// One connection to the system bus for every thread that talks on it.
static BUS: OnceLock<zbus::blocking::Connection> = OnceLock::new();

fn bus() -> zbus::Result<zbus::blocking::Connection> {
	if let Some(conn) = BUS.get() {
		return Ok(conn.clone());
	}
	let conn = zbus::blocking::Connection::system()?;
	// another thread may have been first; then its connection serves as well
	let _ = BUS.set(conn.clone());
	Ok(BUS.get().cloned().unwrap_or(conn))
}

/// Everything the pages show, read in one go on a thread of its own.
#[derive(Clone, Debug)]
struct Snapshot {
	modem: Result<(mm::Modem, mm::Modem3gpp), String>,
	data: Result<nm::State, String>,
	saved: Result<Option<String>, String>,
	/// what the modem itself reports when it was asked this time (`Ok(Some)`),
	/// `Ok(None)` when it was not
	nas: Result<Option<NasPreference>, String>,
}

fn load(ask_nas: bool) -> Snapshot {
	let conn = match bus() {
		Ok(conn) => conn,
		Err(error) => {
			let error = error.to_string();
			return Snapshot { modem: Err(error.clone()), data: Err(error), saved: persist::read(), nas: Ok(None) };
		}
	};
	Snapshot {
		modem: mm::first_modem(&conn).map_err(|error| error.to_string()),
		data: nm::state(&conn).map_err(|error| error.to_string()),
		saved: persist::read(),
		nas: if ask_nas && nas::available() { nas::read().map(Some) } else { Ok(None) },
	}
}

/// Apply, in the order of a boot: the file, then how the modem asks for
/// service, then the network mode. What went wrong is said, each on its own
/// line; an empty answer is that all went well.
fn apply_all(path: &str, ue: u32, allowed: u32, preferred: u32, file: Option<&str>) -> String {
	let mut wrong = Vec::new();
	if let Some(text) = file {
		if let Err(error) = persist::write(text) {
			wrong.push(t!("Not saved for the next boot: {}", error));
		}
	}
	if let (Some(usage), Some(service_domain)) = (eps::usage(ue), eps::service_domain(ue)) {
		// by the tool where there is one: it waits for the modem; else through
		// ModemManager, whose answer is not the modem's
		let not_taken = if nas::available() {
			nas::apply(usage, service_domain).err()
		} else {
			bus().and_then(|conn| mm::set_eps_ue_mode(&conn, path, ue)).err().map(|error| error.to_string())
		};
		if let Some(error) = not_taken {
			wrong.push(t!("The EPS UE mode was not taken: {}", error));
		}
	}
	if let Err(error) = bus().and_then(|conn| mm::set_modes(&conn, path, allowed, preferred)) {
		wrong.push(t!("The network mode was not taken: {}", error));
	}
	if wrong.is_empty() {
		if file.is_some() {
			t!("Applied, and kept for the next boot")
		} else {
			t!("Applied")
		}
	} else {
		wrong.join("\n")
	}
}

/// What the widgets ask for.
#[derive(Clone, Debug)]
enum Msg {
	Refresh,
	Loaded(Box<Snapshot>),
	Bus(String),
	ShowPage(&'static str),
	/// the user changed one of the lists of the Network page
	Dirty,
	Keep(bool),
	Apply,
	/// shown as a toast, or as a dialog when there is more to read; then
	/// everything is read again
	Answer(String),
	/// the form for a new connection, or for this one
	Edit(Option<nm::Profile>),
	/// a form to save: of the connection at the path, or of a new one
	Form(Box<nm::Form>, Option<String>),
	Activate(String),
	DeleteAsk(String),
	Delete(String),
	Forget,
}

struct App {
	app: adw::Application,
	win: adw::ApplicationWindow,
	w: ui::Widgets,
	tx: Sender<Msg>,
	current: Option<Snapshot>,
	/// the network modes the list holds, as listed
	presets: Vec<Preset>,
	/// set while the lists are filled from the modem: their own signal is not the user's
	updating: Rc<Cell<bool>>,
	keep: bool,
	/// the user changed a list since it last showed the modem
	dirty: bool,
	in_flight: bool,
	queued: bool,
	/// what the modem itself says of its usage and service domain: None where
	/// there is no tool to ask it with
	nas: Option<Result<NasPreference, String>>,
	nas_read: Option<Instant>,
	/// ask the modem again at the next reading
	nas_again: bool,
	snapshot: Option<String>,
	snapshot_started: bool,
}

fn main() -> glib::ExitCode {
	let snapshot = std::env::var("CELLULAR_SETTINGS_SNAPSHOT").ok().filter(|directory| !directory.is_empty());
	i18n::init();
	let application = adw::Application::builder().application_id(APP_ID).build();
	application.connect_activate(move |application| build(application, snapshot.clone()));
	application.run()
}

fn build(application: &adw::Application, snapshot: Option<String>) {
	let win = adw::ApplicationWindow::new(application);
	win.set_title(Some(&t!("Cellular Settings")));
	win.set_default_size(390, 760);

	let (tx, rx) = async_channel::unbounded::<Msg>();
	let updating = Rc::new(Cell::new(false));
	let widgets = ui::build(tx.clone(), updating.clone());
	win.set_content(Some(&widgets.toast));
	win.present();

	let mut app = App {
		app: application.clone(),
		win,
		w: widgets,
		tx: tx.clone(),
		current: None,
		presets: Vec::new(),
		updating,
		keep: false,
		dirty: false,
		in_flight: false,
		queued: false,
		nas: None,
		nas_read: None,
		nas_again: false,
		snapshot,
		snapshot_started: false,
	};
	// the answers of the bus threads come back on the thread of the window
	glib::spawn_future_local(async move {
		while let Ok(msg) = rx.recv().await {
			app.handle(msg);
		}
	});
	let _ = tx.send_blocking(Msg::Refresh);
	watch::start(tx);
}

/// The subtitle of a row: the text, or nothing.
fn show(row: &adw::ActionRow, text: Option<String>) {
	row.set_subtitle(text.as_deref().unwrap_or(""));
}

/// The second line of a connection in the list.
fn profile_line(profile: &nm::Profile, state: &nm::State) -> String {
	let settings = &profile.settings;
	let apn = nm::string(settings, "gsm", "apn").unwrap_or_default();
	let active = state.active.iter().any(|active| active.connection == profile.path);
	let status = if active { t!("connected") } else { t!("not connected") };
	let autoconnect = if nm::boolean(settings, "connection", "autoconnect").unwrap_or(true) {
		t!("automatic")
	} else {
		t!("manual")
	};
	let dials = nm::i32(settings, "connection", "autoconnect-retries")
		.filter(|retries| *retries >= 0)
		.unwrap_or(nm::DEFAULT_RETRIES);
	t!("APN {}", apn) + " · " + &status + " · " + &autoconnect + " · " + &t!("{} dials", dials)
}

impl App {
	fn handle(&mut self, msg: Msg) {
		match msg {
			Msg::Refresh => self.refresh(),
			Msg::Loaded(snapshot) => {
				self.in_flight = false;
				match &snapshot.nas {
					Ok(Some(preference)) => self.nas = Some(Ok(*preference)),
					Err(error) => self.nas = Some(Err(error.clone())),
					Ok(None) => {}
				}
				self.render(&snapshot);
				self.current = Some((*snapshot).clone());
				self.start_snapshot();
				if self.queued {
					self.queued = false;
					let _ = self.tx.send_blocking(Msg::Refresh);
				}
			}
			Msg::Bus(error) => self.answer(t!("No system bus: {}", error)),
			Msg::ShowPage(page) => self.w.stack.set_visible_child_name(page),
			Msg::Dirty => {
				self.dirty = true;
				self.w.network.apply.set_sensitive(true);
				self.explain_mode();
			}
			Msg::Keep(on) => self.keep = on,
			Msg::Apply => self.apply(),
			Msg::Answer(text) => {
				self.answer(text);
				// the modem may have been asked to change: read it again
				self.nas_again = true;
				self.refresh();
			}
			Msg::Edit(None) => ui::form_dialog(&self.win, None, self.tx.clone()),
			Msg::Edit(Some(profile)) => ui::form_dialog(&self.win, Some(&profile), self.tx.clone()),
			Msg::Form(form, path) => self.in_background(
				move |conn| nm::save_form(conn, &form, path.as_deref()),
				|| t!("Connection saved"),
			),
			Msg::Activate(path) => {
				let Some(device) = self.modem_device() else {
					return self.answer(t!("NetworkManager has no device for the modem"));
				};
				self.in_background(move |conn| nm::activate(conn, &path, &device), || t!("Dialling"));
			}
			Msg::DeleteAsk(path) => {
				let id = self
					.profile(&path)
					.and_then(|profile| nm::string(&profile.settings, "connection", "id"))
					.unwrap_or_else(|| path.clone());
				ui::confirm_delete(&self.win, &id, &path, self.tx.clone());
			}
			Msg::Delete(path) => self.in_background(move |conn| nm::delete_connection(conn, &path), || t!("Connection deleted")),
			Msg::Forget => {
				let tx = self.tx.clone();
				std::thread::spawn(move || {
					let answer = persist::forget()
						.map(|_| t!("Forgotten: the modem's own defaults apply at the next boot."))
						.unwrap_or_else(|error| error);
					let _ = tx.send_blocking(Msg::Answer(answer));
				});
			}
		}
	}

	/// Read everything again, once at a time: a request that comes while one
	/// is on its way is answered when that one is back. The modem itself is
	/// asked how it asks for service only now and then.
	fn refresh(&mut self) {
		if self.in_flight {
			self.queued = true;
			return;
		}
		self.in_flight = true;
		let ask_nas = self.nas_again || self.nas_read.map_or(true, |read| read.elapsed() > NAS_AGE);
		if ask_nas {
			self.nas_again = false;
			self.nas_read = Some(Instant::now());
		}
		let tx = self.tx.clone();
		std::thread::spawn(move || {
			let _ = tx.send_blocking(Msg::Loaded(Box::new(load(ask_nas))));
		});
	}

	fn answer(&mut self, text: String) {
		self.w.network.apply.set_sensitive(self.dirty);
		if text.lines().count() > 1 || text.chars().count() > 72 {
			ui::failure(&self.win, text);
		} else {
			self.w.toast.add_toast(adw::Toast::new(&text));
		}
	}

	/// Run a call on the bus on a thread; its answer, or the text on success,
	/// comes back as a toast.
	fn in_background<W, S>(&self, work: W, success: S)
	where
		W: FnOnce(&zbus::blocking::Connection) -> zbus::Result<()> + Send + 'static,
		S: FnOnce() -> String + Send + 'static,
	{
		let tx = self.tx.clone();
		std::thread::spawn(move || {
			let answer = match bus().and_then(|conn| work(&conn)) {
				Ok(()) => success(),
				Err(error) => error.to_string(),
			};
			let _ = tx.send_blocking(Msg::Answer(answer));
		});
	}

	/// The EPS UE mode as it is: as the modem reports it where the tool asks
	/// it, else as ModemManager shows it.
	fn ue_mode(&self, threegpp: &mm::Modem3gpp) -> u32 {
		match &self.nas {
			Some(Ok(preference)) => preference.ue_mode().unwrap_or(threegpp.eps_ue_mode),
			_ => threegpp.eps_ue_mode,
		}
	}

	fn apply(&mut self) {
		let Some((modem, _)) = self.current.as_ref().and_then(|snapshot| snapshot.modem.as_ref().ok()) else {
			return self.answer(t!("No modem"));
		};
		let Some(ue) = eps::KNOWN.get(self.w.network.eps.selected() as usize).copied() else {
			return self.answer(t!("No EPS UE mode chosen"));
		};
		let Some(preset) = self.presets.get(self.w.network.mode.selected() as usize).copied() else {
			return self.answer(t!("No network mode chosen"));
		};
		let mut saved = ModemMode::default();
		saved.allowed = Rat::ALL.into_iter().filter(|rat| preset.allowed & rat.bit() != 0).collect();
		saved.preferred = preset.preferred;
		saved.usage = eps::usage(ue);
		saved.service_domain = eps::service_domain(ue);
		let file = self.keep.then(|| saved.to_text());
		let path = modem.path.clone();
		self.w.network.apply.set_sensitive(false);
		// the lists show the modem again as it is after this
		self.dirty = false;
		let tx = self.tx.clone();
		std::thread::spawn(move || {
			let _ = tx.send_blocking(Msg::Answer(apply_all(
				&path,
				ue,
				preset.allowed,
				preset.preferred.map_or(0, Rat::bit),
				file.as_deref(),
			)));
		});
	}

	fn render(&mut self, snapshot: &Snapshot) {
		let mut refused = false;
		match &snapshot.modem {
			Ok((modem, threegpp)) => {
				let mut state = names::modem_state(modem.state);
				if let Some(reason) = names::failed_reason(modem.failed_reason) {
					state = t!("{}, because: {}", &state, reason);
				}
				show(&self.w.status.state, Some(state));
				let operator = match (threegpp.operator_name.is_empty(), threegpp.operator_code.is_empty()) {
					(true, true) => t!("None"),
					(true, false) => threegpp.operator_code.clone(),
					(false, true) => threegpp.operator_name.clone(),
					(false, false) => t!("{} ({})", &threegpp.operator_name, &threegpp.operator_code),
				};
				show(&self.w.status.operator, Some(operator));
				show(&self.w.status.access, Some(names::access_technology(modem.access_technologies)));
				show(&self.w.status.signal, Some(t!("{} %", modem.signal_quality)));
				show(&self.w.status.registration, Some(names::registration(threegpp.registration_state)));
				show(&self.w.status.packet, Some(names::packet_service(threegpp.packet_service_state)));
				match &threegpp.rejection {
					Some(rejection) => {
						refused = rejection.error == names::CS_DOMAIN_NOT_AVAILABLE;
						let network = match (rejection.operator_name.is_empty(), rejection.operator_id.is_empty()) {
							(true, true) => t!("an unknown network"),
							(true, false) => rejection.operator_id.clone(),
							(false, true) => rejection.operator_name.clone(),
							(false, false) => t!("{} ({})", &rejection.operator_name, &rejection.operator_id),
						};
						show(
							&self.w.status.rejection,
							Some(t!(
								"{} ({}), on {} for {}",
								names::network_error(rejection.error),
								rejection.error,
								names::access_technology(rejection.access_technology),
								&network
							)),
						);
					}
					None => show(&self.w.status.rejection, None),
				}
				self.w.status.rejection.set_visible(threegpp.rejection.is_some());
				let ue = self.ue_mode(threegpp);
				let ue = if matches!(self.nas, Some(Ok(_))) {
					t!("{} (as the modem reports it)", names::eps_ue_mode(ue))
				} else {
					names::eps_ue_mode(ue)
				};
				show(&self.w.status.eps, Some(ue));
				show(&self.w.status.mode, Some(mode_label(modem.current_modes.0, modem.current_modes.1)));
				show(&self.w.status.power, Some(names::power_state(modem.power_state)));
				let firmware = match (modem.model.is_empty(), modem.revision.is_empty()) {
					(_, true) => t!("Unknown"),
					(true, false) => modem.revision.clone(),
					(false, false) => t!("{} {}", &modem.model, &modem.revision),
				};
				show(&self.w.status.firmware, Some(firmware));
				self.render_network(modem, threegpp);
			}
			Err(error) => {
				show(&self.w.status.state, Some(t!("Not available: {}", error)));
				for listed in [
					&self.w.status.operator,
					&self.w.status.access,
					&self.w.status.signal,
					&self.w.status.registration,
					&self.w.status.packet,
					&self.w.status.eps,
					&self.w.status.mode,
					&self.w.status.power,
					&self.w.status.firmware,
				] {
					show(listed, None);
				}
				show(&self.w.status.rejection, None);
				self.w.status.rejection.set_visible(false);
			}
		}
		self.w.status.banner.set_revealed(refused);
		self.w.network.banner.set_revealed(refused);
		self.render_saved(snapshot);
		self.render_data(snapshot);
	}

	/// The lists of the Network page. The network modes are only those
	/// ModemManager says the modem takes: it refuses any other pair with "not
	/// supported". They show the modem unless the user changed them.
	fn render_network(&mut self, modem: &mm::Modem, threegpp: &mm::Modem3gpp) {
		let supported = |allowed: u32, preferred: u32| {
			modem
				.supported_modes
				.iter()
				.any(|&(all, none)| (all == u32::MAX && none == 0) || (all == allowed && none == preferred))
		};
		if *self.w.network.listed_for.borrow() != modem.supported_modes {
			let presets: Vec<Preset> = modemmode::PRESETS
				.iter()
				.copied()
				.filter(|preset| supported(preset.allowed, preset.preferred.map_or(0, Rat::bit)))
				.collect();
			let labels: Vec<String> = presets
				.iter()
				.map(|preset| mode_label(preset.allowed, preset.preferred.map_or(0, Rat::bit)))
				.collect();
			self.updating.set(true);
			ui::set_list(&self.w.network.mode, &labels);
			self.updating.set(false);
			self.presets = presets;
			*self.w.network.listed_for.borrow_mut() = modem.supported_modes.clone();
			self.dirty = false;
			self.w.network.apply.set_sensitive(false);
		}
		if !self.dirty {
			self.updating.set(true);
			let place = usize::try_from(self.ue_mode(threegpp)).unwrap_or(0).saturating_sub(1).min(3);
			self.w.network.eps.set_selected(place as u32);
			if let Some(wanted) = Preset::index_of(modem.current_modes.0, modem.current_modes.1).map(|index| modemmode::PRESETS[index]) {
				if let Some(at) = self.presets.iter().position(|preset| *preset == wanted) {
					self.w.network.mode.set_selected(at as u32);
				}
			}
			self.updating.set(false);
		}
		self.w.network.explain.set_text(&ui::explain_eps(self.w.network.eps.selected()));
		self.explain_mode();
		// What the list leaves out, and why: ModemManager refuses a pair it
		// does not list for the modem. This modem lists 28 pairs: 2G alone
		// and 3G alone without a preference, and the rest each with one
		// preferred technology. So it has neither 4G and 5G on their own nor
		// a combination of several technologies without a preferred one;
		// other modems list both.
		let has = |rat: Rat| modem.supported_modes.iter().any(|(allowed, _)| allowed & rat.bit() != 0);
		let alone = [(8, 0), (16, 0), (8 | 16, 16), (8 | 16, 8), (8 | 16, 0)]
			.iter()
			.all(|&(allowed, preferred)| !supported(allowed, preferred));
		let no_preference = modemmode::PRESETS.iter().any(|preset| {
			// more than one technology in the mask
			let several = preset.allowed & (preset.allowed - 1) != 0;
			several && preset.preferred.is_none() && !supported(preset.allowed, 0)
		});
		let text = match (has(Rat::G4) && has(Rat::G5) && alone, no_preference) {
			(true, true) => t!(
				"4G on its own, 5G on its own, 4G with 5G, and a combination of several \
				 technologies without a preferred one are missing from this list: \
				 ModemManager does not offer them for this modem, and refuses them."
			),
			(true, false) => t!(
				"4G on its own, 5G on its own and 4G with 5G are missing from this list: \
				 ModemManager does not offer them for this modem, and refuses them."
			),
			(false, true) => t!(
				"A combination of several technologies without a preferred one is missing \
				 from this list: ModemManager does not offer it for this modem, and refuses \
				 it."
			),
			(false, false) => String::new(),
		};
		self.w.network.alone.set_visible(!text.is_empty());
		self.w.network.alone.set_text(&text);
	}

	/// What the network mode selected means.
	fn explain_mode(&mut self) {
		let Some(preset) = self.presets.get(self.w.network.mode.selected() as usize) else {
			return;
		};
		let technologies: Vec<&str> = Rat::ALL
			.iter()
			.filter(|rat| preset.allowed & rat.bit() != 0)
			.map(|rat| rat.name())
			.collect();
		let text = match preset.preferred {
			Some(preferred) => t!("The phone may use {}, and looks for {} first.", technologies.join(", "), preferred.name()),
			None if technologies.len() == 1 => t!("The phone uses only {}.", technologies[0]),
			None => t!("The phone may use {}, in whatever order the modem searches.", technologies.join(", ")),
		};
		self.w.network.mode_explain.set_text(&text);
	}

	/// The file for the next boot: whether there is one, and what it says.
	fn render_saved(&mut self, snapshot: &Snapshot) {
		let available = persist::available();
		self.w.network.keep.set_visible(available);
		let mut forget = false;
		let text = match (&snapshot.saved, available) {
			(_, false) => t!("Not on this device: diting-modem-setup is not installed."),
			(Err(error), true) => t!("Not readable: {}", error),
			(Ok(None), true) => t!("Nothing saved: the modem's own defaults apply at boot."),
			(Ok(Some(text)), true) => {
				forget = true;
				let mode = ModemMode::parse(text);
				let mut summary = mode_label(mode.mask(), mode.preferred.map_or(0, Rat::bit));
				if let Some(ue) = mode.usage.zip(mode.service_domain).and_then(|(usage, domain)| eps::mode(usage, domain)) {
					summary = t!("{}; {}", &summary, names::eps_ue_mode(ue));
				}
				summary
			}
		};
		show(&self.w.network.saved, Some(text));
		self.w.network.forget.set_visible(forget);
	}

	/// The Mobile data page.
	fn render_data(&mut self, snapshot: &Snapshot) {
		for listed in self.w.data.rows.borrow().iter() {
			self.w.data.list.remove(listed);
		}
		self.w.data.rows.borrow_mut().clear();
		match &snapshot.data {
			Ok(state) => {
				let device = match &state.device {
					// why, for the two states that leave the user asking
					Some(device) => match names::device_reason(device.reason) {
						Some(reason) if matches!(device.state, 20 | 120) => {
							t!("{}, {}: {}", &device.interface, names::device_state(device.state), reason)
						}
						_ => t!("{}, {}", &device.interface, names::device_state(device.state)),
					},
					None => t!("None: NetworkManager does not manage the modem"),
				};
				show(&self.w.data.device, Some(device));
				let active: Vec<String> = state
					.active
					.iter()
					.filter_map(|active| state.connections.iter().find(|profile| profile.path == active.connection))
					.filter_map(|profile| nm::string(&profile.settings, "connection", "id"))
					.collect();
				show(&self.w.data.active, Some(if active.is_empty() { t!("None") } else { active.join(", ") }));
				let first = state.connections.first();
				self.w.data.banner.set_revealed(first.is_some() && state.connections.len() > 1);
				if let Some(first) = first {
					let first = nm::string(&first.settings, "connection", "id").unwrap_or_default();
					self.w.data.banner.set_title(&t!(
						"More than one mobile data connection: the redial watchdog dials the first one, {}.",
						first
					));
				}
				for profile in &state.connections {
					let title = nm::string(&profile.settings, "connection", "id").unwrap_or_default();
					let item = ui::row(title);
					item.set_subtitle(&profile_line(profile, state));
					let active = state.active.iter().any(|active| active.connection == profile.path);
					let connect = ui::small_button(
						t!("Connect"),
						&["flat"],
						Msg::Activate(profile.path.clone()),
						self.tx.clone(),
					);
					connect.set_sensitive(!active);
					item.add_suffix(&connect);
					item.add_suffix(&ui::small_button(t!("Edit"), &["flat"], Msg::Edit(Some(profile.clone())), self.tx.clone()));
					item.add_suffix(&ui::small_button(
						t!("Delete"),
						&["flat", "destructive-action"],
						Msg::DeleteAsk(profile.path.clone()),
						self.tx.clone(),
					));
					self.w.data.list.add(&item);
					self.w.data.rows.borrow_mut().push(item);
				}
			}
			Err(error) => {
				show(&self.w.data.device, None);
				show(&self.w.data.active, None);
				self.w.data.banner.set_title(&t!("NetworkManager is not available: {}", error));
				self.w.data.banner.set_revealed(true);
			}
		}
	}

	fn profile(&self, path: &str) -> Option<&nm::Profile> {
		self.current.as_ref()?.data.as_ref().ok()?.connections.iter().find(|profile| profile.path == path)
	}

	fn modem_device(&self) -> Option<String> {
		self.current.as_ref()?.data.as_ref().ok()?.device.as_ref().map(|device| device.path.clone())
	}

	/// `CELLULAR_SETTINGS_SNAPSHOT=DIR[/NAME@PAGE]`: after the first reading the
	/// page is written to DIR/NAME.png (NAME is the page unless given) and the
	/// application quits. A window takes a moment to be drawn, and under a
	/// locked screen the compositor stops showing it after a few seconds: so
	/// the page is shown from the start and tried a few times in a row.
	fn start_snapshot(&mut self) {
		let Some(target) = self.snapshot.clone() else {
			return;
		};
		if self.snapshot_started {
			return;
		}
		self.snapshot_started = true;
		let (directory, name) = match target.rsplit_once('@') {
			Some((directory, name)) => (directory.to_string(), name.to_string()),
			None => (target.clone(), ui::PAGES[0].to_string()),
		};
		let page: &'static str = ui::PAGES.iter().find(|page| **page == name).copied().unwrap_or(ui::PAGES[0]);
		self.w.stack.set_visible_child_name(page);
		let win = self.win.clone();
		let app = self.app.clone();
		let mut tries = 0u32;
		glib::timeout_add_local(std::time::Duration::from_millis(900), move || {
			tries += 1;
			if !ui::shoot(&win, &directory, page) && tries < 8 {
				return glib::ControlFlow::Continue;
			}
			app.quit();
			glib::ControlFlow::Break
		});
	}
}
