import Network
import Observation

@Observable
final class NetworkMonitor: NetworkConnectivityProvider {
    private(set) var isConnected: Bool = true
    /// True when using a cellular or personal hotspot interface.
    private(set) var isExpensive: Bool = false
    /// True when the user has enabled Low Data Mode.
    private(set) var isConstrained: Bool = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected  = path.status == .satisfied
                self?.isExpensive  = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
