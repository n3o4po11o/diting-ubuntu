//! The window: three pages in a view stack under one toolbar, and a toast or
//! a dialog for every answer. The widgets send `Msg`s; `main.rs` owns the
//! thread of the window and decides what each one means.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use async_channel::Sender;

use crate::t;
use crate::{nm, Msg};

/// The pages of the view stack, by name.
pub const STATUS: &str = "status";
pub const NETWORK: &str = "network";
pub const DATA: &str = "data";
pub const PAGES: [&str; 3] = [STATUS, NETWORK, DATA];

/// The EPS "UE mode of operation", in the order of the list: the numbers
/// ModemManager gives them are one more than the place in the list.
pub const EPS_NAMES: [&str; 4] = [
	"EPS only, voice-centric",
	"EPS only, data-centric",
	"EPS and non-EPS, voice-centric",
	"EPS and non-EPS, data-centric",
];

pub struct Status {
	pub banner: adw::Banner,
	pub state: adw::ActionRow,
	pub operator: adw::ActionRow,
	pub access: adw::ActionRow,
	pub signal: adw::ActionRow,
	pub registration: adw::ActionRow,
	pub packet: adw::ActionRow,
	pub rejection: adw::ActionRow,
	pub eps: adw::ActionRow,
	pub mode: adw::ActionRow,
	pub power: adw::ActionRow,
	pub firmware: adw::ActionRow,
}

pub struct Network {
	pub banner: adw::Banner,
	pub eps: adw::ComboRow,
	/// what the EPS mode selected means, in plain words
	pub explain: gtk::Label,
	pub mode: adw::ComboRow,
	/// what the network mode selected means
	pub mode_explain: gtk::Label,
	/// shown when the modem has 4G and 5G and they cannot be chosen alone
	pub alone: gtk::Label,
	/// the combinations of technologies the list was made for; empty until it is
	pub listed_for: Rc<RefCell<Vec<(u32, u32)>>>,
	pub apply: gtk::Button,
	pub keep: adw::SwitchRow,
	pub saved: adw::ActionRow,
	pub forget: gtk::Button,
}

pub struct Data {
	pub device: adw::ActionRow,
	pub active: adw::ActionRow,
	pub banner: adw::Banner,
	pub list: adw::PreferencesGroup,
	/// the rows of the connections, the last ones listed
	pub rows: RefCell<Vec<adw::ActionRow>>,
}

pub struct Widgets {
	pub toast: adw::ToastOverlay,
	pub stack: adw::ViewStack,
	/// the pages as tabs under the content: in a window narrower than 500 sp
	pub switcher_bottom: adw::ViewSwitcher,
	/// the same tabs in the header bar: from 500 sp (main.rs adds the breakpoint)
	pub switcher_top: adw::ViewSwitcher,
	/// the title of the window in the header bar, where the tabs are not
	pub title: gtk::Label,
	pub status: Status,
	pub network: Network,
	pub data: Data,
}

/// A row with a title, and a subtitle that wraps instead of being cut.
pub fn row(title: String) -> adw::ActionRow {
	adw::ActionRow::builder()
		.title(title)
		.title_lines(1)
		.subtitle_lines(0)
		.use_markup(false)
		.build()
}

fn group(title: String) -> adw::PreferencesGroup {
	adw::PreferencesGroup::builder().title(title).build()
}

/// A page: its widgets in one column, narrow enough to read on a phone, and
/// scrolling when the window is shorter than it is. A window is never
/// smaller than its content, and without the scrolling the Network page
/// made it 906 high: on its side the phone has 610, and the tabs under the
/// content were below the screen (2026-11-27).
fn page(children: &[&gtk::Widget]) -> gtk::ScrolledWindow {
	let column = gtk::Box::builder()
		.orientation(gtk::Orientation::Vertical)
		.spacing(12)
		.margin_top(12)
		.margin_bottom(24)
		.margin_start(12)
		.margin_end(12)
		.build();
	for child in children {
		column.append(*child);
	}
	let clamp = adw::Clamp::builder().maximum_size(600).tightening_threshold(480).build();
	clamp.set_child(Some(&column));
	gtk::ScrolledWindow::builder()
		.hscrollbar_policy(gtk::PolicyType::Never)
		.vscrollbar_policy(gtk::PolicyType::Automatic)
		.child(&clamp)
		.build()
}

/// A paragraph under the lists, in the dim colour of a note.
fn note_label(text: String) -> gtk::Label {
	gtk::Label::builder()
		.label(text)
		.wrap(true)
		.xalign(0.0)
		.use_markup(false)
		.css_classes(["dim-label"])
		.margin_start(12)
		.margin_end(12)
		.build()
}

/// What the selected EPS mode means, in plain words. The number is the
/// place in the list.
pub fn explain_eps(selected: u32) -> String {
	match selected {
		0 => t!(
			"EPS only, voice-centric: the phone uses only the 4G/5G network and puts calls \
			 first: where VoLTE is missing, it is not content with data alone. On a network \
			 without 2G/3G this does not help; the usual choice there is the next one."
		),
		1 => t!(
			"EPS only, data-centric: the phone uses only the 4G/5G network and puts data \
			 first. It stays registered on a carrier that has no 2G/3G network for this phone, \
			 such as China Telecom. Calls then need VoLTE: without it, no calls are possible."
		),
		2 => t!(
			"EPS and non-EPS, voice-centric: the phone uses 4G/5G and also the old 2G/3G \
			 network for calls and SMS, and puts calls first. This is the modem's own default. \
			 It is right where the carrier has a 2G/3G network. Where it has none, as with \
			 China Telecom, the registration drops every few minutes: the network refuses with \
			 “CS domain not available”."
		),
		3 => t!(
			"EPS and non-EPS, data-centric: the phone uses 4G/5G and the old 2G/3G network, \
			 and puts data first. Right where the carrier has a 2G/3G network and data matters \
			 more than calls. Where it has none, the registration drops every few minutes, as \
			 with the previous one."
		),
		_ => String::new(),
	}
}

/// The words of the EPS modes, explained once.
fn glossary() -> String {
	[
		t!("EPS: the 4G and 5G network. Everything on it is data."),
		t!(
			"Non-EPS, or the circuit-switched (CS) domain: the older 2G and 3G network, \
			 made for calls and SMS."
		),
		t!("PS only: the phone asks for data service only, so it registers on 4G/5G alone."),
		t!("CS and PS: the phone asks for calls and SMS as well, so it also registers on 2G/3G."),
		t!("Voice-centric: calls come first. The phone wants a network on which it can call."),
		t!(
			"Data-centric: data comes first. The phone stays on 4G/5G even where it \
			 could not call."
		),
		t!("VoLTE: calls over the 4G/5G network, with no 2G/3G network behind them."),
	]
	.join("\n\n")
}

/// A button to the right of a row, and what it says when pressed.
pub fn small_button(label: String, styles: &'static [&'static str], message: Msg, tx: Sender<Msg>) -> gtk::Button {
	let button = gtk::Button::builder()
		.label(label)
		.valign(gtk::Align::Center)
		.css_classes(styles)
		.build();
	button.connect_clicked(move |_| {
		let _ = tx.send_blocking(message.clone());
	});
	button
}

/// What a list of choices shows, in this order.
pub fn set_list(item: &adw::ComboRow, names: &[String]) {
	let words: Vec<&str> = names.iter().map(String::as_str).collect();
	item.set_model(Some(&gtk::StringList::new(&words)));
}

/// `CELLULAR_SETTINGS_SNAPSHOT`: the window as a PNG, without a hand on the
/// phone. False when the window has nothing drawn yet: not mapped, or just
/// turned to; the caller tries again.
pub fn shoot(window: &adw::ApplicationWindow, directory: &str, name: &str) -> bool {
	let paintable = gtk::WidgetPaintable::new(Some(window));
	let snapshot = gtk::Snapshot::new();
	paintable.snapshot(&snapshot, window.width().max(1) as f64, window.height().max(1) as f64);
	let Some(node) = snapshot.to_node() else {
		return false;
	};
	let Some(renderer) = window.renderer() else {
		eprintln!("snapshot {name}: no renderer");
		return true;
	};
	let texture = renderer.render_texture(&node, None);
	let path = format!("{directory}/{name}.png");
	match texture.save_to_png(&path) {
		Ok(()) => {
			eprintln!("snapshot written: {path}");
			true
		}
		Err(error) => {
			eprintln!("snapshot {name}: {error}");
			true
		}
	}
}

/// A reason to be read whole: a toast would cut it to one line.
pub fn failure(parent: &adw::ApplicationWindow, text: String) {
	let dialog = adw::AlertDialog::builder()
		.heading(t!("Not done"))
		.body(text)
		.build();
	dialog.add_response("close", &t!("Close"));
	dialog.set_default_response(Some("close"));
	dialog.set_close_response("close");
	dialog.present(Some(parent));
}

pub fn build(tx: Sender<Msg>, updating: Rc<Cell<bool>>) -> Widgets {
	let toast = adw::ToastOverlay::new();
	let toolbar = adw::ToolbarView::new();
	let stack = adw::ViewStack::new();

	// The header shows the title, or, from 500 sp wide, the pages as tabs:
	// main.rs adds the breakpoint that switches. A GtkBox measures only its
	// visible children, so the title does not reserve the tabs' width.
	let header = adw::HeaderBar::new();
	let titles = gtk::Box::builder().orientation(gtk::Orientation::Horizontal).build();
	let title = gtk::Label::builder()
		.label(t!("Cellular Settings"))
		.single_line_mode(true)
		.ellipsize(gtk::pango::EllipsizeMode::End)
		.css_classes(["title"])
		.build();
	titles.append(&title);
	let switcher_top =
		adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Wide).visible(false).build();
	titles.append(&switcher_top);
	header.set_title_widget(Some(&titles));
	toolbar.add_top_bar(&header);
	// under the content in a narrow window
	let switcher_bottom = adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Narrow).build();
	toolbar.add_bottom_bar(&switcher_bottom);

	let (status, status_page) = status_page(tx.clone());
	stack.add_titled_with_icon(&status_page, Some(STATUS), &t!("Status"), "dialog-information-symbolic");
	let (network, network_page) = network_page(tx.clone(), updating);
	stack.add_titled_with_icon(&network_page, Some(NETWORK), &t!("Network"), "network-cellular-symbolic");
	let (data, data_page) = data_page(tx);
	stack.add_titled_with_icon(&data_page, Some(DATA), &t!("Mobile data"), "network-transmit-receive-symbolic");

	toolbar.set_content(Some(&stack));
	toast.set_child(Some(&toolbar));
	Widgets { toast, stack, switcher_bottom, switcher_top, title, status, network, data }
}

fn status_page(tx: Sender<Msg>) -> (Status, gtk::ScrolledWindow) {
	let banner = adw::Banner::builder()
		.title(t!(
			"The network refused this modem because it has no 2G/3G network for it. \
			 “EPS only, data-centric” on the Network page keeps the registration up; \
			 calls then need VoLTE."
		))
		.button_label(t!("Network page"))
		.revealed(false)
		.build();
	banner.connect_button_clicked(move |_| {
		let _ = tx.send_blocking(Msg::ShowPage(NETWORK));
	});
	let status = Status {
		banner: banner.clone(),
		state: row(t!("State")),
		operator: row(t!("Operator")),
		access: row(t!("Access technology")),
		signal: row(t!("Signal quality")),
		registration: row(t!("Registration")),
		packet: row(t!("Packet service")),
		rejection: row(t!("Network rejection")),
		eps: row(t!("EPS UE mode of operation")),
		mode: row(t!("Network mode")),
		power: row(t!("Power")),
		firmware: row(t!("Firmware")),
	};
	let modem = group(t!("Modem"));
	modem.add(&status.state);
	modem.add(&status.operator);
	modem.add(&status.access);
	modem.add(&status.signal);
	modem.add(&status.power);
	modem.add(&status.firmware);
	let network = group(t!("Network"));
	network.add(&status.registration);
	network.add(&status.packet);
	network.add(&status.rejection);
	network.add(&status.eps);
	network.add(&status.mode);
	(status, page(&[banner.upcast_ref(), modem.upcast_ref(), network.upcast_ref()]))
}

fn network_page(tx: Sender<Msg>, updating: Rc<Cell<bool>>) -> (Network, gtk::ScrolledWindow) {
	let banner = adw::Banner::builder()
		.title(t!(
			"The network has no 2G/3G network for this modem. “EPS only, data-centric” \
			 keeps the registration up; calls then need VoLTE."
		))
		.revealed(false)
		.build();

	// how the phone asks for service
	let eps = adw::ComboRow::builder()
		.title(t!("EPS UE mode of operation"))
		.subtitle(t!("How the phone registers: for data only, or for calls and SMS as well."))
		.build();
	set_list(&eps, &EPS_NAMES.iter().map(|name| t!(*name)).collect::<Vec<_>>());
	let words = adw::ExpanderRow::builder()
		.title(t!("What these words mean"))
		.subtitle(t!("EPS, CS and PS, voice-centric, data-centric, VoLTE."))
		.build();
	let paper = gtk::Box::builder()
		.orientation(gtk::Orientation::Vertical)
		.margin_start(12)
		.margin_end(12)
		.margin_bottom(12)
		.build();
	let words_text = gtk::Label::builder()
		.label(glossary())
		.wrap(true)
		.xalign(0.0)
		.use_markup(false)
		.build();
	paper.append(&words_text);
	words.add_row(&paper);
	let service = group(t!("Network preference"));
	service.add(&eps);
	service.add(&words);
	let explain = note_label(explain_eps(0));

	let mode = adw::ComboRow::builder()
		.title(t!("Network mode"))
		.subtitle(t!("The technologies the phone may use, and the one it looks for first."))
		.build();
	set_list(&mode, &[]);
	let technologies = adw::PreferencesGroup::new();
	technologies.add(&mode);
	let mode_explain = note_label(String::new());
	// what the list of this modem leaves out; main.rs sets the text
	let alone = note_label(String::new());
	alone.set_visible(false);

	let tx_eps = tx.clone();
	let weak_explain = explain.downgrade();
	let changed = updating.clone();
	eps.connect_notify_local(Some("selected"), move |row, _| {
		if let Some(explain) = weak_explain.upgrade() {
			explain.set_text(&explain_eps(row.selected()));
		}
		if !changed.get() {
			let _ = tx_eps.send_blocking(Msg::Dirty);
		}
	});
	let tx_mode = tx.clone();
	let changed = updating.clone();
	mode.connect_notify_local(Some("selected"), move |_, _| {
		if !changed.get() {
			let _ = tx_mode.send_blocking(Msg::Dirty);
		}
	});

	let apply = gtk::Button::builder()
		.label(t!("Apply"))
		.css_classes(["suggested-action"])
		.halign(gtk::Align::Center)
		.sensitive(false)
		.build();
	let tx_apply = tx.clone();
	apply.connect_clicked(move |_| {
		let _ = tx_apply.send_blocking(Msg::Apply);
	});

	let keep = adw::SwitchRow::builder()
		.title(t!("Keep for next boot"))
		.subtitle(t!(
			"With Apply: write the choice to /etc/diting/modem-mode, which diting-modem-setup \
			 reads at every boot."
		))
		.build();
	let tx_keep = tx.clone();
	keep.connect_active_notify(move |row| {
		let _ = tx_keep.send_blocking(Msg::Keep(row.is_active()));
	});
	let saved = row(t!("Saved for next boot"));
	let forget = small_button(t!("Forget"), &["flat", "destructive-action"], Msg::Forget, tx);
	saved.add_suffix(&forget);
	let next_boot = group(t!("Next boot"));
	next_boot.add(&keep);
	next_boot.add(&saved);

	let note = note_label(t!(
		"Applied at once. The preferred technology is the order in which the modem searches \
		 for a network, so it shows at the next search."
	));
	let page = page(&[
		banner.upcast_ref(),
		service.upcast_ref(),
		explain.upcast_ref(),
		technologies.upcast_ref(),
		mode_explain.upcast_ref(),
		alone.upcast_ref(),
		apply.upcast_ref(),
		next_boot.upcast_ref(),
		note.upcast_ref(),
	]);
	let widgets = Network {
		banner: banner.clone(),
		eps,
		explain,
		mode,
		mode_explain,
		alone,
		listed_for: Rc::new(RefCell::new(Vec::new())),
		apply,
		keep,
		saved,
		forget,
	};
	(widgets, page)
}

fn data_page(tx: Sender<Msg>) -> (Data, gtk::ScrolledWindow) {
	let device = row(t!("Modem device"));
	let active = row(t!("Active connection"));
	let state = group(t!("Status"));
	state.add(&device);
	state.add(&active);
	let banner = adw::Banner::builder().revealed(false).build();
	let list = group(t!("Mobile data connections"));
	let new = adw::ButtonRow::builder()
		.title(t!("New connection"))
		.start_icon_name("list-add-symbolic")
		.build();
	let tx_new = tx.clone();
	new.connect_activated(move |_| {
		let _ = tx_new.send_blocking(Msg::Edit(None));
	});
	list.add(&new);
	let note = note_label(t!(
		"A connection that drops is dialled again by the redial watchdog, so there is no way \
		 to disconnect from here."
	));
	note.set_visible(std::path::Path::new("/usr/lib/diting/diting-modem-redial").is_file());
	let page = page(&[banner.upcast_ref(), state.upcast_ref(), list.upcast_ref(), note.upcast_ref()]);
	let widgets = Data { device, active, banner: banner.clone(), list, rows: RefCell::new(Vec::new()) };
	(widgets, page)
}

fn text_of<W: gtk::glib::object::ObjectExt>(widget: &W) -> String {
	widget.property::<Option<String>>("text").unwrap_or_default()
}

fn mark(widget: &impl IsA<gtk::Widget>, wrong: bool) {
	if wrong {
		widget.add_css_class("error");
	} else {
		widget.remove_css_class("error");
	}
}

/// The form of a connection: a new one, or the one at `existing`.
pub fn form_dialog(parent: &adw::ApplicationWindow, existing: Option<&nm::Profile>, tx: Sender<Msg>) {
	let form = existing.map(nm::form_of);
	let path = existing.map(|profile| profile.path.clone());
	let dialog = adw::Dialog::builder()
		.title(if existing.is_some() { t!("Edit connection") } else { t!("New connection") })
		.content_width(480)
		.build();

	let name = adw::EntryRow::builder().title(t!("Name")).build();
	let apn = adw::EntryRow::builder().title(t!("Access point name (APN)")).build();
	let username = adw::EntryRow::builder().title(t!("Username (optional)")).build();
	// the stored password is never shown: left empty, it stays as it is
	let password_title = if existing.is_some() {
		t!("Password (optional; unchanged unless you type one)")
	} else {
		t!("Password (optional)")
	};
	let password = adw::PasswordEntryRow::builder().title(password_title).build();
	let identity = group(t!("Identity"));
	let widgets: [&gtk::Widget; 4] = [name.upcast_ref(), apn.upcast_ref(), username.upcast_ref(), password.upcast_ref()];
	for widget in widgets {
		identity.add(widget);
	}

	let ip_type = adw::ComboRow::builder()
		.title(t!("IP type"))
		.subtitle(t!("Automatic lets the modem try IPv4 and IPv6, then each alone."))
		.build();
	set_list(&ip_type, &[t!("Automatic"), t!("IPv4"), t!("IPv6"), t!("IPv4 and IPv6")]);
	let autoconnect = adw::SwitchRow::builder()
		.title(t!("Connect automatically"))
		.subtitle(t!("As soon as the modem is registered."))
		.build();
	let retries = adw::SpinRow::with_range(1.0, 9.0, 1.0);
	retries.set_title(&t!("Dials before giving up"));
	retries.set_subtitle(&t!(
		"One leaves the retries to the redial watchdog and its back-off. Many in a row make \
		 the network throttle the modem for minutes."
	));
	let home_only = adw::SwitchRow::builder()
		.title(t!("Home network only"))
		.subtitle(t!("Do not register on other networks."))
		.build();
	let behaviour = group(t!("Behaviour"));
	let widgets: [&gtk::Widget; 4] = [ip_type.upcast_ref(), autoconnect.upcast_ref(), retries.upcast_ref(), home_only.upcast_ref()];
	for widget in widgets {
		behaviour.add(widget);
	}

	if let Some(form) = &form {
		name.set_property("text", &form.id);
		apn.set_property("text", &form.apn);
		username.set_property("text", &form.username);
		let place = nm::IpType::ALL.iter().position(|ip| *ip == form.ip_type).unwrap_or(0);
		ip_type.set_selected(place as u32);
		autoconnect.set_active(form.autoconnect);
		retries.set_value(f64::from(form.autoconnect_retries.clamp(1, 9)));
		home_only.set_active(form.home_only);
	}

	let cancel = gtk::Button::builder().label(t!("Cancel")).build();
	let weak_dialog = dialog.downgrade();
	cancel.connect_clicked(move |_| {
		if let Some(dialog) = weak_dialog.upgrade() {
			dialog.close();
		}
	});
	let save = gtk::Button::builder()
		.label(t!("Save"))
		.css_classes(["suggested-action"])
		.build();
	// the widgets are referenced weakly, so that the closure is not what keeps them alive
	let weak = (
		dialog.downgrade(),
		name.downgrade(),
		apn.downgrade(),
		username.downgrade(),
		password.downgrade(),
		ip_type.downgrade(),
		autoconnect.downgrade(),
		retries.downgrade(),
		home_only.downgrade(),
	);
	save.connect_clicked(move |_| {
		let (
			Some(dialog),
			Some(name),
			Some(apn),
			Some(username),
			Some(password),
			Some(ip_type),
			Some(autoconnect),
			Some(retries),
			Some(home_only),
		) = (
			weak.0.upgrade(),
			weak.1.upgrade(),
			weak.2.upgrade(),
			weak.3.upgrade(),
			weak.4.upgrade(),
			weak.5.upgrade(),
			weak.6.upgrade(),
			weak.7.upgrade(),
			weak.8.upgrade(),
		) else {
			return;
		};
		let id = text_of(&name);
		let apn_text = text_of(&apn);
		mark(&name, id.trim().is_empty());
		mark(&apn, apn_text.trim().is_empty());
		if id.trim().is_empty() || apn_text.trim().is_empty() {
			return;
		}
		let secret = text_of(&password);
		let form = nm::Form {
			id: id.trim().to_string(),
			apn: apn_text.trim().to_string(),
			ip_type: nm::IpType::ALL[(ip_type.selected() as usize).min(3)],
			autoconnect: autoconnect.is_active(),
			autoconnect_retries: retries.value() as i32,
			home_only: home_only.is_active(),
			username: text_of(&username).trim().to_string(),
			password: (!secret.is_empty()).then_some(secret),
		};
		dialog.close();
		let _ = tx.send_blocking(Msg::Form(Box::new(form), path.clone()));
	});
	let buttons = gtk::Box::builder()
		.orientation(gtk::Orientation::Horizontal)
		.spacing(12)
		.homogeneous(true)
		.margin_top(12)
		.margin_bottom(12)
		.margin_start(12)
		.margin_end(12)
		.build();
	buttons.append(&cancel);
	buttons.append(&save);
	let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
	content.append(&identity);
	content.append(&behaviour);
	content.append(&buttons);
	let scrolled = gtk::ScrolledWindow::builder()
		.hscrollbar_policy(gtk::PolicyType::Never)
		.vscrollbar_policy(gtk::PolicyType::Automatic)
		.propagate_natural_height(true)
		.max_content_height(640)
		.child(&content)
		.build();
	dialog.set_child(Some(&scrolled));
	dialog.present(Some(parent));
}

/// "Delete this one?" with Cancel as the way out.
pub fn confirm_delete(parent: &adw::ApplicationWindow, id: &str, path: &str, tx: Sender<Msg>) {
	let dialog = adw::AlertDialog::builder()
		.heading(t!("Delete “{}”?", id))
		.body(t!("The connection profile is removed from NetworkManager."))
		.build();
	dialog.add_response("cancel", &t!("Cancel"));
	dialog.add_response("delete", &t!("Delete"));
	dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
	dialog.set_default_response(Some("cancel"));
	dialog.set_close_response("cancel");
	let path = path.to_string();
	dialog.connect_response(None, move |_, response| {
		if response == "delete" {
			let _ = tx.send_blocking(Msg::Delete(path.clone()));
		}
	});
	dialog.present(Some(parent));
}
