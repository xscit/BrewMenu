/// Homebrew outdated JSON response structure.
struct BrewOutdatedResponse: Codable {
    let formulae: [BrewItem]?
    let casks: [BrewItem]?
}

/// A single package entry in the Homebrew JSON response.
struct BrewItem: Codable {
    let name: String
    let installedVersions: [String]?
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

/// Business-layer package model.
struct BrewPackage: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let oldVersion: String
    let newVersion: String
}
