import Foundation

struct CLIOptions: Equatable {
    var preferred: QxLinkKind?
    var json = false
    var timeout: TimeInterval = 5
    var verbose = false
}

enum CLICommand: Equatable {
    case help
    case probe
    case status
    case watch
    case volumeShow
    case volumeSet(Double)
    case volumeMute(Bool)
    case filterList
    case filterSet(Int)
    case eqShow
    case eqEnable(Bool)
    case presetList
    case presetLoad(Int)
    case presetSave(Int)
    case presetRename(index: Int, name: String)
    case presetPull(String)
    case presetPush(String)
    case importFile(String)
    case library(LibraryCommand)
    case ai(AICommand)
    case history(HistoryCommand)
}

struct CLIInvocation: Equatable {
    var options: CLIOptions
    var command: CLICommand
}

struct CLIUsageError: Error, Equatable {
    var message: String
}

enum CLIExit {
    static let ok: Int32 = 0
    static let deviceError: Int32 = 1
    static let usageError: Int32 = 2
    static let noTransport: Int32 = 3
}

enum CLI {
    static let maxImportBytes = 1 << 20
    static let maxSnapshotBytes = 100_000

    static let usageText = """
    qudelix — command-line control for the Qudelix 5K

    usage: qudelix [flags] <command>

    commands:
      probe                     report what this machine offers, without touching the device
      status                    model, firmware, battery, volume, DAC filter, EQ, preset
      watch                     print device notifications until interrupted
      volume                    show the current output level
      volume <dB>               set the output level
      volume mute | unmute      mute or unmute the output
      filter                    list the DAC reconstruction filters
      filter <index|name>       select a DAC reconstruction filter
      eq show                   pre-gain and the band table
      eq on | off               enable or disable the EQ
      preset list               every device slot, 1…\(QudelixController.presetCount)
      preset load <n>           load a device slot into the live EQ
      preset save <n>           save the live EQ into a device slot
      preset name <n> <name>    rename a device slot
      preset pull <file>        write the live EQ to a JSON file
      preset push <file>        apply a JSON file written by pull
      import <autoeq.txt>       apply a parametric-EQ text file
    \(LibraryCommand.usageLines.joined(separator: "\n"))
    \(AICommand.usageLines.joined(separator: "\n"))
    \(HistoryCommand.usageLines.joined(separator: "\n"))

    flags:
      --usb                     use the USB link
      --ble                     use the Bluetooth link
      --json                    print one JSON object instead of text
      --timeout <seconds>       how long to wait for the device (default 5)
      --verbose                 mirror the packet log to stderr
      --help                    print this text

    exit codes: 0 ok · 1 the device answered and then failed · 2 usage error
                3 no transport reached the device
    """

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var options = CLIOptions()
        var positional: [String] = []
        var wantsHelp = false
        var flagsEnded = false
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if flagsEnded {
                positional.append(token)
                continue
            }
            switch token {
            case "--":
                flagsEnded = true
            case "--usb":
                options.preferred = .usb
            case "--ble", "--bluetooth":
                options.preferred = .bluetooth
            case "--json":
                options.json = true
            case "--verbose", "-v":
                options.verbose = true
            case "--help", "-h":
                wantsHelp = true
            case "--timeout":
                guard index < arguments.count else {
                    throw CLIUsageError(message: "--timeout needs a number of seconds")
                }
                options.timeout = try seconds(arguments[index])
                index += 1
            default:
                if token.hasPrefix("--timeout=") {
                    options.timeout = try seconds(String(token.dropFirst("--timeout=".count)))
                } else if token.hasPrefix("-"), token.count > 1, Double(token) == nil {
                    throw CLIUsageError(message: "unknown option \(token)")
                } else {
                    positional.append(token)
                }
            }
        }
        if wantsHelp { return CLIInvocation(options: options, command: .help) }
        return CLIInvocation(options: options, command: try command(positional))
    }

    private static func seconds(_ raw: String) throws -> TimeInterval {
        guard let value = Double(raw), value.isFinite, value > 0, value <= 600 else {
            throw CLIUsageError(message: "--timeout needs a positive number of seconds")
        }
        return value
    }

    private static func command(_ positional: [String]) throws -> CLICommand {
        guard let head = positional.first else {
            throw CLIUsageError(message: "no command given")
        }
        let rest = Array(positional.dropFirst())
        switch head {
        case "probe":
            try expect(rest, 0, head)
            return .probe
        case "status":
            try expect(rest, 0, head)
            return .status
        case "watch":
            try expect(rest, 0, head)
            return .watch
        case "volume":
            return try volume(rest)
        case "filter":
            return try filter(rest)
        case "eq":
            return try eq(rest)
        case "preset":
            return try preset(rest)
        case LibraryCommand.name:
            return .library(try LibraryCommand.parse(rest))
        case AICommand.name:
            return .ai(try AICommand.parse(rest))
        case HistoryCommand.name:
            return .history(try HistoryCommand.parse(rest))
        case "import":
            guard rest.count == 1 else {
                throw CLIUsageError(message: "import needs one file path")
            }
            return .importFile(rest[0])
        case "help":
            return .help
        default:
            throw CLIUsageError(message: "unknown command \(head)")
        }
    }

    private static func expect(_ rest: [String], _ count: Int, _ what: String) throws {
        guard rest.count == count else {
            throw CLIUsageError(message: count == 0
                ? "\(what) takes no arguments"
                : "\(what) takes \(count) argument\(count == 1 ? "" : "s")")
        }
    }

    private static func volume(_ rest: [String]) throws -> CLICommand {
        guard let argument = rest.first else { return .volumeShow }
        guard rest.count == 1 else {
            throw CLIUsageError(message: "volume takes one argument")
        }
        switch argument.lowercased() {
        case "mute": return .volumeMute(true)
        case "unmute": return .volumeMute(false)
        default:
            guard let db = Double(argument), db.isFinite else {
                throw CLIUsageError(
                    message: "volume takes a level in dB, or mute/unmute — not \(argument)")
            }
            return .volumeSet(db)
        }
    }

    private static func filter(_ rest: [String]) throws -> CLICommand {
        guard let argument = rest.first else { return .filterList }
        guard rest.count == 1 else {
            throw CLIUsageError(message: "filter takes one index or name")
        }
        return .filterSet(try resolveFilter(argument))
    }

    static func resolveFilter(_ token: String) throws -> Int {
        if let index = Int(token) {
            guard QxStatusParser.dacFilters.indices.contains(index) else {
                throw CLIUsageError(
                    message: "there is no DAC filter \(index) — run 'qudelix filter' for the list")
            }
            return index
        }
        let needle = token.lowercased()
        let matches = QxStatusParser.dacFilters.enumerated()
            .filter { $0.element.lowercased().contains(needle) }
        guard matches.count == 1, let only = matches.first else {
            throw CLIUsageError(message: matches.isEmpty
                ? "no DAC filter matches \"\(token)\" — run 'qudelix filter' for the list"
                : "\"\(token)\" matches \(matches.count) DAC filters — be more specific")
        }
        return only.offset
    }

    private static func eq(_ rest: [String]) throws -> CLICommand {
        guard let sub = rest.first else {
            throw CLIUsageError(message: "eq needs show, on or off")
        }
        try expect(Array(rest.dropFirst()), 0, "eq \(sub)")
        switch sub {
        case "show": return .eqShow
        case "on", "enable": return .eqEnable(true)
        case "off", "disable": return .eqEnable(false)
        default: throw CLIUsageError(message: "eq needs show, on or off — not \(sub)")
        }
    }

    private static func preset(_ rest: [String]) throws -> CLICommand {
        guard let sub = rest.first else {
            throw CLIUsageError(message: "preset needs list, load, save, name, pull or push")
        }
        let arguments = Array(rest.dropFirst())
        switch sub {
        case "list":
            try expect(arguments, 0, "preset list")
            return .presetList
        case "load":
            guard arguments.count == 1 else {
                throw CLIUsageError(message: "preset load needs a slot number")
            }
            return .presetLoad(try slot(arguments[0]))
        case "save":
            guard arguments.count == 1 else {
                throw CLIUsageError(message: "preset save needs a slot number")
            }
            return .presetSave(try slot(arguments[0]))
        case "name":
            guard arguments.count == 2 else {
                throw CLIUsageError(message: "preset name needs a slot number and a name")
            }
            return .presetRename(index: try slot(arguments[0]), name: arguments[1])
        case "pull":
            guard arguments.count == 1 else {
                throw CLIUsageError(message: "preset pull needs a file path")
            }
            return .presetPull(arguments[0])
        case "push":
            guard arguments.count == 1 else {
                throw CLIUsageError(message: "preset push needs a file path")
            }
            return .presetPush(arguments[0])
        default:
            throw CLIUsageError(
                message: "preset needs list, load, save, name, pull or push — not \(sub)")
        }
    }

    static func slot(_ token: String) throws -> Int {
        let count = QudelixController.presetCount
        guard let number = Int(token), (1...count).contains(number) else {
            throw CLIUsageError(message: "a preset slot is a number from 1 to \(count)")
        }
        return number - 1
    }

    static func needsDevice(_ command: CLICommand) -> Bool {
        switch command {
        case .help, .probe: return false
        case .library(let family): return family.needsDevice
        case .ai(let family): return family.needsDevice
        case .history(let family): return family.needsDevice
        default: return true
        }
    }
}

enum QudelixCLI {
    static func run(arguments: [String],
                    makeLinks: (QxLinkKind?) -> [QxLink]) async -> Int32 {
        let invocation: CLIInvocation
        do {
            invocation = try CLI.parse(arguments)
        } catch let error as CLIUsageError {
            StdIO.error("qudelix: " + error.message)
            StdIO.error("try 'qudelix --help'")
            return CLIExit.usageError
        } catch {
            StdIO.error("qudelix: \(error)")
            return CLIExit.usageError
        }

        Trace.verbose = invocation.options.verbose

        switch invocation.command {
        case .help:
            StdIO.out(CLI.usageText)
            return CLIExit.ok
        case .probe:
            let report = Probe.report(.system())
            if invocation.options.json {
                StdIO.out(QxFormat.json(Probe.object(report)))
            } else {
                for line in Probe.lines(report) { StdIO.out(line) }
            }
            return CLIExit.ok
        default:
            break
        }

        if !CLI.needsDevice(invocation.command) {
            do {
                try await execute(invocation, nil)
                return CLIExit.ok
            } catch let error as CLIUsageError {
                StdIO.error("qudelix: " + error.message)
                return CLIExit.usageError
            } catch {
                StdIO.error("qudelix: " + describe(error))
                return CLIExit.deviceError
            }
        }

        let links = makeLinks(invocation.options.preferred)
        guard !links.isEmpty else {
            StdIO.error("qudelix: no transport available")
            if let advice = Probe.permissionAdvice(Probe.report(.system())) {
                StdIO.error("qudelix: " + advice)
            }
            return CLIExit.noTransport
        }

        var connected: QxSession?
        var failures: [(kind: QxLinkKind, error: Error)] = []
        for link in links {
            let session = QxSession(link: link, timeout: invocation.options.timeout)
            do {
                try await session.connect(timeout: invocation.options.timeout)
                connected = session
                break
            } catch {
                failures.append((link.kind, error))
                session.close()
            }
        }
        guard let session = connected else {
            let report = Probe.report(.system())
            let sawUsbNode = report.nodes.contains { $0.isQudelix }
            for failure in failures {
                StdIO.error("qudelix: \(failure.kind.rawValue): "
                    + connectFailureText(failure.error, kind: failure.kind,
                                         sawUsbNode: sawUsbNode))
            }
            if let advice = Probe.permissionAdvice(report) {
                StdIO.error("qudelix: " + advice)
            }
            return failures.allSatisfy { isMissingTransport($0.error) }
                ? CLIExit.noTransport : CLIExit.deviceError
        }
        defer { session.close() }

        do {
            try await execute(invocation, session)
            if persistsToFlash(invocation.command) { try await session.saveAll() }
            return CLIExit.ok
        } catch let error as CLIUsageError {
            StdIO.error("qudelix: " + error.message)
            return CLIExit.usageError
        } catch {
            StdIO.error("qudelix: " + describe(error))
            return CLIExit.deviceError
        }
    }

    static func isMissingTransport(_ error: Error) -> Bool {
        guard let session = error as? QxSessionError else { return false }
        switch session {
        case .linkUnusable: return true
        case .timedOut(let what): return what == QxSession.deviceAppearance
        default: return false
        }
    }

    static func connectFailureText(_ error: Error, kind: QxLinkKind,
                                   sawUsbNode: Bool) -> String {
        if kind == .usb, !sawUsbNode,
           let session = error as? QxSessionError,
           case .timedOut(QxSession.deviceAppearance) = session {
            return "no Qudelix 5K found on USB (no matching /dev/hidraw node)"
        }
        return describe(error)
    }

    static func persistsToFlash(_ command: CLICommand) -> Bool {
        switch command {
        case .importFile, .presetPush, .eqEnable: return true
        case .library(let family): return family.persistsToFlash
        case .ai(let family): return family.persistsToFlash
        case .history(let family): return family.persistsToFlash
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        if let session = error as? QxSessionError { return session.description }
        if let usage = error as? CLIUsageError { return usage.message }
        return "\(error)"
    }

    private static func execute(_ invocation: CLIInvocation, _ session: QxSession?) async throws {
        let json = invocation.options.json
        switch invocation.command {
        case .help, .probe:
            return
        case .library(let family):
            try await family.run(options: invocation.options, session: session)
            return
        case .ai(let family):
            try await family.run(options: invocation.options, session: session)
            return
        case .history(let family):
            try await family.run(options: invocation.options, session: session)
            return
        default:
            break
        }
        guard let session else { throw CLIUsageError(message: "this command needs the device") }
        switch invocation.command {
        case .help, .probe, .library, .ai, .history:
            return

        case .status:
            let first = await session.snapshot()
            if let index = first.activePresetIndex {
                _ = try? await session.presetName(index: index)
            }
            let snapshot = await session.snapshot()
            if json {
                StdIO.out(QxFormat.json(QxFormat.statusObject(snapshot)))
            } else {
                for line in QxFormat.statusLines(snapshot) { StdIO.out(line) }
            }

        case .watch:
            for await line in session.notifications() { StdIO.out(line) }

        case .volumeShow:
            let snapshot = await session.snapshot()
            if json {
                var object: [String: Any] = [:]
                QxFormat.put(&object, "volume_db", snapshot.volumeDb)
                QxFormat.put(&object, "volume_limit_db", snapshot.volumeLimitDb)
                QxFormat.put(&object, "mute", snapshot.muted)
                StdIO.out(QxFormat.json(object))
            } else {
                StdIO.out(snapshot.volumeDb.map(QxFormat.db) ?? "unknown")
            }

        case .volumeSet(let db):
            try await session.setVolume(db: db)
            try? await session.refreshStatus()
            let snapshot = await session.snapshot()
            report(json, text: "volume " + (snapshot.volumeDb.map(QxFormat.db) ?? "set"),
                   object: ["volume_db": snapshot.volumeDb ?? db])

        case .volumeMute(let on):
            try await session.setMute(on)
            report(json, text: on ? "muted" : "unmuted", object: ["mute": on])

        case .filterList:
            let snapshot = await session.snapshot()
            if json {
                var object: [String: Any] = ["filters": QxStatusParser.dacFilters]
                QxFormat.put(&object, "current_index", snapshot.dacFilterIndex)
                StdIO.out(QxFormat.json(object))
            } else {
                for line in QxFormat.filterLines(current: snapshot.dacFilterIndex) {
                    StdIO.out(line)
                }
            }

        case .filterSet(let index):
            try await session.setDacFilter(index: index)
            report(json, text: "dac filter \(index) — \(QxStatusParser.dacFilters[index])",
                   object: ["dac_filter_index": index,
                            "dac_filter": QxStatusParser.dacFilters[index]])

        case .eqShow:
            let preset = try await session.readPreset()
            let snapshot = await session.snapshot()
            if json {
                StdIO.out(QxFormat.json(QxFormat.eqObject(preGain: preset.preGain,
                                                          bands: preset.bands,
                                                          enabled: snapshot.eqEnabled,
                                                          group: snapshot.eqGroup)))
            } else {
                StdIO.out("eq        " + QxFormat.onOff(snapshot.eqEnabled))
                for line in QxFormat.eqLines(preGain: preset.preGain, bands: preset.bands) {
                    StdIO.out(line)
                }
            }

        case .eqEnable(let on):
            try await session.setEqEnabled(on)
            report(json, text: "eq " + (on ? "on" : "off"), object: ["eq_enabled": on])

        case .presetList:
            let names = try await session.namedPresets()
            let snapshot = await session.snapshot()
            let count = QudelixController.presetCount
            if json {
                StdIO.out(QxFormat.json([
                    "presets": (0..<count).map { index -> [String: Any] in
                        var entry: [String: Any] = [
                            "slot": index + 1,
                            "label": QxFormat.presetLabel(index, names[index]),
                            "active": index == snapshot.activePresetIndex,
                        ]
                        QxFormat.put(&entry, "name", names[index])
                        return entry
                    },
                ]))
            } else {
                for line in QxFormat.presetLines(names, count: count,
                                                 active: snapshot.activePresetIndex) {
                    StdIO.out(line)
                }
            }

        case .presetLoad(let index):
            let preset = try await session.loadPreset(index: index)
            if json {
                StdIO.out(QxFormat.json(QxFormat.eqObject(preGain: preset.preGain,
                                                          bands: preset.bands,
                                                          enabled: nil,
                                                          group: await session.snapshot().eqGroup)))
            } else {
                StdIO.out("loaded preset \(index + 1)")
                for line in QxFormat.eqLines(preGain: preset.preGain, bands: preset.bands) {
                    StdIO.out(line)
                }
            }

        case .presetSave(let index):
            try await session.savePreset(index: index)
            report(json, text: "saved to preset \(index + 1)", object: ["slot": index + 1])

        case .presetRename(let index, let name):
            try await session.renamePreset(index: index, name: name)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let readback = try? await session.presetName(index: index)
            let label = QxFormat.presetLabel(index, readback ?? nil)
            report(json, text: "preset \(index + 1) — \(label)",
                   object: ["slot": index + 1, "name": label])

        case .presetPull(let path):
            let preset = try await session.readPreset()
            let snapshot = await session.snapshot()
            let record = EqSnapshot(groupRaw: snapshot.eqGroup.rawValue,
                                    bands: preset.bands,
                                    preGain: preset.preGain,
                                    enabled: snapshot.eqEnabled ?? true,
                                    name: snapshot.activePresetName,
                                    mutedBands: [:],
                                    deviceIdentity: snapshot.deviceIdentity)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(record) else {
                throw CLIUsageError(message: "could not encode the EQ")
            }
            guard SafeFile.writeAtomic(data, to: URL(fileURLWithPath: path)) else {
                throw CLIUsageError(message: "could not write \(path)")
            }
            report(json, text: "wrote \(path)", object: ["path": path])

        case .presetPush(let path):
            let group = await session.snapshot().eqGroup
            let record = try loadSnapshotFile(path, group: group)
            var file = ParametricEQFile()
            file.preamp = record.preGain
            file.bands = record.bands
            let applied = try await session.applyParametric(file, expecting: group)
            if !record.enabled { try await session.setEqEnabled(false) }
            if json {
                StdIO.out(QxFormat.json(QxFormat.eqObject(preGain: applied.preGain,
                                                          bands: applied.bands,
                                                          enabled: record.enabled,
                                                          group: await session.snapshot().eqGroup)))
            } else {
                StdIO.out("applied \(path)")
                for line in QxFormat.eqLines(preGain: applied.preGain, bands: applied.bands) {
                    StdIO.out(line)
                }
            }

        case .importFile(let path):
            let text = try readText(path)
            guard let file = ParametricEQFile.parse(text) else {
                throw CLIUsageError(message: "no EQ filters found in \(path)")
            }
            let applied = try await session.applyParametric(file)
            if json {
                var object = QxFormat.eqObject(preGain: applied.preGain,
                                               bands: applied.bands,
                                               enabled: true,
                                               group: await session.snapshot().eqGroup)
                object["notes"] = file.notes
                object["dropped_bands"] = file.droppedBands
                StdIO.out(QxFormat.json(object))
            } else {
                StdIO.out("applied \(file.bands.count) band(s) from \(path)")
                for note in file.notes { StdIO.out("note: " + note) }
                for line in QxFormat.eqLines(preGain: applied.preGain, bands: applied.bands) {
                    StdIO.out(line)
                }
            }
        }
    }

    private static func report(_ json: Bool, text: String, object: [String: Any]) {
        StdIO.out(json ? QxFormat.json(object) : text)
    }

    static func readText(_ path: String) throws -> String {
        guard let data = SafeFile.read(URL(fileURLWithPath: path), cap: CLI.maxImportBytes) else {
            throw CLIUsageError(
                message: "could not read \(path) — an EQ preset is a plain text file, "
                    + "and not a large one")
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw CLIUsageError(message: "could not read \(path) as text")
        }
        return text
    }

    static func loadSnapshotFile(_ path: String, group: QxEqGroup) throws -> EqSnapshot {
        guard let data = SafeFile.read(URL(fileURLWithPath: path), cap: CLI.maxSnapshotBytes) else {
            throw CLIUsageError(message: "could not read \(path)")
        }
        guard let store = try? JSONDecoder().decode(EqSnapshotStore.self, from: data) else {
            throw CLIUsageError(message: "\(path) is not an EQ file this tool wrote")
        }
        if let match = store[group.rawValue] { return match }
        guard store.byGroup.count == 1, let only = store.byGroup.values.first else {
            throw CLIUsageError(
                message: "\(path) holds no curve for the \(QxFormat.groupLabel(group)) group")
        }
        guard only.bands.count == group.bandCount else {
            throw CLIUsageError(
                message: "\(path) holds \(only.bands.count) bands, and this device is in "
                    + QxFormat.groupLabel(group) + " mode")
        }
        return only
    }
}

protocol CLIFamily: Equatable {
    static var name: String { get }
    static var usageLines: [String] { get }
    static func parse(_ rest: [String]) throws -> Self
    var needsDevice: Bool { get }
    var persistsToFlash: Bool { get }
    func run(options: CLIOptions, session: QxSession?) async throws
}
