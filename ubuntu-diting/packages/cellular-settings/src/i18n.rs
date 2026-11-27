//! Translations through gettext: the system's own libintl, the domain and the
//! directory the package installs the catalogs under. `CELLULAR_LOCALEDIR` at
//! build time moves that directory, to try a catalog from the tree.
//!
//! Every string the user sees is written as `t!("...")`: the script
//! `po/update-pot.py` collects those literals into the template.
//!
//! The crate of the catalogs is gettext-rs, whose library is `gettextrs`; with
//! its `gettext-system` feature it uses the libintl of glibc, nothing else.

use gettextrs::{bind_textdomain_codeset, bindtextdomain, setlocale, textdomain, LocaleCategory};

pub const DOMAIN: &str = "cellular-settings";

pub const LOCALEDIR: &str = match option_env!("CELLULAR_LOCALEDIR") {
	Some(dir) => dir,
	None => "/usr/share/locale",
};

pub fn init() {
	// what the locale is decides which catalog is used; none of this can fail
	// in a way the window could do anything about
	let _ = setlocale(LocaleCategory::LcAll, "");
	let _ = bindtextdomain(DOMAIN, LOCALEDIR);
	let _ = bind_textdomain_codeset(DOMAIN, "UTF-8");
	let _ = textdomain(DOMAIN);
}

/// `t!("{} of {} connected", n, total)`: each `{}` of the translated text
/// takes the next argument.
pub fn fill(template: String, args: &[&dyn std::fmt::Display]) -> String {
	let mut out = String::with_capacity(template.len() + 32);
	let mut rest = template.as_str();
	for arg in args {
		match rest.split_once("{}") {
			Some((before, after)) => {
				out.push_str(before);
				out.push_str(&arg.to_string());
				rest = after;
			}
			None => break,
		}
	}
	out.push_str(rest);
	out
}

#[macro_export]
macro_rules! t {
	($s:expr) => {
		gettextrs::gettext($s)
	};
	($s:expr, $($arg:expr),+ $(,)?) => {
		crate::i18n::fill(gettextrs::gettext($s), &[$(&$arg as &dyn std::fmt::Display),+])
	};
}

#[cfg(test)]
mod tests {
	use super::fill;

	#[test]
	fn fill_takes_the_arguments_in_order() {
		let a = 2;
		let b = String::from("x");
		assert_eq!(fill("{} of {}".to_string(), &[&a, &b]), "2 of x");
		assert_eq!(fill("none".to_string(), &[&a]), "none");
		assert_eq!(fill("one {}".to_string(), &[&a, &b]), "one 2");
	}
}
