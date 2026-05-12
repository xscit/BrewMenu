/// Configuration interface consumed by business engines (decouples config source).
protocol BrewConfiguration: Sendable {
    var greedyMode: GreedyMode { get }
    var cleanupMode: CleanupMode { get }
    var authTimeout: Int { get }
}
