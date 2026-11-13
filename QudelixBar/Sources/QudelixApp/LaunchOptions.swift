import Foundation
import QudelixBar

struct RenderRequest {
    var page: AppPage
    var output: String
}

struct LaunchOptions {
    var render: RenderRequest?
    var dark = false
    var demo = false
    var noDevice = false
    var power: DemoLink.Power = .battery
    var selectBand: Int?
    var dialog: String?
    var section: String?
    var query: String?
    var selectItem: Int?
    var aiDraft = false
    var aiMenu: String?
    var aiSlot: Int?
    var expandOthers = false
    var mode: String?
    var bass: Double?
    var tilt: Double?
    var cutoff: Double?
    var limitCutoff = false
    var suggest: String?
    var dismissSuggestion = false
    var automationOpen = false
    var hidden = false
    var menuOpen = false
    var toast: String?
    var eqState: String?
    var sidebar = false
    var ghost = false
    var follow = false
    var noAudio = false
    var customEq = false
    var stageDemo: String?
    var levelDemo: String?
    var tuneDemo: String?
    var version = false
    var help = false
    var trayDump: String?
    var width: Int32 = 900
    var height: Int32 = 640

    static var usage: String {
        [
            "Usage: \(AppInfo.executable) [options]",
            "",
            "Settings, equalizer and presets for the Qudelix 5K.",
            "",
            "Options:",
            "  --hidden     start without showing the window (used by Start at Login)",
            "  --version    print the version and exit",
            "  --help       print this help and exit"
        ].joined(separator: "\n")
    }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var page: AppPage = .device
        var output: String?
        var wantsRender = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--render-page":
                wantsRender = true
                if let value, let parsed = AppPage(rawValue: value.lowercased()) { page = parsed }
                index += 1
            case "--render-out":
                output = value
                index += 1
            case "--dark":
                options.dark = true
            case "--demo":
                options.demo = true
            case "--power":
                if let value, let parsed = DemoLink.Power(rawValue: value) { options.power = parsed }
                index += 1
            case "--no-device":
                options.noDevice = true
            case "--select-band":
                options.selectBand = value.flatMap { Int($0) }
                index += 1
            case "--dialog":
                options.dialog = value
                index += 1
            case "--section":
                options.section = value
                index += 1
            case "--query":
                options.query = value
                index += 1
            case "--select":
                options.selectItem = value.flatMap { Int($0) }
                index += 1
            case "--toast":
                options.toast = value
                index += 1
            case "--eq-state":
                options.eqState = value
                index += 1
            case "--version", "-V":
                options.version = true
            case "--help", "-h":
                options.help = true
            case "--hidden":
                options.hidden = true
            case "--open-menu":
                options.menuOpen = true
            case "--dump-tray":
                options.trayDump = value
                index += 1
            case "--sidebar":
                options.sidebar = true
            case "--ghost":
                options.ghost = true
            case "--follow":
                options.follow = true
            case "--custom-eq":
                options.customEq = true
            case "--stage-demo":
                options.stageDemo = value
                index += 1
            case "--level-demo":
                options.levelDemo = value
                index += 1
            case "--tune-demo":
                options.tuneDemo = value
                index += 1
            case "--no-audio":
                options.noAudio = true
            case "--ai-draft":
                options.aiDraft = true
            case "--ai-menu":
                options.aiMenu = value
                index += 1
            case "--ai-slot":
                options.aiSlot = value.flatMap { Int($0) }
                index += 1
            case "--expand-others":
                options.expandOthers = true
            case "--mode":
                options.mode = value
                index += 1
            case "--bass":
                options.bass = value.flatMap { Double($0) }
                index += 1
            case "--tilt":
                options.tilt = value.flatMap { Double($0) }
                index += 1
            case "--cutoff":
                options.cutoff = value.flatMap { Double($0) }
                index += 1
            case "--limit-cutoff":
                options.limitCutoff = true
            case "--suggest":
                options.suggest = value
                index += 1
            case "--dismiss-suggestion":
                options.dismissSuggestion = true
            case "--automation-open":
                options.automationOpen = true
            case "--size":
                let parts = (value ?? "").split(separator: "x").compactMap { Int32($0) }
                if parts.count == 2 {
                    options.width = parts[0]
                    options.height = parts[1]
                }
                index += 1
            default:
                break
            }
            index += 1
        }
        if wantsRender, let output {
            options.render = RenderRequest(page: page, output: output)
        }
        return options
    }
}
