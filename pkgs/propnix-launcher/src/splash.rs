//! The GTK4 startup splash. Shown while the game cold-starts; dismissed on the first-present marker of
//! whichever backend is active (DXVK, vkd3d, or wined3d) OR when the game window first maps (the compositor
//! window-watcher, for backends/titles that emit no marker) — or a timeout / game exit. Closing it before
//! first-present cancels startup. The launcher process outlives
//! the game (it holds the single-instance lock + drives teardown), so the GTK loop stays alive after the
//! splash is hidden and quits only when the worker reports the game exited.

use crate::run::Progress;
use gtk4 as gtk;
use gtk::prelude::*;
use gtk::{gio, glib, Application, ApplicationWindow};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::time::Duration;

/// Fixed splash window width (px). The window is FORCED to this width via `set_size_request`, so its size
/// no longer tracks the title's length: a long title WRAPS onto multiple lines (see `SPLASH_WRAP_CHARS`)
/// and grows the window TALLER, never wider. Comfortably fits the current short titles on one line.
const SPLASH_WIDTH: i32 = 300;
/// Wrap cap for the title, in characters. Tuned so a wrapped title fits within `SPLASH_WIDTH` minus the
/// vbox's 32px start/end margins (~236px of content). Without a cap a wrapping label still *requests* its
/// full single-line width, and the non-resizable window would grow to fit it — so this is what actually
/// forces the wrap. Kept conservative so the title's natural width can never exceed the window.
const SPLASH_WRAP_CHARS: i32 = 16;

pub fn run(app_id: String, name: String, icon: Option<String>, rx: Receiver<Progress>) -> i32 {
    let app = Application::builder()
        // The game's `org.propnix.<appid>` id (also the game's `.desktop` basename): GTK sets it as the
        // Wayland toplevel app_id, so the compositor maps the splash to the SAME desktop entry — and thus
        // the same icon — as the game window. NON_UNIQUE: each launcher process is independent — WE own
        // single-instance (the flock in focus.rs), not GtkApplication's D-Bus registration.
        .application_id(&app_id)
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();

    let exit_code = Rc::new(Cell::new(0i32));
    let rx_holder = Rc::new(RefCell::new(Some(rx)));

    {
        let exit_code = exit_code.clone();
        app.connect_activate(move |app| {
            build_splash(app, &name, &icon, &rx_holder, &exit_code);
        });
    }

    app.run_with_args(&["propnix-launcher"]);
    exit_code.get()
}

fn build_splash(
    app: &Application,
    name: &str,
    icon: &Option<String>,
    rx_holder: &Rc<RefCell<Option<Receiver<Progress>>>>,
    exit_code: &Rc<Cell<i32>>,
) {
    // Force a black splash (#000000 bg, light foreground) regardless of the system light/dark theme.
    let css = gtk::CssProvider::new();
    // load_from_data (baseline &str API); load_from_string is v4_12-gated and we don't enable that feature.
    css.load_from_data(concat!(
        "window { background-color: #000000; } ",
        "label { color: #ffffff; } ",
        "spinner { color: #ffffff; } ",
        // Rounded corners on the splash icon (clipped via the widget's `overflow: hidden` below).
        ".splash-icon { border-radius: 16px; }",
    ));
    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    // Portrait proportions: taller than wide (a stacked icon → title → spinner → status column).
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 20);
    vbox.set_margin_top(44);
    vbox.set_margin_bottom(44);
    vbox.set_margin_start(32);
    vbox.set_margin_end(32);
    vbox.set_valign(gtk::Align::Center);
    vbox.set_halign(gtk::Align::Center);

    if let Some(path) = icon {
        if std::path::Path::new(path).exists() {
            let img = gtk::Image::from_file(path);
            // Fixed, contained size: a large extracted PE icon must not overflow/clip the small splash
            // window (was 128 with no size cap → oversized + truncated on some games).
            img.set_pixel_size(96);
            img.set_size_request(96, 96);
            // Centre the icon within its frame explicitly (don't rely on the default fill alignment), so the
            // glyph sits mid-frame regardless of its source aspect ratio.
            img.set_halign(gtk::Align::Center);
            img.set_valign(gtk::Align::Center);
            // Clip the icon to rounded corners: a wrapper Box with `overflow: hidden` + the .splash-icon
            // border-radius rounds the child image (overflow reliably clips children).
            let frame = gtk::Box::new(gtk::Orientation::Vertical, 0);
            frame.set_halign(gtk::Align::Center);
            frame.set_valign(gtk::Align::Center);
            frame.set_size_request(96, 96);
            frame.add_css_class("splash-icon");
            frame.set_overflow(gtk::Overflow::Hidden);
            frame.append(&img);
            vbox.append(&frame);
        }
    }

    let title = gtk::Label::new(None);
    title.set_markup(&format!(
        "<span size='x-large' weight='bold'>{}</span>",
        glib::markup_escape_text(name)
    ));
    // Constant-width splash: a long title WRAPS onto multiple lines (the window grows taller) rather than
    // widening the window. `set_max_width_chars` caps the label's natural width so it wraps — a bare
    // `set_wrap(true)` label still requests its full single-line width, which the non-resizable window
    // would grow to fit. `hexpand` lets the label fill the fixed-width column so the centred, wrapped text
    // sits mid-window.
    title.set_wrap(true);
    title.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    title.set_justify(gtk::Justification::Center);
    title.set_max_width_chars(SPLASH_WRAP_CHARS);
    title.set_hexpand(true);
    vbox.append(&title);

    let spinner = gtk::Spinner::new();
    spinner.set_size_request(36, 36);
    spinner.start();
    vbox.append(&spinner);

    let status = gtk::Label::new(Some("Starting…"));
    status.add_css_class("dim-label");
    vbox.append(&status);

    let window = ApplicationWindow::builder()
        .application(app)
        .title(name)
        .resizable(false)
        .decorated(false)
        .default_width(SPLASH_WIDTH)
        .default_height(360)
        .build();
    window.set_child(Some(&vbox));
    // Pin the width: a non-resizable window sizes to its content's natural size, so without this floor the
    // width would still track the title. With the title's natural width capped (above), forcing the window
    // minimum width to SPLASH_WIDTH makes the width CONSTANT across title lengths — only the height grows.
    window.set_size_request(SPLASH_WIDTH, -1);

    // Closing the splash before first-present cancels startup: flag the worker, hide the window, and keep
    // it (return Stop) so the app stays alive until the worker's Exited(130) drives the quit.
    window.connect_close_request(move |w| {
        crate::signals::cancel();
        w.set_visible(false);
        glib::Propagation::Stop
    });

    window.present();

    // Poll the worker channel on the GTK main loop.
    let rx = rx_holder
        .borrow_mut()
        .take()
        .expect("activate fires exactly once");
    let app = app.clone();
    let window = window.clone();
    let exit_code = exit_code.clone();
    glib::timeout_add_local(Duration::from_millis(100), move || {
        loop {
            match rx.try_recv() {
                Ok(Progress::Presented) => window.set_visible(false),
                Ok(Progress::Exited(code)) => {
                    exit_code.set(code);
                    app.quit();
                    return glib::ControlFlow::Break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    app.quit();
                    return glib::ControlFlow::Break;
                }
            }
        }
        glib::ControlFlow::Continue
    });
}
