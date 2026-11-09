import CGtk
import Foundation

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

package enum MainLoopBridge {
    private static var sourceID: UInt32 = 0
    package private(set) static var callbackCount = 0

    package static var isInstalled: Bool { sourceID != 0 }

    package static func install() {
        guard sourceID == 0 else { return }
        let fd = dispatchMainQueueHandle()
        sourceID = g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            var wakeups: UInt64 = 0
            _ = read(fd, &wakeups, MemoryLayout<UInt64>.size)
            MainLoopBridge.callbackCount += 1
            dispatchMainQueueCallback(nil)
            return 1
        }, nil)
    }
}
