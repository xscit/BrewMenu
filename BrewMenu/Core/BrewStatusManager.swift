import Foundation
import Observation

/// Write-side coordinator interface for subsystems (UpgradeEngine, SudoMonitor, AutoScheduler, CleanupScheduler).
///
/// Subsystems receive this narrow view of the coordinator: they can read current
/// state and push state transitions, but they cannot invoke user-facing actions.
@MainActor
protocol BrewStatusManager: AnyObject {
    var status: AppStatus { get }
    var outdatedPackages: [BrewPackage] { get }
    var activeUpgradePackageName: String? { get }
    var errorMessage: String? { get }
    var lastCheckDate: Date? { get }

    func transition(to status: AppStatus)
    func setActiveUpgrade(_ packageName: String?)
    func setErrorMessage(_ message: String?)

    func check(mode: ScanMode) async
    func cleanup() async
    func cancel(shouldAbortSequence: Bool)
}

extension BrewStatusManager {
    func check() async {
        await check(mode: .manual)
    }

    func cancel() {
        cancel(shouldAbortSequence: true)
    }
}

/// Full coordinator interface for Views.
///
/// Extends BrewStatusManager with read-only display state and user-action entry
/// points. Requiring Observable lets views stay generic (no concrete AppCoordinator
/// import) while keeping @Observable body-invalidation intact at the call site.
@MainActor
protocol BrewMenuCoordinating: BrewStatusManager, Observable {
    func upgrade() async
    func upgrade(package: BrewPackage) async
    func triggerAuthorizationUI()
    func pin(package: BrewPackage)
    func unpin(packageName: String)
}
