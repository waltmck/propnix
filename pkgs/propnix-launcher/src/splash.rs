//! The GTK4 startup splash. Shown while the game cold-starts; dismissed on DXVK's first-present marker (or
//! a timeout / game exit). Closing it before first-present cancels startup. The launcher process outlives
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

pub fn run(name: String, icon: Option<String>, rx: Receiver<Progress>) -> i32 {
    let app = Application::builder()
        // NON_UNIQUE: each launcher process is independent — WE own single-instance (the flock in
        // focus.rs), not GtkApplication's D-Bus registration.
        .application_id("org.propnix.launcher")
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
        "spinner { color: #ffffff; }",
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
            img.set_pixel_size(128);
            vbox.append(&img);
        }
    }

    let title = gtk::Label::new(None);
    title.set_markup(&format!(
        "<span size='x-large' weight='bold'>{}</span>",
        glib::markup_escape_text(name)
    ));
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
        .default_width(260)
        .default_height(360)
        .build();
    window.set_child(Some(&vbox));

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
                Ok(Progress::Failed(msg)) => {
                    eprintln!("propnix: {msg}");
                    exit_code.set(1);
                    app.quit();
                    return glib::ControlFlow::Break;
                }
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
