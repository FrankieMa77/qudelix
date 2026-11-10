import Foundation
#if canImport(Darwin)
import os.lock

struct RTLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock_s>

    init() {
        storage = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock_s())
    }

    func lock() { os_unfair_lock_lock(storage) }

    func unlock() { os_unfair_lock_unlock(storage) }

    func destroy() { storage.deallocate() }
}
#else
struct RTLock {
    private let storage: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        storage = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        pthread_mutexattr_setprotocol(&attributes, Int32(PTHREAD_PRIO_INHERIT))
        pthread_mutex_init(storage, &attributes)
        pthread_mutexattr_destroy(&attributes)
    }

    func lock() { pthread_mutex_lock(storage) }

    func unlock() { pthread_mutex_unlock(storage) }

    func destroy() {
        pthread_mutex_destroy(storage)
        storage.deallocate()
    }
}
#endif
