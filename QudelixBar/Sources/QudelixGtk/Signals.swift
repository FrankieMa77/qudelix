import CGtk
import Foundation

private class ClosureBox {}

private final class Box<Handler>: ClosureBox {
    let handler: Handler

    init(_ handler: Handler) {
        self.handler = handler
    }
}

private func retain<Handler>(_ handler: Handler) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Box(handler)).toOpaque()
}

private func unbox<Handler>(_ data: UnsafeMutableRawPointer?, _ type: Handler.Type) -> Handler? {
    guard let data else { return nil }
    return (Unmanaged<ClosureBox>.fromOpaque(data).takeUnretainedValue() as? Box<Handler>)?.handler
}

private let releaseSignalData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<ClosureBox>.fromOpaque(data).release()
}

private let releaseData: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<ClosureBox>.fromOpaque(data).release()
}

private typealias InstanceHandler = (UnsafeMutableRawPointer) -> Void
private typealias NotifyHandler = (UnsafeMutableRawPointer) -> Void
private typealias DrawHandler = (OpaquePointer, Int32, Int32) -> Void
private typealias PointHandler = (UnsafeMutableRawPointer, Double, Double) -> Void
private typealias PressHandler = (Int32, Double, Double) -> Void
private typealias ScrollHandler = (Double, Double) -> Bool
private typealias ResponseHandler = (String) -> Void
private typealias DecisionHandler = () -> Bool
private typealias StateHandler = (Bool) -> Void
private typealias KeyHandler = (UInt32, UInt32) -> Bool
private typealias RowHandler = (Int) -> Void

private let rowTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, row, data in
    guard let handler = unbox(data, RowHandler.self) else { return }
    guard let row else { handler(-1); return }
    handler(Int(gtk_list_box_row_get_index(row.assumingMemoryBound(to: GtkListBoxRow.self))))
}

private let instanceTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { instance, data in
    guard let instance, let handler = unbox(data, InstanceHandler.self) else { return }
    handler(instance)
}

private let notifyTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { instance, _, data in
    guard let instance, let handler = unbox(data, NotifyHandler.self) else { return }
    handler(instance)
}

private let drawTrampoline: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { area, cr, width, height, data in
    guard let area, let cr, let handler = unbox(data, DrawHandler.self) else { return }
    _ = area
    handler(cr, width, height)
}

private let pointTrampoline: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { instance, x, y, data in
    guard let instance, let handler = unbox(data, PointHandler.self) else { return }
    handler(instance, x, y)
}

private let pressTrampoline: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, count, x, y, data in
    guard let handler = unbox(data, PressHandler.self) else { return }
    handler(count, x, y)
}

private let scrollTrampoline: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Int32 = { _, dx, dy, data in
    guard let handler = unbox(data, ScrollHandler.self) else { return 0 }
    return handler(dx, dy) ? 1 : 0
}

private let responseTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, response, data in
    guard let response, let handler = unbox(data, ResponseHandler.self) else { return }
    handler(String(cString: response))
}

private let decisionTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { _, data in
    guard let handler = unbox(data, DecisionHandler.self) else { return 0 }
    return handler() ? 1 : 0
}

private let stateTrampoline: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, value, data in
    guard let value, let handler = unbox(data, StateHandler.self) else { return }
    handler(g_variant_get_boolean(value) != 0)
}

private let keyTrampoline: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32 = { _, keyval, _, state, data in
    guard let handler = unbox(data, KeyHandler.self) else { return 0 }
    return handler(keyval, state) ? 1 : 0
}

package enum Signals {
    @discardableResult
    package static func onCloseRequest(_ window: some GPointer,
                                       handler: @escaping () -> Bool) -> UInt {
        let callback = unsafeBitCast(decisionTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(window.raw, "close-request", callback,
                                          retain(handler as DecisionHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func onChangeState(_ action: some GPointer,
                                      handler: @escaping (Bool) -> Void) -> UInt {
        let callback = unsafeBitCast(stateTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(action.raw, "change-state", callback,
                                          retain(handler as StateHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func connect(_ instance: some GPointer,
                                signal: String,
                                handler: @escaping (UnsafeMutableRawPointer) -> Void) -> UInt {
        let callback = unsafeBitCast(instanceTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(instance.raw, signal, callback,
                                          retain(handler as InstanceHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func connect(_ instance: some GPointer,
                                signal: String,
                                handler: @escaping () -> Void) -> UInt {
        connect(instance, signal: signal) { _ in handler() }
    }

    @discardableResult
    package static func onActivate(_ action: some GPointer,
                                   handler: @escaping () -> Void) -> UInt {
        let callback = unsafeBitCast(notifyTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(action.raw, "activate", callback,
                                          retain({ _ in handler() } as NotifyHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func onNotify(_ instance: some GPointer,
                                 property: String,
                                 handler: @escaping (UnsafeMutableRawPointer) -> Void) -> UInt {
        let callback = unsafeBitCast(notifyTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(instance.raw, "notify::" + property, callback,
                                          retain(handler as NotifyHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func onRowSelected(_ list: some GPointer,
                                      handler: @escaping (Int) -> Void) -> UInt {
        let callback = unsafeBitCast(rowTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(list.raw, "row-selected", callback,
                                          retain(handler as RowHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func onRowActivated(_ list: some GPointer,
                                       handler: @escaping (Int) -> Void) -> UInt {
        let callback = unsafeBitCast(rowTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(list.raw, "row-activated", callback,
                                          retain(handler as RowHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }

    @discardableResult
    package static func onSpinChanged(_ spin: some GPointer,
                                      handler: @escaping (Double) -> Void) -> UInt {
        connect(spin, signal: "value-changed") { instance in
            handler(gtk_spin_button_get_value(OpaquePointer(instance)))
        }
    }

    @discardableResult
    package static func onValueChanged(_ range: some GPointer,
                                       handler: @escaping (Double) -> Void) -> UInt {
        connect(range, signal: "value-changed") { instance in
            handler(gtk_range_get_value(instance.assumingMemoryBound(to: GtkRange.self)))
        }
    }

    @discardableResult
    package static func onAdjustmentChanged(_ adjustment: some GPointer,
                                            handler: @escaping (Double) -> Void) -> UInt {
        connect(adjustment, signal: "value-changed") { instance in
            handler(gtk_adjustment_get_value(instance.assumingMemoryBound(to: GtkAdjustment.self)))
        }
    }

    @discardableResult
    package static func onToggled(_ button: some GPointer,
                                  handler: @escaping (Bool) -> Void) -> UInt {
        connect(button, signal: "toggled") { instance in
            handler(gtk_toggle_button_get_active(instance.assumingMemoryBound(to: GtkToggleButton.self)) != 0)
        }
    }

    package static func setDrawFunc(_ area: some GPointer,
                                    handler: @escaping (OpaquePointer, Int32, Int32) -> Void) {
        gtk_drawing_area_set_draw_func(area.raw.assumingMemoryBound(to: GtkDrawingArea.self),
                                       drawTrampoline,
                                       retain(handler as DrawHandler),
                                       releaseData)
    }

    package static func disconnect(_ instance: some GPointer, id: UInt) {
        g_signal_handler_disconnect(instance.raw, id)
    }

    package static func shiftHeld(_ controller: UnsafeMutableRawPointer) -> Bool {
        let state = gtk_event_controller_get_current_event_state(OpaquePointer(controller))
        return state.rawValue & GDK_SHIFT_MASK.rawValue != 0
    }

    package static func addDrag(to widget: some GPointer,
                                begin: @escaping (Double, Double) -> Void,
                                update: @escaping (Double, Double, Bool) -> Void,
                                end: @escaping (Double, Double) -> Void) {
        let gesture = gtk_gesture_drag_new()!
        let pointer = UnsafeMutableRawPointer(gesture)
        let callback = unsafeBitCast(pointTrampoline, to: GCallback.self)
        let beginBox: PointHandler = { _, x, y in begin(x, y) }
        let updateBox: PointHandler = { instance, dx, dy in update(dx, dy, shiftHeld(instance)) }
        let endBox: PointHandler = { _, dx, dy in end(dx, dy) }
        g_signal_connect_data(pointer, "drag-begin", callback, retain(beginBox),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        g_signal_connect_data(pointer, "drag-update", callback, retain(updateBox),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        g_signal_connect_data(pointer, "drag-end", callback, retain(endBox),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget.widget, gesture)
    }

    package static func addClick(to widget: some GPointer,
                                 pressed: @escaping (Int32, Double, Double) -> Void) {
        let gesture = gtk_gesture_click_new()!
        let callback = unsafeBitCast(pressTrampoline, to: GCallback.self)
        g_signal_connect_data(UnsafeMutableRawPointer(gesture), "pressed", callback,
                              retain(pressed as PressHandler),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget.widget, gesture)
    }

    package static func addMotion(to widget: some GPointer,
                                  move: @escaping (Double, Double) -> Void,
                                  leave: @escaping () -> Void) {
        let controller = gtk_event_controller_motion_new()!
        let pointer = UnsafeMutableRawPointer(controller)
        let callback = unsafeBitCast(pointTrampoline, to: GCallback.self)
        let moveBox: PointHandler = { _, x, y in move(x, y) }
        g_signal_connect_data(pointer, "motion", callback, retain(moveBox),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        g_signal_connect_data(pointer, "enter", callback, retain(moveBox),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        connect(pointer, signal: "leave") { leave() }
        gtk_widget_add_controller(widget.widget, controller)
    }

    package static func addScroll(to widget: some GPointer,
                                  handler: @escaping (Double, Double) -> Bool) {
        let controller = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        let callback = unsafeBitCast(scrollTrampoline, to: GCallback.self)
        g_signal_connect_data(UnsafeMutableRawPointer(controller), "scroll", callback,
                              retain(handler as ScrollHandler),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget.widget, controller)
    }

    package static func addKey(to widget: some GPointer,
                               handler: @escaping (UInt32, UInt32) -> Bool) {
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        let callback = unsafeBitCast(keyTrampoline, to: GCallback.self)
        g_signal_connect_data(UnsafeMutableRawPointer(controller), "key-pressed", callback,
                              retain(handler as KeyHandler),
                              releaseSignalData, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(widget.widget, controller)
    }

    @discardableResult
    package static func onResponse(_ dialog: some GPointer,
                                   handler: @escaping (String) -> Void) -> UInt {
        let callback = unsafeBitCast(responseTrampoline, to: GCallback.self)
        return UInt(g_signal_connect_data(dialog.raw, "response", callback,
                                          retain(handler as ResponseHandler),
                                          releaseSignalData, GConnectFlags(rawValue: 0)))
    }
}
