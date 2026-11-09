import CGtk
import Foundation
import QudelixGtk

private let maxAttempts = 100
private let settleTicks = 8

enum Renderer {
    private final class Job {
        let window: UnsafeMutableRawPointer
        let application: UnsafeMutableRawPointer
        let request: RenderRequest
        let ready: () -> Bool
        let target: () -> UnsafeMutableRawPointer
        var attempts = 0
        var settledTicks = 0

        init(window: UnsafeMutableRawPointer, application: UnsafeMutableRawPointer, request: RenderRequest,
             ready: @escaping () -> Bool, target: @escaping () -> UnsafeMutableRawPointer) {
            self.target = target
            self.window = window
            self.application = application
            self.request = request
            self.ready = ready
        }
    }

    static func schedule(window: some GPointer, application: some GPointer, request: RenderRequest,
                         ready: @escaping () -> Bool, target: @escaping () -> UnsafeMutableRawPointer) {
        let job = Job(window: window.raw, application: application.raw, request: request, ready: ready,
                      target: target)
        g_timeout_add(100, { data in
            let job = Unmanaged<Job>.fromOpaque(data!).takeUnretainedValue()
            job.attempts += 1
            let sized = gtk_widget_get_width(job.window.assumingMemoryBound(to: GtkWidget.self)) > 0
            if sized && job.ready() { job.settledTicks += 1 }
            if job.settledTicks < settleTicks && job.attempts < maxAttempts { return 1 }
            let failure = Snapshot.writePNG(of: job.target(), to: job.request.output)
            if let failure {
                FileHandle.standardError.write(Data("render failed: \(failure)\n".utf8))
            }
            Unmanaged<Job>.fromOpaque(data!).release()
            g_application_quit(job.application.assumingMemoryBound(to: GApplication.self))
            if failure != nil { exit(1) }
            return 0
        }, Unmanaged.passRetained(job).toOpaque())
    }
}
