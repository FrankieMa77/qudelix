import CGtk
import Foundation
import QudelixBar
import QudelixGtk

@MainActor
enum AppWindow {
    private static var devicePage: DevicePage?
    private static var eqPage: EqPage?
    private static var presetsPage: PresetsPage?
    private static var libraryPage: LibraryPage?
    private static var libraryDriver: LibraryRenderDriver?
    private static let controller = WindowController()
    private static var tray: TrayService?
    private static var menuOpened = false
    private static var toasts: UnsafeMutablePointer<GtkWidget>?
    private static var stackWidget: OpaquePointer?
    private static var undoAction: OpaquePointer?
    private static var redoAction: OpaquePointer?
    private static var renderedToast = false
    private static var noticeObserver: Int?
    private(set) static var mainWindow: UnsafeMutablePointer<GtkWidget>?

    static func present(for application: some GPointer, options: LaunchOptions, model: AppModel) {
        if let existing = gtk_application_get_windows(application.raw.assumingMemoryBound(to: GtkApplication.self)),
           existing.pointee.data != nil {
            controller.show()
            return
        }
        if options.render != nil { disableAnimations() }
        let manager = adw_style_manager_get_default()
        adw_style_manager_set_color_scheme(manager, options.dark ? ADW_COLOR_SCHEME_FORCE_DARK : ADW_COLOR_SCHEME_DEFAULT)

        AppIcon.installWindowDefault()
        let window = adw_application_window_new(application.raw.assumingMemoryBound(to: GtkApplication.self))!
        gtk_window_set_title(window.raw.assumingMemoryBound(to: GtkWindow.self), "Qudelix")
        gtk_window_set_default_size(window.raw.assumingMemoryBound(to: GtkWindow.self), options.width, options.height)
        gtk_widget_set_size_request(window, 360, 294)

        let stack = adw_view_stack_new()!
        for page in AppPage.allCases {
            let content: UnsafeMutablePointer<GtkWidget>
            switch page {
            case .device:
                let devicePage = DevicePage(model: model)
                self.devicePage = devicePage
                content = devicePage.widget
            case .eq:
                let eqPage = EqPage(model: model)
                self.eqPage = eqPage
                content = eqPage.widget
            case .presets:
                let presetsPage = PresetsPage(model: model)
                self.presetsPage = presetsPage
                content = presetsPage.widget
            case .library:
                let libraryPage = LibraryPage(model: model)
                self.libraryPage = libraryPage
                libraryDriver = LibraryRenderDriver(options: options, page: libraryPage)
                content = libraryPage.widget
            }
            adw_view_stack_add_titled_with_icon(stack.opaque, content, page.rawValue, page.title, page.icon)
        }

        let switcher = adw_view_switcher_new()!
        adw_view_switcher_set_stack(switcher.opaque, stack.opaque)
        adw_view_switcher_set_policy(switcher.opaque, ADW_VIEW_SWITCHER_POLICY_WIDE)

        let windowTitle = adw_window_title_new("Qudelix", nil)!
        gtk_widget_set_visible(windowTitle.widget, 0)
        let titleBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_box_append(titleBox.typed(GtkBox.self), switcher.widget)
        gtk_box_append(titleBox.typed(GtkBox.self), windowTitle.widget)

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(header.opaque, titleBox)
        adw_header_bar_pack_end(header.opaque, AppMenu.makeButton())

        let bar = adw_view_switcher_bar_new()!
        adw_view_switcher_bar_set_stack(bar.opaque, stack.opaque)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.opaque, header.widget)
        adw_toolbar_view_add_bottom_bar(toolbar.opaque, bar.widget)
        adw_toolbar_view_set_content(toolbar.opaque, stack.widget)
        let overlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(overlay.opaque, toolbar.widget)
        adw_application_window_set_content(window.raw.assumingMemoryBound(to: AdwApplicationWindow.self), overlay.widget)
        toasts = overlay.widget
        noticeObserver = model.addNoticeObserver { notice in
            onLive { showToast(notice.message, failure: notice.kind == .failure) }
        }

        UiLifetime.windowDestroyed = false
        Signals.connect(window, signal: "destroy") { UiLifetime.windowDestroyed = true }

        installLibraryBreakpoint(window: window)
        installNarrowBreakpoint(window: window, switcher: switcher, title: windowTitle.widget, bar: bar)
        installShortcuts(application: application, window: window, stack: stack.opaque, model: model)

        if let request = options.render {
            adw_view_stack_set_visible_child_name(stack.opaque, request.page.rawValue)
        }

        mainWindow = window.widget

        if let request = options.render {
            gtk_window_present(window.raw.assumingMemoryBound(to: GtkWindow.self))
            Renderer.schedule(window: window, application: application, request: request,
                              ready: { Self.isReady(model, options: options) },
                              target: {
                                  (options.menuOpen ? AppMenu.popover : nil)
                                      ?? presetsPage?.dialog ?? libraryPage?.dialog ?? window.raw
                              })
        } else {
            controller.attach(window: window.widget, application: application.raw)
            controller.launch(startHidden: options.hidden)
            tray = TrayService(model: model, controller: controller, application: application.raw)
        }

        model.start()
    }

    static func showToast(_ message: String, failure: Bool) {
        guard let toasts else { return }
        let toast = adw_toast_new("")!
        let label = gtk_label_new(message)!
        gtk_label_set_wrap(label.opaque, 1)
        gtk_label_set_wrap_mode(label.opaque, PANGO_WRAP_WORD_CHAR)
        gtk_label_set_max_width_chars(label.opaque, 34)
        gtk_label_set_justify(label.opaque, GTK_JUSTIFY_CENTER)
        gtk_widget_add_css_class(label, "heading")
        adw_toast_set_custom_title(toast, label)
        adw_toast_set_timeout(toast, failure ? 7 : 3)
        adw_toast_overlay_add_toast(toasts.opaque, toast)
    }

    private static func isReady(_ model: AppModel, options: LaunchOptions) -> Bool {
        let connection = model.state.connection
        if options.noDevice {
            guard connection == .searching else { return false }
            return options.render?.page != .library || libraryDriver?.ready() ?? true
        }
        guard options.demo else { return true }
        guard connection.isConnected, model.eq.state.ready,
              model.presets.state.slots.count == PresetSlotsModel.slotCount,
              model.presets.state.slots[2].name != nil else { return false }
        if let toast = options.toast, !renderedToast {
            renderedToast = true
            showToast(toast == "failure" ? "Could not save to slot 3. Check the connection and try again."
                      : "Saved to slot 3.", failure: toast == "failure")
        }
        if let state = options.eqState {
            eqPage?.showForRender(state == "loading" ? .loading : .failed)
        }
        if let band = options.selectBand {
            if model.eq.state.selected != band { model.eq.select(band) }
            guard model.eq.state.selected == band else { return false }
        }
        if options.render?.page == .library { return libraryDriver?.ready() ?? true }
        if options.menuOpen { return menuReady() }
        if options.dialog == "about" { return aboutReady() }
        if let kind = options.dialog {
            guard let presetsPage else { return false }
            if presetsPage.dialog == nil {
                if kind == "rename" { presetsPage.presentRename(slot: 2) } else { presetsPage.presentSaveConfirmation(slot: 2) }
                return false
            }
            return presetsPage.dialog.map { gtk_widget_get_width($0.assumingMemoryBound(to: GtkWidget.self)) > 0 } ?? false
        }
        return true
    }

    private static func menuReady() -> Bool {
        if !menuOpened {
            menuOpened = true
            AppMenu.open()
            return false
        }
        guard let popover = AppMenu.popover else { return false }
        return gtk_widget_get_width(popover.assumingMemoryBound(to: GtkWidget.self)) > 0
    }

    private static func aboutReady() -> Bool {
        guard let dialog = AppMenu.currentAboutDialog else {
            AppMenu.presentAbout(parent: mainWindow)
            return false
        }
        return gtk_widget_get_width(dialog.assumingMemoryBound(to: GtkWidget.self)) > 0
    }

    private static func disableAnimations() {
        guard let settings = gtk_settings_get_default() else { return }
        var disabled = GValue()
        g_value_init(&disabled, g_type_from_name("gboolean"))
        g_value_set_boolean(&disabled, 0)
        g_object_set_property(settings.object, "gtk-enable-animations", &disabled)
    }

    private static func installShortcuts(application: some GPointer, window: some GPointer,
                                         stack: OpaquePointer, model: AppModel) {
        let undo = g_simple_action_new("eq-undo", nil)!
        Signals.onActivate(undo) { onMain { eqPage?.undo() } }
        g_action_map_add_action(application.opaque, undo.opaque)
        let redo = g_simple_action_new("eq-redo", nil)!
        Signals.onActivate(redo) { onMain { eqPage?.redo() } }
        g_action_map_add_action(application.opaque, redo.opaque)
        undoAction = undo.opaque
        redoAction = redo.opaque
        stackWidget = stack
        let app = application.raw.assumingMemoryBound(to: GtkApplication.self)
        "<Primary>z".withCString { accelerator in
            var accelerators: [UnsafePointer<CChar>?] = [accelerator, nil]
            gtk_application_set_accels_for_action(app, "app.eq-undo", &accelerators)
        }
        "<Primary><Shift>z".withCString { first in
            "<Primary>y".withCString { second in
                var accelerators: [UnsafePointer<CChar>?] = [first, second, nil]
                gtk_application_set_accels_for_action(app, "app.eq-redo", &accelerators)
            }
        }
        let windowPointer = window.raw
        let refresh: () -> Void = { onLive { refreshHistoryActions(window: windowPointer, model: model) } }
        Signals.onNotify(stack, property: "visible-child-name") { _ in
            refresh()
            onLive {
                let name = adw_view_stack_get_visible_child_name(stack).map { String(cString: $0) }
                if name == AppPage.library.rawValue { model.library.saved.refreshFromDisk() }
            }
        }
        Signals.onNotify(window, property: "focus-widget") { _ in refresh() }
        model.eq.addObserver { _ in refresh() }
    }

    private static func refreshHistoryActions(window: UnsafeMutableRawPointer, model: AppModel) {
        guard let undoAction, let redoAction, let stackWidget else { return }
        let onEq = adw_view_stack_get_visible_child_name(stackWidget).map { String(cString: $0) } == AppPage.eq.rawValue
        var typing = false
        if let focus = gtk_window_get_focus(window.assumingMemoryBound(to: GtkWindow.self)) {
            typing = HistoryActionGate.isEditable(focus)
        }
        let state = model.eq.state
        let enabled = HistoryActionGate.enabled(onEqPage: onEq, typing: typing, canEdit: state.canEdit,
                                                canUndo: state.canUndo, canRedo: state.canRedo)
        g_simple_action_set_enabled(undoAction, enabled.undo ? 1 : 0)
        g_simple_action_set_enabled(redoAction, enabled.redo ? 1 : 0)
    }

    private static func installLibraryBreakpoint(window: some GPointer) {
        guard let libraryPage, let condition = adw_breakpoint_condition_parse(SplitLayout.narrowBreakpoint) else { return }
        let breakpoint = adw_breakpoint_new(condition)!
        for layout in libraryPage.layouts { layout.addNarrowSetters(to: breakpoint) }
        adw_application_window_add_breakpoint(window.raw.assumingMemoryBound(to: AdwApplicationWindow.self), breakpoint)
    }

    private static func installNarrowBreakpoint(window: some GPointer, switcher: some GPointer,
                                                title: UnsafeMutablePointer<GtkWidget>, bar: some GPointer) {
        guard let condition = adw_breakpoint_condition_parse("max-width: 550sp") else { return }
        let breakpoint = adw_breakpoint_new(condition)!
        var hidden = GValue()
        g_value_init(&hidden, g_type_from_name("gboolean"))
        g_value_set_boolean(&hidden, 0)
        var revealed = GValue()
        g_value_init(&revealed, g_type_from_name("gboolean"))
        g_value_set_boolean(&revealed, 1)
        adw_breakpoint_add_setter(breakpoint, switcher.object, "visible", &hidden)
        adw_breakpoint_add_setter(breakpoint, bar.object, "reveal", &revealed)
        adw_breakpoint_add_setter(breakpoint, title.object, "visible", &revealed)
        for layout in libraryPage?.layouts ?? [] { layout.addNarrowSetters(to: breakpoint) }
        adw_application_window_add_breakpoint(window.raw.assumingMemoryBound(to: AdwApplicationWindow.self), breakpoint)
    }
}
