import AppKit
@testable import BrewMenu
import Foundation
import os
import Testing

// MARK: - Package Fixtures

func makePackage(_ name: String = "wget", old: String = "1.0", new: String = "1.1") -> BrewPackage {
    BrewPackage(name: name, oldVersion: old, newVersion: new)
}

func outdatedJSON(
    formulae: [(String, String, String)] = [],
    casks: [(String, String, String)] = []
) -> String {
    func encode(_ name: String, _ old: String, _ new: String) -> String {
        "{\"name\":\"\(name)\",\"installed_versions\":[\"\(old)\"],\"current_version\":\"\(new)\"}"
    }
    let formulaeJson = formulae.map { encode($0.0, $0.1, $0.2) }.joined(separator: ",")
    let casksJson = casks.map { encode($0.0, $0.1, $0.2) }.joined(separator: ",")
    return "{\"formulae\":[\(formulaeJson)],\"casks\":[\(casksJson)]}"
}

// MARK: - Config Stub

struct MockConfig: BrewConfiguration {
    var greedyMode: GreedyMode = .disabled
    var cleanupSchedule: CleanupSchedule = .disabled
    var authTimeout: Int = 300
}

// MARK: - MockBrewCommandRunner

final class MockBrewCommandRunner: BrewCommandRunner, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var queue: [(String, String, Int32)] = []
    private(set) var executedCommands: [BrewCommand] = []

    func enqueue(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        lock.withLock { queue.append((stdout, stderr, exitCode)) }
    }

    func execute(_ command: BrewCommand) async -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.withLock {
            executedCommands.append(command)
            guard !queue.isEmpty else { return ("", "", 0) }
            let result = queue.removeFirst()
            return (stdout: result.0, stderr: result.1, exitCode: result.2)
        }
    }

    func terminateAll() {}
}

// MARK: - MockSettingsStore

final class MockSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var storage: [String: Any] = [:]

    func integer(forKey key: String) -> Int {
        lock.withLock { storage[key] as? Int ?? 0 }
    }

    func bool(forKey key: String) -> Bool {
        lock.withLock { storage[key] as? Bool ?? false }
    }

    func string(forKey key: String) -> String? {
        lock.withLock { storage[key] as? String }
    }

    func object(forKey key: String) -> Any? {
        lock.withLock { storage[key] }
    }

    func set(_ value: Any?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }
}

// MARK: - MockCoordinator (BrewStatusManager)

@MainActor
final class MockCoordinator: BrewStatusManager {
    var status: AppStatus = .idle
    var outdatedPackages: [BrewPackage] = []
    var activeUpgradePackageName: String?
    var errorMessage: String?
    var lastCheckDate: Date?
    var transitionHistory: [AppStatus] = []
    var checkModes: [ScanMode] = []
    // 每次 check() 从队列取一批，模拟真实 refresh 结果；队列耗尽则保持当前值不变
    var outdatedQueue: [[BrewPackage]] = []
    var cleanupCallCount = 0

    func transition(to newStatus: AppStatus) {
        status = newStatus
        transitionHistory.append(newStatus)
    }

    func setActiveUpgrade(_ name: String?) {
        activeUpgradePackageName = name
    }

    func setErrorMessage(_ msg: String?) {
        errorMessage = msg
    }

    func check(mode: ScanMode) async {
        checkModes.append(mode)
        outdatedPackages = outdatedQueue.isEmpty ? [] : outdatedQueue.removeFirst()
    }

    func cleanup() async {
        cleanupCallCount += 1
    }

    var cancelCallCount = 0
    var lastCancelShouldAbortSequence: Bool?
    func cancel(shouldAbortSequence: Bool) {
        cancelCallCount += 1
        lastCancelShouldAbortSequence = shouldAbortSequence
    }
}

// MARK: - MockBrewService

final class MockBrewService: BrewServiceProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var outdatedQueue: [Result<[BrewPackage], BrewError>] = []
    private var upgradeQueue: [Result<Bool, BrewError>] = []
    private var stillOutdatedQueue: [Bool] = []
    private(set) var cleanupCallCount = 0
    private(set) var terminateCallCount = 0

    func enqueueOutdated(_ result: Result<[BrewPackage], BrewError>) {
        lock.withLock { outdatedQueue.append(result) }
    }

    func enqueueUpgrade(_ result: Result<Bool, BrewError>) {
        lock.withLock { upgradeQueue.append(result) }
    }

    func enqueueStillOutdated(_ value: Bool) {
        lock.withLock { stillOutdatedQueue.append(value) }
    }

    func getOutdatedPackages(shouldUpdate _: Bool, greedyArgs _: [String]) async -> Result<[BrewPackage], BrewError> {
        lock.withLock { outdatedQueue.isEmpty ? .success([]) : outdatedQueue.removeFirst() }
    }

    func checkIfPackageIsStillOutdated(name _: String, greedyArgs _: [String]) async -> Bool {
        lock.withLock { stillOutdatedQueue.isEmpty ? true : stillOutdatedQueue.removeFirst() }
    }

    func upgrade(packages _: [BrewPackage], greedyArgs _: [String], authTimeout _: Int, onPID _: (@Sendable (Int32) -> Void)?) async -> Result<Bool, BrewError> {
        lock.withLock { upgradeQueue.isEmpty ? .success(true) : upgradeQueue.removeFirst() }
    }

    func terminateAll() {
        lock.withLock { terminateCallCount += 1 }
    }

    func cleanup(pruneDays _: Int) async -> Bool {
        lock.withLock { cleanupCallCount += 1; return true }
    }
}

// MARK: - MockNotificationService

@MainActor
final class MockNotificationService: NotificationServiceProtocol {
    var onAuthorizeActionTapped: (() -> Void)?

    struct UpgradeResultCall {
        let upgraded: [BrewPackage]
        let success: Bool
        let requestedNames: [String]
        let skippedNames: [String]
        let externalSuccessNames: [String]
        let failedErrors: [String: String]
    }

    struct UpdatesFoundCall {
        let packages: [BrewPackage]
        let willAutoUpgrade: Bool
    }

    private(set) var upgradeResultCalls: [UpgradeResultCall] = []
    private(set) var transientErrorCalls: [(BrewError, String?)] = []
    private(set) var updatesFoundCalls: [UpdatesFoundCall] = []
    private(set) var authRequiredCalls: Int = 0
    private(set) var authTimeoutCalls: Int = 0
    private(set) var brewNotFoundCalls: Int = 0

    func requestAuthorization() {}
    func showUpgradeResult(upgraded: [BrewPackage], success: Bool, requestedNames: [String], skippedNames: [String], externalSuccessNames: [String], failedErrors: [String: String]) {
        upgradeResultCalls.append(UpgradeResultCall(upgraded: upgraded, success: success, requestedNames: requestedNames, skippedNames: skippedNames, externalSuccessNames: externalSuccessNames, failedErrors: failedErrors))
    }

    func showUpdatesFound(packages: [BrewPackage], willAutoUpgrade: Bool) {
        updatesFoundCalls.append(UpdatesFoundCall(packages: packages, willAutoUpgrade: willAutoUpgrade))
    }

    private(set) var noUpdatesFoundCalls: Int = 0
    func showNoUpdatesFound() {
        noUpdatesFoundCalls += 1
    }

    func showAuthRequired(packageNames _: [String], isRetry _: Bool) {
        authRequiredCalls += 1
    }

    func showAuthTimeout(packageName _: String) {
        authTimeoutCalls += 1
    }

    func showTransientError(error: BrewError, packageName: String?) {
        transientErrorCalls.append((error, packageName))
    }

    func showBrewNotFound() {
        brewNotFoundCalls += 1
    }
}
