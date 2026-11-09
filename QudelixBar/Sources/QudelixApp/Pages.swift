import CGtk
import QudelixGtk

enum AppPage: String, CaseIterable {
    case device
    case eq
    case presets
    case library

    var title: String {
        switch self {
        case .device: return "Device"
        case .eq: return "EQ"
        case .presets: return "Presets"
        case .library: return "Library"
        }
    }

    var icon: String {
        switch self {
        case .device: return "audio-headphones-symbolic"
        case .eq: return "media-playlist-shuffle-symbolic"
        case .presets: return "view-list-symbolic"
        case .library: return "folder-symbolic"
        }
    }

    var summary: String {
        switch self {
        case .device: return "Connection, volume and output settings"
        case .eq: return "Equalizer curve and band controls"
        case .presets: return "Presets stored on the device"
        case .library: return "Local presets, AutoEq and AI suggestions"
        }
    }
}

func makePlaceholder(for page: AppPage) -> UnsafeMutablePointer<GtkWidget> {
    let status = adw_status_page_new()!
    adw_status_page_set_title(status.opaque, page.title)
    adw_status_page_set_description(status.opaque, page.summary)
    adw_status_page_set_icon_name(status.opaque, page.icon)
    return status.widget
}
