import CGtk

package enum Accessible {
    private static func stringValue(_ text: String) -> GValue {
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        g_value_set_string(&value, text)
        return value
    }

    private static func tristateValue(_ flag: Bool) -> GValue {
        var value = GValue()
        g_value_init(&value, g_type_from_name("gint"))
        g_value_set_int(&value, flag ? 1 : 0)
        return value
    }

    package static func setLabel(_ widget: some GPointer, _ text: String) {
        var property = GTK_ACCESSIBLE_PROPERTY_LABEL
        var value = stringValue(text)
        gtk_accessible_update_property_value(widget.opaque, 1, &property, &value)
        g_value_unset(&value)
    }

    package static func setDescription(_ widget: some GPointer, _ text: String) {
        var property = GTK_ACCESSIBLE_PROPERTY_DESCRIPTION
        var value = stringValue(text)
        gtk_accessible_update_property_value(widget.opaque, 1, &property, &value)
        g_value_unset(&value)
    }

    package static func setSelected(_ widget: some GPointer, _ selected: Bool) {
        var state = GTK_ACCESSIBLE_STATE_SELECTED
        var value = tristateValue(selected)
        gtk_accessible_update_state_value(widget.opaque, 1, &state, &value)
        g_value_unset(&value)
    }

    package static func role(of widget: some GPointer) -> GtkAccessibleRole {
        gtk_accessible_get_accessible_role(widget.opaque)
    }

    package static func drawingArea(role: GtkAccessibleRole) -> UnsafeMutablePointer<GtkWidget> {
        var names: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("accessible-role"))]
        defer { free(UnsafeMutablePointer(mutating: names[0])) }
        var value = GValue()
        g_value_init(&value, gtk_accessible_role_get_type())
        g_value_set_enum(&value, Int32(role.rawValue))
        defer { g_value_unset(&value) }
        let created = g_object_new_with_properties(gtk_drawing_area_get_type(), 1, &names, &value)!
        return UnsafeMutableRawPointer(created).assumingMemoryBound(to: GtkWidget.self)
    }
}
