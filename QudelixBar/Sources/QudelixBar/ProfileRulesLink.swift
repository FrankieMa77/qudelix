import Combine
import Foundation

@MainActor
final class ProfileRulesLink {
    private weak var controller: QudelixController?
    private weak var rules: ProfileRules?
    private var sources: Set<AnyCancellable> = []

    static func knownGroupRaw(connection: QudelixController.ConnectionState,
                              modeReported: Bool, group: QxEqGroup) -> UInt8? {
        guard case .connected = connection, modeReported else { return nil }
        return group.rawValue
    }

    init(controller: QudelixController, rules: ProfileRules) {
        self.controller = controller
        self.rules = rules

        rules.onApplyPreset = { [weak controller] index in
            controller?.loadPreset(index) ?? false
        }
        rules.presetLabel = { [weak controller] index in
            controller?.presetLabel(index) ?? "Preset \(index + 1)"
        }
        rules.canApplyNow = { [weak controller, weak rules] in
            guard let controller, controller.canWriteNow,
                  !controller.byEarSessionActive,
                  controller.activePreset != nil else { return false }
            return rules?.editingNow != true
        }

        Publishers.MergeMany([
            controller.$connection.map { _ in () }.eraseToAnyPublisher(),
            controller.$compatibility.map { _ in () }.eraseToAnyPublisher(),
            controller.$eqGroup.map { _ in () }.eraseToAnyPublisher(),
            controller.$sawEqMode.map { _ in () }.eraseToAnyPublisher(),
            controller.$activePreset.map { _ in () }.eraseToAnyPublisher(),
            controller.$byEarSessionActive.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.push() }
        }
        .store(in: &sources)

        push()
    }

    func push() {
        guard let controller, let rules else { return }
        rules.currentEqGroupRaw = Self.knownGroupRaw(connection: controller.connection,
                                                     modeReported: controller.sawEqMode,
                                                     group: controller.eqGroup)
        if controller.canWriteNow { rules.retryDeferredAutomatic() }
    }
}
