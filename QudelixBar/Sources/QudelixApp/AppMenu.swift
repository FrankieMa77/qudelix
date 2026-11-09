import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
enum AppMenu {
    private static var button: UnsafeMutablePointer<GtkWidget>?
    private static var autostartAction: OpaquePointer?
    private static var aboutDialog: UnsafeMutableRawPointer?
    private static let autostart = AutostartFile.system()

    static var popover: UnsafeMutableRawPointer? {
        button.flatMap { gtk_menu_button_get_popover($0.opaque) }.map { UnsafeMutableRawPointer($0) }
    }

    static var currentAboutDialog: UnsafeMutableRawPointer? { aboutDialog }

    nonisolated static func installOnMain(application: some GPointer) {
        MainActor.assumeIsolated {
            install(actionsOn: application, parent: { AppWindow.mainWindow })
        }
    }

    static func install(actionsOn application: some GPointer, parent: @escaping () -> UnsafeMutablePointer<GtkWidget>?) {
        let state = g_variant_new_boolean(autostart.isEnabled ? 1 : 0)
        let toggle = g_simple_action_new_stateful("autostart", nil, state)!
        Signals.onChangeState(toggle) { requested in
            onMain {
                let applied = autostart.set(requested)
                let effective = applied ? requested : autostart.isEnabled
                g_simple_action_set_state(toggle, g_variant_new_boolean(effective ? 1 : 0))
            }
        }
        g_action_map_add_action(application.opaque, toggle.opaque)
        autostartAction = toggle.opaque

        let about = g_simple_action_new("about", nil)!
        Signals.onActivate(about) { onMain { presentAbout(parent: parent()) } }
        g_action_map_add_action(application.opaque, about.opaque)
    }

    static func makeButton() -> UnsafeMutablePointer<GtkWidget> {
        let root = g_menu_new()!
        let startup = g_menu_new()!
        g_menu_append(startup, "Start at Login", "app.autostart")
        g_menu_append_section(root, nil, UnsafeMutableRawPointer(startup).assumingMemoryBound(to: GMenuModel.self))
        let general = g_menu_new()!
        g_menu_append(general, "About Qudelix", "app.about")
        g_menu_append(general, "Quit", "app.quit")
        g_menu_append_section(root, nil, UnsafeMutableRawPointer(general).assumingMemoryBound(to: GMenuModel.self))

        let created = gtk_menu_button_new()!
        let typed = created.opaque
        gtk_menu_button_set_icon_name(typed, "open-menu-symbolic")
        gtk_menu_button_set_primary(typed, 1)
        gtk_menu_button_set_menu_model(typed, UnsafeMutableRawPointer(root).assumingMemoryBound(to: GMenuModel.self))
        gtk_widget_set_tooltip_text(created, "Main menu")
        Accessible.setLabel(created, "Main menu")
        button = created
        return created
    }

    static func open() {
        guard let button else { return }
        gtk_menu_button_popup(button.opaque)
    }

    static func presentAbout(parent: UnsafeMutablePointer<GtkWidget>?) {
        guard let created = adw_about_dialog_new() else { return }
        let dialog = OpaquePointer(created)
        adw_about_dialog_set_application_name(dialog, AppInfo.name)
        adw_about_dialog_set_application_icon(dialog, AppIcon.available ? AppInfo.identifier : TrayMenuBuilder.iconName)
        adw_about_dialog_set_version(dialog, AppInfo.version)
        adw_about_dialog_set_comments(dialog, "Settings, equalizer and presets for the Qudelix 5K.")
        adw_about_dialog_set_website(dialog, AppInfo.website)
        adw_about_dialog_set_issue_url(dialog, AppInfo.issues)
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        aboutDialog = UnsafeMutableRawPointer(created)
        adw_dialog_present(created, parent)
    }
}
