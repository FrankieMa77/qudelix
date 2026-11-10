import Foundation
#if canImport(Glibc)
import Glibc
#endif

package struct StageSettings: Codable, Equatable {
    package var enabled = false
    package var width: Double = 130
    package var crossfeed: Double = 0.3
    package var dialogue: Double = 0
    package var room: Double = 0

    package var distance: Double?
    package var span: Double?
    package var center: Double?
    package var size: Double?
    package var night: Double?

    package var crossLowTrim: Double?
    package var crossMidTrim: Double?
    package var crossHighTrim: Double?

    package var balanceDb: Double?
    package var alignMs: Double?

    package var limiter: Bool?

    package var loudness: Bool?
    package var loudnessStrength: Double?

    package var bassGuard: Bool?
    package var bassGuardStrength: Double?

    package var impulseFile: String?
    package var impulseMix: Double?

    package var distanceValue: Double { distance ?? 0.35 }
    package var spanValue: Double { span ?? 0.5 }
    package var centerValue: Double { center ?? 0 }
    package var sizeValue: Double { size ?? 0.5 }
    package var nightValue: Double { night ?? 0 }
    package var crossLowTrimValue: Double { crossLowTrim ?? 1 }
    package var crossMidTrimValue: Double { crossMidTrim ?? 1 }
    package var crossHighTrimValue: Double { crossHighTrim ?? 1 }
    package var balanceDbValue: Double { balanceDb ?? 0 }
    package var alignMsValue: Double { alignMs ?? 0 }
    package var limiterValue: Bool { limiter ?? false }
    package var loudnessValue: Bool { loudness ?? false }
    package var loudnessStrengthValue: Double { loudnessStrength ?? 1 }
    package var bassGuardValue: Bool { bassGuard ?? false }
    package var bassGuardStrengthValue: Double { bassGuardStrength ?? 1 }
    package var impulseFileValue: String { impulseFile ?? "" }
    package var impulseMixValue: Double { impulseMix ?? 1 }
    package var hasImpulse: Bool { !impulseFileValue.isEmpty }

    package static let music = StageSettings(enabled: true, width: 115, crossfeed: 0.35,
                                     dialogue: 0, room: 0.1,
                                     distance: 0.15, span: 0.4, center: 0, size: 0.4)
    package static let movie = StageSettings(enabled: true, width: 140, crossfeed: 0.25,
                                     dialogue: 2.5, room: 0.35,
                                     distance: 0.35, span: 0.55, center: 0, size: 0.55)
    package static let theater = StageSettings(enabled: true, width: 180, crossfeed: 0.15,
                                       dialogue: 3, room: 0.7,
                                       distance: 0.55, span: 0.75, center: -1.5, size: 0.75)

    package func audiblyEquals(_ other: StageSettings) -> Bool {
        enabled == other.enabled && width == other.width
            && crossfeed == other.crossfeed && dialogue == other.dialogue
            && room == other.room
            && distanceValue == other.distanceValue
            && spanValue == other.spanValue
            && centerValue == other.centerValue
            && sizeValue == other.sizeValue
            && nightValue == other.nightValue
            && crossLowTrimValue == other.crossLowTrimValue
            && crossMidTrimValue == other.crossMidTrimValue
            && crossHighTrimValue == other.crossHighTrimValue
            && balanceDbValue == other.balanceDbValue
            && alignMsValue == other.alignMsValue
            && limiterValue == other.limiterValue
            && loudnessValue == other.loudnessValue
            && loudnessStrengthValue == other.loudnessStrengthValue
            && bassGuardValue == other.bassGuardValue
            && bassGuardStrengthValue == other.bassGuardStrengthValue
            && impulseFileValue == other.impulseFileValue
            && impulseMixValue == other.impulseMixValue
    }

    package var doesAnything: Bool {
        var neutral = StageSettings()
        neutral.enabled = enabled
        return !audiblyEquals(neutral)
    }

    package var isAudiblyNeutral: Bool {
        width == 100 && crossfeed == 0 && dialogue <= 0.05 && room == 0
            && distanceValue == 0 && centerValue == 0 && nightValue == 0
            && balanceDbValue == 0 && alignMsValue == 0 && !limiterValue
            && !loudnessValue && !bassGuardValue && !hasImpulse
    }

    package func clamped() -> StageSettings {
        var s = self
        s.width = s.width.isFinite ? min(max(s.width, 0), 200) : 100
        s.crossfeed = s.crossfeed.isFinite ? min(max(s.crossfeed, 0), 1) : 0
        s.dialogue = s.dialogue.isFinite ? min(max(s.dialogue, 0), 6) : 0
        s.room = s.room.isFinite ? min(max(s.room, 0), 1) : 0
        func unit(_ v: Double?) -> Double? {
            guard let v else { return nil }
            return v.isFinite ? min(max(v, 0), 1) : nil
        }
        s.distance = unit(s.distance)
        s.span = unit(s.span)
        s.size = unit(s.size)
        s.night = unit(s.night)
        if let c = s.center {
            s.center = c.isFinite ? min(max(c, -6), 3) : nil
        }
        func trim(_ v: Double?) -> Double? {
            guard let v else { return nil }
            return v.isFinite ? min(max(v, 0), 1) : nil
        }
        s.crossLowTrim = trim(s.crossLowTrim)
        s.crossMidTrim = trim(s.crossMidTrim)
        s.crossHighTrim = trim(s.crossHighTrim)
        if let b = s.balanceDb {
            s.balanceDb = b.isFinite ? min(max(b, -3), 3) : nil
        }
        if let a = s.alignMs {
            s.alignMs = a.isFinite ? min(max(a, -0.5), 0.5) : nil
        }
        if s.limiter == false { s.limiter = nil }
        if s.loudness == false { s.loudness = nil }
        s.loudnessStrength = unit(s.loudnessStrength)
        if s.loudnessStrength == 1 { s.loudnessStrength = nil }
        if s.bassGuard == false { s.bassGuard = nil }
        s.bassGuardStrength = unit(s.bassGuardStrength)
        if s.bassGuardStrength == 1 { s.bassGuardStrength = nil }
        s.impulseFile = IRLibrary.safeName(s.impulseFile)
        s.impulseMix = s.impulseFile == nil ? nil : unit(s.impulseMix)
        if s.impulseMix == 1 { s.impulseMix = nil }
        return s
    }
}

struct StageDeviceStore: Equatable {
    static let defaultLimit = 64

    private(set) var settings: [String: StageSettings] = [:]
    private(set) var order: [String] = []
    private let limit: Int

    init(_ loaded: [String: StageSettings] = [:], limit: Int = defaultLimit) {
        self.limit = max(limit, 1)
        order = loaded.keys.sorted().suffix(self.limit).map { $0 }
        let kept = Set(order)
        settings = loaded.filter { kept.contains($0.key) }
    }

    subscript(uid: String) -> StageSettings? { settings[uid] }

    var values: Dictionary<String, StageSettings>.Values { settings.values }

    mutating func set(_ value: StageSettings, for uid: String) {
        settings[uid] = value
        touch(uid)
    }

    mutating func touch(_ uid: String) {
        guard settings[uid] != nil else { return }
        order.removeAll { $0 == uid }
        order.append(uid)
        while settings.count > limit, let oldest = order.first {
            order.removeFirst()
            settings.removeValue(forKey: oldest)
        }
    }
}

package struct DayExposure: Codable, Equatable {
    package var day: String
    package var audibleSeconds: Double
    package var loudSeconds: Double
    package var energySum: Double
}

struct PersistedStageState: Codable {
    var stageByDevice: [String: StageSettings] = [:]
    var exposure: [DayExposure] = []
    var levelTracking = false
    var detectQuality: Bool?
    var autoRate: Bool?
    var manualRateHz: Double?
    var a2dpGuard: String?
    var earCalibrationByDevice: [String: Double]?
    var perAppEQ: Bool?
}

enum SafeFile {
    static func read(_ url: URL, cap: Int) -> Data? {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
#if canImport(Glibc)
            let n = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
#else
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
#endif
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return data.isEmpty ? nil : data }
            data.append(contentsOf: chunk[0..<n])
            if data.count > cap { return nil }
        }
    }

    private static let heldLock = NSLock()
    private static var held = Set<String>()

    static func isHeld(_ url: URL) -> Bool {
        heldLock.lock()
        defer { heldLock.unlock() }
        return held.contains(url.standardizedFileURL.path)
    }

    private static func hold(_ url: URL) {
        heldLock.lock()
        held.insert(url.standardizedFileURL.path)
        heldLock.unlock()
    }

    @discardableResult
    static func setAsideIfUnreadable(_ url: URL) -> Bool {
        var st = stat()
        let present = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path, lstat(path, &st) == 0 else { return false }
            return st.st_mode & S_IFMT != S_IFREG || st.st_size > 0
        }
        guard present else { return false }
        let fm = FileManager.default
        func taken(_ candidate: URL) -> Bool {
            fm.fileExists(atPath: candidate.path)
                || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil
        }
        let all = ParkedCopy.candidates(beside: url)
        guard let target = all.first(where: { !taken($0) }) else {
            hold(url)
            DebugLog.shared.log("\(url.lastPathComponent) could not be read and every parking name is taken; it is left untouched")
            return false
        }
        let moved = url.withUnsafeFileSystemRepresentation { from -> Bool in
            guard let from else { return false }
            return target.withUnsafeFileSystemRepresentation { to -> Bool in
                guard let to else { return false }
                return rename(from, to) == 0
            }
        }
        if !moved { hold(url) }
        DebugLog.shared.log(moved
            ? "\(url.lastPathComponent) could not be read; it was moved aside as \(target.lastPathComponent)"
            : "\(url.lastPathComponent) could not be read and could not be moved aside")
        return moved
    }

    @discardableResult
    static func sweepStaleTemps(in directory: URL, olderThan age: TimeInterval = 3600,
                                now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where isTempName(name) {
            let file = directory.appendingPathComponent(name)
            var st = stat()
            let info = file.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path, lstat(path, &st) == 0 else { return false }
                return st.st_mode & S_IFMT == S_IFREG
            }
#if canImport(Glibc)
            let modified = Double(st.st_mtim.tv_sec)
#else
            let modified = Double(st.st_mtimespec.tv_sec)
#endif
            guard info, now.timeIntervalSince1970 - modified > age else { continue }
            let gone = file.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return unlink(path) == 0
            }
            if gone { removed += 1 }
        }
        return removed
    }

    static func isTempName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.count > 10 else { return false }
        let tail = name.suffix(9)
        guard tail.first == "." else { return false }
        return tail.dropFirst().allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }

    @discardableResult
    static func writeAtomic(_ data: Data, to url: URL) -> Bool {
        guard !isHeld(url) else { return false }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent
                                    + "." + String(UUID().uuidString.prefix(8)))
        let fd = temp.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let written = (try? handle.write(contentsOf: data)) != nil
#if canImport(Glibc)
        if written { Glibc.fsync(fd) }
        Glibc.close(fd)
#else
        if written { Darwin.fsync(fd) }
        Darwin.close(fd)
#endif
        let renamed = written && temp.withUnsafeFileSystemRepresentation { from -> Bool in
            guard let from else { return false }
            return url.withUnsafeFileSystemRepresentation { to -> Bool in
                guard let to else { return false }
                return rename(from, to) == 0
            }
        }
        guard renamed else {
            _ = temp.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return unlink(path)
            }
            return false
        }
        return true
    }
}

enum StageStateFile {
    static var directory: URL {
        let fm = FileManager.default
#if os(Linux)
        let parent = XDGDirectory.data()
#else
        let parent = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#endif
        let dir = parent.appendingPathComponent("QudelixBar", isDirectory: true)
        switch lstatMode(dir) {
        case let mode? where mode & S_IFMT == S_IFDIR:
            if mode & 0o777 != 0o700 {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        case .some:
            let aside = parent.appendingPathComponent(
                "QudelixBar.displaced-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: dir, to: aside)
            DebugLog.shared.log("state directory path was not a directory — "
                + "moved aside as \(aside.lastPathComponent)")
            fallthrough
        case nil:
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    private static func lstatMode(_ url: URL) -> mode_t? {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &st) == 0 else { return nil }
            return st.st_mode
        }
    }

    static var url: URL { directory.appendingPathComponent("stage.json") }

    private static let maxBytes = 1_000_000

    enum LoadOutcome {
        case absent
        case loaded(PersistedStageState)
        case unreadable(parked: Bool)

        var permitsSaving: Bool {
            if case .unreadable = self { return false }
            return true
        }
    }

    static func loadOutcome(_ url: URL = url) -> LoadOutcome {
        guard let data = SafeFile.read(url, cap: maxBytes) else {
            guard let mode = lstatMode(url) else { return .absent }
            return mode & S_IFMT == S_IFREG && lstatSize(url) == 0
                ? .absent : .unreadable(parked: false)
        }
        if let state = try? JSONDecoder().decode(PersistedStageState.self, from: data) {
            return .loaded(state)
        }
        return .unreadable(parked: ParkedCopy.park(data, beside: url) != nil)
    }

    private static func lstatSize(_ url: URL) -> off_t? {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { path -> off_t? in
            guard let path, lstat(path, &st) == 0 else { return nil }
            return st.st_size
        }
    }

    static func notice(for outcome: LoadOutcome,
                       fileName: String = "stage.json") -> String? {
        guard case .unreadable(let parked) = outcome else { return nil }
        let tail = " Changes to Stage and Level settings are not saved until it is "
            + "fixed. Move \(fileName) aside and relaunch to start fresh."
        if parked {
            return "\(fileName) couldn't be understood, so the saved Stage settings "
                + "were not loaded and the file is left alone. A copy is kept beside "
                + "it as \(fileName).recovered." + tail
        }
        return "\(fileName) couldn't be read, so the saved Stage settings were not "
            + "loaded and the file is left alone. Check its permissions and size."
            + tail
    }

    @discardableResult
    static func save(_ state: PersistedStageState, to url: URL = url) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return false }
        return SafeFile.writeAtomic(data, to: url)
    }
}
