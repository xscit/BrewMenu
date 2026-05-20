@testable import BrewMenu
import Testing
import UserNotifications

// MARK: - Content Generation

@Suite("NotificationService Content")
@MainActor
struct NotificationServiceContentTests {
    private let svc = NotificationService.shared

    private func content(
        upgraded: [BrewPackage] = [],
        success: Bool = true,
        requested: [String] = [],
        skipped: [String] = [],
        external: [String] = [],
        failedErrors: [String: String] = [:]
    ) -> (title: String, body: String) {
        svc.upgradeResultContent(
            upgraded: upgraded,
            success: success,
            requestedNames: requested,
            skippedNames: skipped,
            externalSuccessNames: external,
            failedErrors: failedErrors
        )
    }

    // MARK: Title 选择

    @Test func titleIsBrewUpdatedOnFullSuccess() {
        let (title, _) = content(upgraded: [makePackage("wget")], success: true, requested: ["wget"])
        #expect(title == "Brew Updated")
    }

    @Test func titleIsPartialUpgradeOnFailure() {
        let (title, _) = content(upgraded: [makePackage("wget")], success: false, requested: ["wget", "curl"])
        #expect(title == "Partial Upgrade")
    }

    @Test func titleIsUpgradeFailedWhenNothingSucceeded() {
        let (title, _) = content(upgraded: [], success: false, requested: ["wget"])
        #expect(title == "Upgrade Failed")
    }

    @Test func titleIsBrewReadyWhenNothingHappened() {
        let (title, _) = content(upgraded: [], success: true, requested: [])
        #expect(title == "Brew Ready")
    }

    @Test func titleAuthFailedIsUpgradeFailed() {
        let (title, _) = content(upgraded: [], success: false, requested: ["wget"])
        #expect(title == "Upgrade Failed")
    }

    @Test func allSkippedTitleIsBrewUpdated() {
        let (title, _) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(title == "Brew Updated")
    }

    // MARK: Body — 成功行

    @Test func bodyContainsUpgradedPackageWithVersions() {
        let (_, body) = content(upgraded: [makePackage("wget", old: "1.0", new: "1.1")], success: true, requested: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("1.0"))
        #expect(body.contains("1.1"))
    }

    @Test func successBodyContainsVersionArrow() {
        let (_, body) = content(upgraded: [makePackage("wget", old: "1.0", new: "1.1")], success: true, requested: ["wget"])
        #expect(body.contains("→"))
    }

    @Test func bodyContainsMultiplePackageLines() {
        let (_, body) = content(
            upgraded: [makePackage("wget"), makePackage("git")],
            success: true,
            requested: ["wget", "git"]
        )
        #expect(body.contains("wget"))
        #expect(body.contains("git"))
    }

    // MARK: Body — 外部升级 / 跳过 / 失败

    @Test func bodyContainsExternalPackage() {
        let (_, body) = content(upgraded: [makePackage("wget")], success: true, requested: ["wget"], external: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Already current"))
    }

    @Test func externalPackageIsFilteredFromUpgradedLines() {
        let (_, body) = content(upgraded: [makePackage("wget")], success: true, requested: ["wget"], external: ["wget"])
        #expect(!body.contains("→"))
    }

    @Test func bodyContainsSkippedPackage() {
        let (_, body) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Skipped"))
    }

    @Test func allSkippedBodyContainsSkipped() {
        let (_, body) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Skipped"))
    }

    @Test func bodyAuthCancelledShowsSkipped() {
        let (_, body) = content(upgraded: [], success: true, requested: ["wget"], skipped: ["wget"])
        #expect(body.contains("Skipped"))
        #expect(!body.contains("Failed"))
    }

    @Test func bodyContainsFailedPackage() {
        let (_, body) = content(upgraded: [], success: false, requested: ["wget", "curl"], skipped: ["wget"])
        #expect(body.contains("curl"))
        #expect(body.contains("Failed"))
    }

    @Test func bodyAuthFailedShowsFailed() {
        let (_, body) = content(upgraded: [], success: false, requested: ["wget"])
        #expect(body.contains("wget"))
        #expect(body.contains("Failed"))
    }

    @Test func bodyContainsFailedReasonWhenProvided() {
        let (_, body) = content(
            upgraded: [],
            success: false,
            requested: ["wget"],
            failedErrors: ["wget": "Network unavailable"]
        )
        #expect(body.contains("wget"))
        #expect(body.contains("Network unavailable"))
    }

    // MARK: failedNames 计算

    @Test func failedNamesExcludesSkippedAndExternal() {
        let (_, body) = content(
            upgraded: [],
            success: false,
            requested: ["wget", "curl", "git"],
            skipped: ["wget"],
            external: ["curl"]
        )
        #expect(body.contains("git"))
        #expect(!body.contains("wget") || body.contains("Skipped"))
    }

    @Test func externalAndSkippedBothPresent() {
        let (_, body) = content(
            upgraded: [],
            success: true,
            requested: ["wget", "curl"],
            skipped: ["curl"],
            external: ["wget"]
        )
        #expect(body.contains("Already current"))
        #expect(body.contains("Skipped"))
    }
}

// MARK: - Content helpers for other notification types

@Suite("NotificationService Other Content")
@MainActor
struct NotificationServiceOtherContentTests {
    private let svc = NotificationService.shared

    // MARK: showNoUpdatesFound

    @Test func noUpdatesFoundContent() {
        let (title, body) = svc.noUpdatesFoundContent()
        #expect(title == "Brew Ready")
        #expect(body.contains("current"))
    }

    // MARK: showUpdatesFound

    @Test func updatesFoundContentSinglePackageNoAutoUpgrade() {
        let (title, body) = svc.updatesFoundContent(packages: [makePackage("git")], willAutoUpgrade: false)
        #expect(title == "Updates Available")
        #expect(body.contains("git"))
        #expect(body.contains("1"))
    }

    @Test func updatesFoundContentMultiplePackages() {
        let pkgs = [makePackage("git"), makePackage("node"), makePackage("ffmpeg")]
        let (title, body) = svc.updatesFoundContent(packages: pkgs, willAutoUpgrade: false)
        #expect(title == "Updates Available")
        #expect(body.contains("git"))
        #expect(body.contains("node"))
        #expect(body.contains("ffmpeg"))
        #expect(body.contains("3"))
    }

    @Test func updatesFoundContentWillAutoUpgrade() {
        let (title, body) = svc.updatesFoundContent(packages: [makePackage("git")], willAutoUpgrade: true)
        #expect(title == "Upgrading")
        #expect(body.contains("git"))
    }

    @Test func updatesFoundBodyUsesPackagePlural() {
        let pkgs = [makePackage("git"), makePackage("node")]
        let (_, body) = svc.updatesFoundContent(packages: pkgs, willAutoUpgrade: false)
        #expect(body.contains("package(s)"))
    }

    // MARK: showAuthRequired

    @Test func authRequiredContentFirstTime() {
        let (title, body) = svc.authRequiredContent(packageNames: ["ffmpeg"], isRetry: false)
        #expect(title == "Authorization Required")
        #expect(body.contains("ffmpeg"))
        #expect(body.contains("🔐"))
    }

    @Test func authRequiredContentRetry() {
        let (title, body) = svc.authRequiredContent(packageNames: ["ffmpeg"], isRetry: true)
        #expect(title == "Authentication Failed")
        #expect(body.contains("ffmpeg"))
        #expect(body.contains("❌"))
    }

    @Test func authRequiredContentMultiplePackages() {
        let (_, body) = svc.authRequiredContent(packageNames: ["git", "node"], isRetry: false)
        #expect(body.contains("git"))
        #expect(body.contains("node"))
    }

    // MARK: showAuthTimeout

    @Test func authTimeoutContent() {
        let (title, body) = svc.authTimeoutContent(packageName: "ffmpeg")
        #expect(title == "Authorization Timeout")
        #expect(body.contains("ffmpeg"))
        #expect(body.contains("⏱️"))
    }

    // MARK: showTransientError

    @Test func transientErrorNetworkUnavailable() {
        let (title, body) = svc.transientErrorContent(error: .networkUnavailable, packageName: nil)
        #expect(title == "Network Unavailable")
        #expect(body.contains("⚠️"))
    }

    @Test func transientErrorCommandFailed() {
        let (title, body) = svc.transientErrorContent(error: .commandFailed("build error"), packageName: nil)
        #expect(title == "Command Failed")
        #expect(body.contains("❌"))
    }

    @Test func transientErrorAuthFailedWithPackageName() {
        let (title, body) = svc.transientErrorContent(error: .authenticationFailed, packageName: "git")
        #expect(title == "Authentication Failed")
        #expect(body.contains("git"))
        #expect(body.contains("⚠️"))
    }

    @Test func transientErrorAuthFailedWithoutPackageName() {
        let (title, body) = svc.transientErrorContent(error: .authenticationFailed, packageName: nil)
        #expect(title == "Authentication Failed")
        #expect(body.contains("⚠️"))
    }

    // MARK: showBrewNotFound

    @Test func brewNotFoundContent() {
        let (title, body) = svc.brewNotFoundContent()
        #expect(title == "Homebrew Not Found")
        #expect(body.contains("❌"))
        #expect(body.contains("Homebrew"))
    }
}

// MARK: - Delivery (verifies notifications are actually scheduled)

@Suite("NotificationService Delivery")
@MainActor
struct NotificationServiceDeliveryTests {
    private func capture(
        _ block: (NotificationService) -> Void
    ) -> [UNNotificationRequest] {
        var captured: [UNNotificationRequest] = []
        let svc = NotificationService.shared
        let oldSettings = svc.settings

        // Inject in-memory settings to bypass any local UserDefaults toggles in test host
        let testSettings = AppSettings(store: MockSettingsStore())
        svc.settings = testSettings

        svc.onRequestScheduled = { captured.append($0) }
        block(svc)
        svc.onRequestScheduled = nil
        svc.settings = oldSettings
        return captured
    }

    // MARK: showNoUpdatesFound

    @Test func noUpdatesFoundSchedulesOneRequest() {
        let requests = capture { $0.showNoUpdatesFound() }
        #expect(requests.count == 1)
        #expect(requests[0].identifier == NotificationService.RequestID.noUpdatesFound)
        #expect(requests[0].content.title == "Brew Ready")
    }

    // MARK: showUpdatesFound

    @Test func updatesFoundSchedulesOneRequest() {
        let requests = capture { $0.showUpdatesFound(packages: [makePackage("git")], willAutoUpgrade: false) }
        #expect(requests.count == 1)
        #expect(requests[0].identifier == NotificationService.RequestID.updatesFound)
        #expect(requests[0].content.title == "Updates Available")
        #expect(requests[0].content.body.contains("git"))
    }

    @Test func updatesFoundWillAutoUpgradeHasCorrectTitle() {
        let requests = capture { $0.showUpdatesFound(packages: [makePackage("git")], willAutoUpgrade: true) }
        #expect(requests[0].content.title == "Upgrading")
    }

    // MARK: showUpgradeResult

    @Test func upgradeResultSchedulesOneRequest() {
        let requests = capture {
            $0.showUpgradeResult(
                upgraded: [makePackage("git", old: "1.0", new: "1.1")],
                success: true,
                requestedNames: ["git"]
            )
        }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Brew Updated")
        #expect(requests[0].content.body.contains("git"))
        #expect(requests[0].content.body.contains("1.0"))
        #expect(requests[0].content.body.contains("1.1"))
    }

    @Test func upgradeResultFailedHasCorrectTitle() {
        let requests = capture {
            $0.showUpgradeResult(upgraded: [], success: false, requestedNames: ["git"])
        }
        #expect(requests[0].content.title == "Upgrade Failed")
        #expect(requests[0].content.body.contains("git"))
        #expect(requests[0].content.body.contains("Failed"))
    }

    @Test func upgradeResultPartialHasCorrectTitle() {
        let requests = capture {
            $0.showUpgradeResult(
                upgraded: [makePackage("git", old: "1.0", new: "1.1")],
                success: false,
                requestedNames: ["git", "node"]
            )
        }
        #expect(requests[0].content.title == "Partial Upgrade")
    }

    @Test func upgradeResultExternallyUpgradedShowsAlreadyCurrent() {
        let requests = capture {
            $0.showUpgradeResult(
                upgraded: [],
                success: true,
                requestedNames: ["git"],
                externalSuccessNames: ["git"]
            )
        }
        #expect(requests.count == 1)
        #expect(requests[0].content.body.contains("Already current"))
        #expect(requests[0].content.body.contains("ℹ️"))
    }

    @Test func upgradeResultSkippedShowsSkipped() {
        let requests = capture {
            $0.showUpgradeResult(
                upgraded: [],
                success: true,
                requestedNames: ["zoom"],
                skippedNames: ["zoom"]
            )
        }
        #expect(requests.count == 1)
        #expect(requests[0].content.body.contains("Skipped"))
        #expect(requests[0].content.body.contains("⏭️"))
    }

    @Test func upgradeResultMixedAllFourStatuses() {
        let requests = capture {
            $0.showUpgradeResult(
                upgraded: [makePackage("git", old: "1.0", new: "1.1")],
                success: false,
                requestedNames: ["git", "node", "zoom", "ffmpeg"],
                skippedNames: ["zoom"],
                externalSuccessNames: ["node"],
                failedErrors: ["ffmpeg": "build error"]
            )
        }
        #expect(requests.count == 1)
        let body = requests[0].content.body
        #expect(body.contains("✅"))
        #expect(body.contains("ℹ️"))
        #expect(body.contains("⏭️"))
        #expect(body.contains("❌"))
        #expect(body.contains("git"))
        #expect(body.contains("node"))
        #expect(body.contains("zoom"))
        #expect(body.contains("ffmpeg"))
        #expect(body.contains("build error"))
    }

    @Test func upgradeResultAllCurrentShowsBrewReady() {
        let requests = capture {
            $0.showUpgradeResult(upgraded: [], success: true, requestedNames: [])
        }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Brew Ready")
        #expect(requests[0].content.body.contains("current"))
    }

    // MARK: showAuthRequired

    @Test func authRequiredFirstTimeUsesAuthTriggerID() {
        let requests = capture { $0.showAuthRequired(packageNames: ["ffmpeg"], isRetry: false) }
        #expect(requests.count == 1)
        #expect(requests[0].identifier == NotificationService.RequestID.authTrigger)
        #expect(requests[0].content.title == "Authorization Required")
        #expect(requests[0].content.body.contains("ffmpeg"))
        #expect(requests[0].content.categoryIdentifier == "AUTH_REQUIRED")
    }

    @Test func authRequiredRetryUsesFixedID() {
        let req1 = capture { $0.showAuthRequired(packageNames: ["ffmpeg"], isRetry: true) }
        let req2 = capture { $0.showAuthRequired(packageNames: ["ffmpeg"], isRetry: true) }
        #expect(req1[0].identifier == NotificationService.RequestID.authRetry)
        #expect(req2[0].identifier == NotificationService.RequestID.authRetry)
        #expect(req1[0].identifier == req2[0].identifier, "重试通知 ID 必须固定，覆盖上一条")
    }

    @Test func authRequiredRetryHasAuthFailedTitle() {
        let requests = capture { $0.showAuthRequired(packageNames: ["ffmpeg"], isRetry: true) }
        #expect(requests[0].content.title == "Authentication Failed")
    }

    // MARK: showAuthTimeout

    @Test func authTimeoutSchedulesOneRequest() {
        let requests = capture { $0.showAuthTimeout(packageName: "ffmpeg") }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Authorization Timeout")
        #expect(requests[0].content.body.contains("ffmpeg"))
        #expect(requests[0].content.body.contains("⏱️"))
    }

    // MARK: showTransientError

    @Test func transientErrorNetworkUnavailableSchedules() {
        let requests = capture { $0.showTransientError(error: .networkUnavailable) }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Network Unavailable")
        #expect(requests[0].content.body.contains("⚠️"))
    }

    @Test func transientErrorCommandFailedSchedules() {
        let requests = capture { $0.showTransientError(error: .commandFailed("build error")) }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Command Failed")
        #expect(requests[0].content.body.contains("❌"))
    }

    @Test func transientErrorAuthFailedWithPackageName() {
        let requests = capture { $0.showTransientError(error: .authenticationFailed, packageName: "git") }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Authentication Failed")
        #expect(requests[0].content.body.contains("git"))
    }

    @Test func transientErrorAuthFailedWithoutPackageName() {
        let requests = capture { $0.showTransientError(error: .authenticationFailed, packageName: nil) }
        #expect(requests.count == 1)
        #expect(requests[0].content.title == "Authentication Failed")
        #expect(requests[0].content.body.contains("⚠️"))
        #expect(!requests[0].content.body.isEmpty)
    }

    // MARK: showBrewNotFound

    @Test func brewNotFoundSchedulesOneRequest() {
        let requests = capture { $0.showBrewNotFound() }
        #expect(requests.count == 1)
        #expect(requests[0].identifier == NotificationService.RequestID.brewNotFound)
        #expect(requests[0].content.title == "Homebrew Not Found")
        #expect(requests[0].content.body.contains("❌"))
    }

    // MARK: willAutoUpgradeFlag

    @Test func updatesFoundRecordsWillAutoUpgradeFlag() {
        let notifSvc = MockNotificationService()
        notifSvc.showUpdatesFound(packages: [makePackage()], willAutoUpgrade: false)
        notifSvc.showUpdatesFound(packages: [makePackage()], willAutoUpgrade: true)
        #expect(notifSvc.updatesFoundCalls[0].willAutoUpgrade == false)
        #expect(notifSvc.updatesFoundCalls[1].willAutoUpgrade == true)
    }
}
