import Foundation
import Observation

/// Write-side coordinator interface for subsystems (UpgradeEngine, SudoMonitor, AutoScheduler).
///
/// Subsystems receive this narrow view of the coordinator: they can read current
/// state and push state transitions, but they cannot invoke user-facing actions.
@MainActor
protocol BrewStatusManager: AnyObject {
    var status: AppStatus { get }
    var outdatedPackages: [BrewPackage] { get }
    var activeUpgradePackageName: String? { get }
    var errorMessage: String? { get }

    func transition(to status: AppStatus)
    func setActiveUpgrade(_ packageName: String?)
    func setErrorMessage(_ message: String?)

    func check(mode: ScanMode) async
}

extension BrewStatusManager {
    func check() async { await check(mode: .manual) }
}

/// Full coordinator interface for Views.
///
/// Extends BrewStatusManager with read-only display state and user-action entry
/// points. Requiring Observable lets views stay generic (no concrete AppCoordinator
/// import) while keeping @Observable body-invalidation intact at the call site.
@MainActor
protocol BrewMenuCoordinating: BrewStatusManager, Observable {
    var lastCheckDate: Date? { get }

    func upgrade() async
    func upgrade(package: BrewPackage) async
    func cancel()
    func triggerAuthorizationUI()
}
