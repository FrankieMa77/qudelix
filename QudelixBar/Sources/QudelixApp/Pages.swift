import CGtk
import QudelixBar
import QudelixGtk

enum AppPage: String, CaseIterable {
    case device
    case eq
    case presets
    case library
    case tune
    case stage
    case level

    var entry: NavigationEntry {
        NavigationPages.entry(for: rawValue) ?? NavigationPages.entries[0]
    }

    var title: String { entry.title }
    var icon: String { entry.icon }
    var summary: String { entry.summary }

    var needsAudio: Bool {
        switch self {
        case .stage, .level: return true
        default: return false
        }
    }
}

@MainActor
func makePlaceholder(for page: AppPage, audio: AudioStack?) -> UnsafeMutablePointer<GtkWidget> {
    let status = adw_status_page_new()!
    adw_status_page_set_title(status.opaque, page.title)
    if page.needsAudio, audio?.available != true {
        adw_status_page_set_description(status.opaque, AudioStack.unavailableMessage)
        adw_status_page_set_icon_name(status.opaque, "dialog-warning-symbolic")
    } else {
        adw_status_page_set_description(status.opaque, page.summary)
        adw_status_page_set_icon_name(status.opaque, page.icon)
    }
    return status.widget
}
