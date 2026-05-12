import Foundation
import os

/// Authorization service: manages the privilege-escalation helper and SUDO_ASKPASS environment.
struct AuthorizationService: Sendable {

    private let bundle: Bundle

    static let shared = AuthorizationService(bundle: .main)

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Verify the AskPass helper is available and return its URL.
    func ensureAskPassHelper() async -> URL? {
        if let helperURL = bundle.url(forAuxiliaryExecutable: "BrewMenuAskPass") {
            return helperURL
        }

        Log.auth.error("BrewMenuAskPass NOT found in bundle for auxiliary executable: \(self.bundle.bundlePath)")
        return nil
    }

    /// Build the environment variables required for sudo privilege escalation (SUDO_ASKPASS).
    func getAuthorizationEnvironment(askPassURL: URL, packages: [String], authTimeout: Int) -> [String: String] {
        var env: [String: String] = [:]

        env["SUDO_ASKPASS"] = askPassURL.path
        env["DISPLAY"] = ":0" // sudo requires a valid DISPLAY to invoke the askpass program

        if !packages.isEmpty {
            let names = packages.joined(separator: ", ")
            env["BREW_MENU_PACKAGE_INFO"] = names
        }

        return env
    }
}
