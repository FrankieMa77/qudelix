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
    private static var stagePage: StagePage?
    private static var levelPage: LevelPage?
    private static var audioDriver: AudioRenderDriver?
    private static var libraryDriver: LibraryRenderDriver?
    private static var eqDriver: EqRenderDriver?
    private static var audio: AudioStack?
    private static var splitView: OpaquePointer?
    private static var contentPage: UnsafeMutablePointer<AdwNavigationPage>?
    private static var contentTitle: OpaquePointer?
    private static var sidebarList: UnsafeMutablePointer<GtkWidget>?
    private static var sidebarRows: [UnsafeMutablePointer<GtkWidget>] = []
    private static var selectingRow = false
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

    static func present(for application: some GPointer, options: LaunchOptions, model: AppModel, audio: AudioStack?) {
        self.audio = audio
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
                let eqPage = EqPage(model: model, audio: audio)
                self.eqPage = eqPage
                eqDriver = EqRenderDriver(options: options, model: model, audio: audio)
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
            case .stage:
                if let stage = audio?.stage {
                    let stagePage = StagePage(stage: stage)
                    self.stagePage = stagePage
                    content = stagePage.widget
                } else {
                    content = makePlaceholder(for: page, audio: audio)
                }
            case .level:
                if let stage = audio?.stage {
                    let levelPage = LevelPage(stage: stage, automation: audio?.automation)
                    self.levelPage = levelPage
                    content = levelPage.widget
                } else {
                    content = makePlaceholder(for: page, audio: audio)
                }
            case .tune:
                content = makePlaceholder(for: page, audio: audio)
            }
            adw_view_stack_add_titled_with_icon(stack.opaque, content, page.rawValue, page.title, page.icon)
        }

        audioDriver = AudioRenderDriver(options: options, audio: audio, levelPage: levelPage)

        let split = adw_navigation_split_view_new()!
        splitView = split.opaque
        adw_navigation_split_view_set_min_sidebar_width(split.opaque, 190)
        adw_navigation_split_view_set_max_sidebar_width(split.opaque, 240)
        adw_navigation_split_view_set_sidebar_width_fraction(split.opaque, 0.22)

        let sidebarTitle = adw_window_title_new("Qudelix", nil)!
        let sidebarHeader = adw_header_bar_new()!
        adw_header_bar_set_title_widget(sidebarHeader.opaque, sidebarTitle.widget)
        adw_header_bar_pack_end(sidebarHeader.opaque, AppMenu.makeButton())
        let list = makeSidebar()
        let listScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(listScroller.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(listScroller.opaque, list)
        let sidebarToolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(sidebarToolbar.opaque, sidebarHeader.widget)
        adw_toolbar_view_set_content(sidebarToolbar.opaque, listScroller.widget)
        let sidebarPage = adw_navigation_page_new(sidebarToolbar.widget, "Qudelix")!
        adw_navigation_split_view_set_sidebar(split.opaque, sidebarPage)

        let titleWidget = adw_window_title_new(AppPage.device.title, nil)!
        contentTitle = titleWidget.opaque
        let contentHeader = adw_header_bar_new()!
        adw_header_bar_set_title_widget(contentHeader.opaque, titleWidget.widget)
        let contentToolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(contentToolbar.opaque, contentHeader.widget)
        adw_toolbar_view_set_content(contentToolbar.opaque, stack.widget)
        let page = adw_navigation_page_new(contentToolbar.widget, AppPage.device.title)!
        contentPage = page
        adw_navigation_split_view_set_content(split.opaque, page)

        let overlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(overlay.opaque, split.widget)
        adw_application_window_set_content(window.raw.assumingMemoryBound(to: AdwApplicationWindow.self), overlay.widget)
        toasts = overlay.widget
        noticeObserver = model.addNoticeObserver { notice in
            onLive { showToast(notice.message, failure: notice.kind == .failure) }
        }

        UiLifetime.windowDestroyed = false
        Signals.connect(window, signal: "destroy") { UiLifetime.windowDestroyed = true }

        installLibraryBreakpoint(window: window)
        installNarrowBreakpoint(window: window, split: split)
        installShortcuts(application: application, window: window, stack: stack.opaque, model: model)
        installNavigation(application: application, stack: stack.opaque)

        if let request = options.render {
            navigate(to: request.page, showContent: !options.sidebar && !options.menuOpen)
        }

        mainWindow = window.widget

        if let request = options.render {
            gtk_window_present(window.raw.assumingMemoryBound(to: GtkWindow.self))
            Renderer.schedule(window: window, application: application, request: request,
                              ready: { Self.isReady(model, options: options) },
                              target: {
                                  (options.menuOpen ? AppMenu.popover : nil)
                                      ?? presetsPage?.dialog ?? libraryPage?.dialog ?? levelPage?.dialog ?? window.raw
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
            if options.render?.page == .stage || options.render?.page == .level { return audioDriver?.ready() ?? true }
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
        if options.render?.page == .stage || options.render?.page == .level { return audioDriver?.ready() ?? true }
        if options.render?.page == .eq, eqDriver?.ready() == false { return false }
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

    private static func makeSidebar() -> UnsafeMutablePointer<GtkWidget> {
        let list = gtk_list_box_new()!
        sidebarList = list
        gtk_list_box_set_selection_mode(list.opaque, GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(list, "navigation-sidebar")
        Accessible.setLabel(list, "Pages")
        sidebarRows = []
        for page in AppPage.allCases {
            let row = gtk_list_box_row_new()!
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
            gtk_widget_set_margin_top(box, 6)
            gtk_widget_set_margin_bottom(box, 6)
            let icon = gtk_image_new_from_icon_name(page.icon)!
            let label = gtk_label_new(page.title)!
            gtk_label_set_xalign(label.opaque, 0)
            gtk_widget_set_hexpand(label, 1)
            gtk_box_append(box.typed(GtkBox.self), icon)
            gtk_box_append(box.typed(GtkBox.self), label)
            gtk_list_box_row_set_child(row.typed(GtkListBoxRow.self), box)
            Accessible.setLabel(row, page.title)
            gtk_widget_set_tooltip_text(row, page.summary)
            gtk_list_box_append(list.opaque, row)
            sidebarRows.append(row)
        }
        Signals.connect(list, signal: "row-selected") { _ in
            onMain {
                guard !selectingRow, let list = sidebarList,
                      let row = gtk_list_box_get_selected_row(list.opaque) else { return }
                let index = Int(gtk_list_box_row_get_index(row))
                guard AppPage.allCases.indices.contains(index) else { return }
                navigate(to: AppPage.allCases[index], showContent: true)
            }
        }
        Signals.connect(list, signal: "row-activated") { _ in
            onMain {
                guard let splitView else { return }
                adw_navigation_split_view_set_show_content(splitView, 1)
            }
        }
        return list
    }

    static func navigate(to page: AppPage, showContent: Bool) {
        guard let stackWidget else { return }
        adw_view_stack_set_visible_child_name(stackWidget, page.rawValue)
        if let contentTitle { adw_window_title_set_title(contentTitle, page.title) }
        if let contentPage { adw_navigation_page_set_title(contentPage, page.title) }
        if showContent, let splitView { adw_navigation_split_view_set_show_content(splitView, 1) }
        if let list = sidebarList, let index = AppPage.allCases.firstIndex(of: page), sidebarRows.indices.contains(index),
           let current = gtk_list_box_get_selected_row(list.opaque), Int(gtk_list_box_row_get_index(current)) != index {
            selectingRow = true
            gtk_list_box_select_row(list.opaque, sidebarRows[index].typed(GtkListBoxRow.self))
            selectingRow = false
        } else if let list = sidebarList, gtk_list_box_get_selected_row(list.opaque) == nil,
                  let index = AppPage.allCases.firstIndex(of: page), sidebarRows.indices.contains(index) {
            selectingRow = true
            gtk_list_box_select_row(list.opaque, sidebarRows[index].typed(GtkListBoxRow.self))
            selectingRow = false
        }
    }

    private static func installNavigation(application: some GPointer, stack: OpaquePointer) {
        let app = application.raw.assumingMemoryBound(to: GtkApplication.self)
        for (index, page) in AppPage.allCases.enumerated() {
            let action = g_simple_action_new(NavigationPages.actionName(for: page.rawValue), nil)!
            Signals.onActivate(action) { onMain { navigate(to: page, showContent: true) } }
            g_action_map_add_action(application.opaque, action.opaque)
            if let accelerator = NavigationPages.accelerator(at: index) {
                accelerator.withCString { value in
                    var accelerators: [UnsafePointer<CChar>?] = [value, nil]
                    gtk_application_set_accels_for_action(app, "app.\(NavigationPages.actionName(for: page.rawValue))", &accelerators)
                }
            }
        }
        for (name, offset, accelerator) in [("page-next", 1, "<Primary>Page_Down"), ("page-previous", -1, "<Primary>Page_Up")] {
            let action = g_simple_action_new(name, nil)!
            Signals.onActivate(action) {
                onMain {
                    let current = adw_view_stack_get_visible_child_name(stack).map { String(cString: $0) } ?? ""
                    guard let id = NavigationPages.neighbour(of: current, offset: offset),
                          let page = AppPage(rawValue: id) else { return }
                    navigate(to: page, showContent: true)
                }
            }
            g_action_map_add_action(application.opaque, action.opaque)
            accelerator.withCString { value in
                var accelerators: [UnsafePointer<CChar>?] = [value, nil]
                gtk_application_set_accels_for_action(app, "app.\(name)", &accelerators)
            }
        }
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

    private static func installNarrowBreakpoint(window: some GPointer, split: some GPointer) {
        guard let condition = adw_breakpoint_condition_parse("max-width: 550sp") else { return }
        let breakpoint = adw_breakpoint_new(condition)!
        var collapsed = GValue()
        g_value_init(&collapsed, g_type_from_name("gboolean"))
        g_value_set_boolean(&collapsed, 1)
        adw_breakpoint_add_setter(breakpoint, split.object, "collapsed", &collapsed)
        for layout in libraryPage?.layouts ?? [] { layout.addNarrowSetters(to: breakpoint) }
        adw_application_window_add_breakpoint(window.raw.assumingMemoryBound(to: AdwApplicationWindow.self), breakpoint)
    }
}
