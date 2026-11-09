import CGtk

package enum HistoryActionGate {
    package static func isEditable(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        g_type_check_instance_is_a(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self),
                                   gtk_editable_get_type()) != 0
    }

    package static func enabled(onEqPage: Bool, typing: Bool, canEdit: Bool,
                                canUndo: Bool, canRedo: Bool) -> (undo: Bool, redo: Bool) {
        let allowed = onEqPage && !typing && canEdit
        return (allowed && canUndo, allowed && canRedo)
    }
}
