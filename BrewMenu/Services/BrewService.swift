import Foundation
import os

// MARK: - Protocol

protocol BrewServiceProtocol: Sendable {
    func getOutdatedPackages(shouldUpdate: Bool, greedyArgs: [String]) async -> Result<[BrewPackage], BrewError>
    func checkIfPackageIsStillOutdated(name: String, greedyArgs: [String]) async -> Bool
    func upgrade(packages: [BrewPackage], greedyArgs: [String], authTimeout: Int, onPID: (@Sendable (Int32) -> Void)?) async -> Result<Bool, BrewError>
    func terminateAll()
    func cleanup(mode: CleanupMode) async -> Bool
}

/// Core Homebrew service: outdated checks, upgrade execution, and JSON parsing.
struct BrewService: BrewServiceProtocol {
    private let runner: BrewCommandRunner
    private let authService: AuthorizationService
    private let brewURL: URL?

    static let shared = BrewService(
        runner: RealBrewCommandRunner(),
        authService: .shared,
        brewURL: findBrewURL()
    )

    init(runner: BrewCommandRunner, authService: AuthorizationService, brewURL: URL?) {
        self.runner = runner
        self.authService = authService
        self.brewURL = brewURL
    }

    // MARK: - Business Logic

    /// Fetch all outdated packages.
    func getOutdatedPackages(shouldUpdate: Bool = true, greedyArgs: [String] = []) async -> Result<[BrewPackage], BrewError> {
        guard let url = brewURL else { return .failure(.brewNotFound) }

        if shouldUpdate {
            let updateCmd = BrewCommand(executable: url, args: ["update"])
            let (updateOut, updateErr, updateExitCode) = await runner.execute(updateCmd)
            if updateExitCode != 0 {
                if let error = BrewError.parse(stdout: updateOut, stderr: updateErr, exitCode: updateExitCode) {
                    return .failure(error)
                }
            }
        }

        let cmd = BrewCommand(executable: url, args: ["outdated", "--json"] + greedyArgs)
        let (out, err, exitCode) = await runner.execute(cmd)

        if let error = BrewError.parse(stdout: out, stderr: err, exitCode: exitCode) {
            return .failure(error)
        }

        return .success(BrewService.parseOutdatedJSON(out))
    }

    /// Execute an upgrade task.
    func upgrade(packages: [BrewPackage], greedyArgs: [String] = [], authTimeout: Int = 300, onPID: (@Sendable (Int32) -> Void)? = nil) async -> Result<Bool, BrewError> {
        guard let url = brewURL else { return .failure(.brewNotFound) }
        if packages.isEmpty { return .success(true) }

        let packageNames = packages.map { $0.name }

        guard let helperURL = await authService.ensureAskPassHelper() else {
            return .failure(.commandFailed("Authorization helper is missing"))
        }

        let authEnv = authService.getAuthorizationEnvironment(
            askPassURL: helperURL, packages: packageNames, authTimeout: authTimeout
        )

        let cmd = BrewCommand(
            executable: url,
            args: ["upgrade"] + greedyArgs,
            packages: packageNames,
            additionalEnvironment: authEnv,
            onPID: onPID
        )

        let (out, err, exitCode) = await runner.execute(cmd)

        if let error = BrewError.parse(stdout: out, stderr: err, exitCode: exitCode) {
            return .failure(error)
        }

        return .success(exitCode == 0)
    }

    /// Pre-check: verify a single package is still outdated (guards against external upgrades).
    func checkIfPackageIsStillOutdated(name: String, greedyArgs: [String] = []) async -> Bool {
        guard let url = brewURL else { return true }

        let cmd = BrewCommand(
            executable: url,
            args: ["outdated", "--json"] + greedyArgs,
            packages: [name]
        )
        let (out, _, exitCode) = await runner.execute(cmd)

        if exitCode == 0 { return false }

        let packages = BrewService.parseOutdatedJSON(out)
        if !packages.isEmpty {
            return packages.contains { $0.name == name }
        }

        // Fallback: when ambiguous, attempt the upgrade rather than skip
        return true
    }

    /// Terminate all active brew processes spawned by this app.
    func terminateAll() {
        runner.terminateAll()
    }

    /// Execute cleanup task.
    func cleanup(mode: CleanupMode) async -> Bool {
        guard let url = brewURL else { return false }
        let cmd = BrewCommand(executable: url, args: ["cleanup"] + mode.args)
        let (_, err, exitCode) = await runner.execute(cmd)
        if exitCode != 0 {
            Log.brew.warning("Cleanup failed (exit \(exitCode)): \(err)")
        }
        return exitCode == 0
    }

    // MARK: - JSON Parsing

    static func parseOutdatedJSON(_ json: String) -> [BrewPackage] {
        guard let response = try? JSONDecoder().decode(BrewOutdatedResponse.self, from: Data(json.utf8)) else {
            return []
        }

        return ((response.formulae ?? []) + (response.casks ?? [])).map { item in
            BrewPackage(
                name: item.name,
                oldVersion: item.installedVersions?.first ?? "unknown",
                newVersion: item.currentVersion
            )
        }
    }

    // MARK: - Private

    private static func findBrewURL() -> URL? {
        let standardPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in standardPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
