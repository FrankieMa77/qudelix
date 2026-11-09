import CGtk
import QudelixBar

@MainActor
enum AppIcon {
    static var available: Bool {
        guard let display = gdk_display_get_default(),
              let theme = gtk_icon_theme_get_for_display(display) else { return false }
        return gtk_icon_theme_has_icon(theme, AppInfo.identifier) != 0
    }

    static func trayName() -> String {
        available ? TrayMenuBuilder.appIconName : TrayMenuBuilder.iconName
    }

    static func installWindowDefault() {
        guard available else { return }
        gtk_window_set_default_icon_name(AppInfo.identifier)
    }
}
