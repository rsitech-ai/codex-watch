import CodexWatchCore
import Foundation
import Network

struct DiscoveredBridge: Identifiable, Equatable, Sendable {
    let name: String
    let baseURL: URL
    let certificatePin: CertificatePin

    var id: String {
        "\(name)|\(baseURL.absoluteString)|\(certificatePin.rawValue)"
    }
}

@MainActor
final class BridgeDiscovery: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case ready
        case unavailable
    }

    @Published private(set) var bridges: [DiscoveredBridge] = []
    @Published private(set) var state: State = .idle

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "ai.rsitech.codexwatch.discovery")

    func start() {
        guard browser == nil else { return }
        state = .searching
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_codexwatch._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                guard let self else { return }
                switch browserState {
                case .ready:
                    self.state = .ready
                case .failed, .waiting:
                    self.state = .unavailable
                case .cancelled:
                    self.state = .idle
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parse).sorted { $0.name < $1.name }
            Task { @MainActor in
                self?.bridges = parsed
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        bridges = []
        state = .idle
    }

    private nonisolated static func parse(_ result: NWBrowser.Result) -> DiscoveredBridge? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(record) = result.metadata,
              let host = record["host"],
              let rawPort = record["port"],
              let port = Int(rawPort),
              (1 ... 65_535).contains(port),
              let rawFingerprint = record["public-key-sha256"],
              let pin = try? CertificatePin(rawFingerprint)
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        guard let baseURL = components.url else { return nil }
        return DiscoveredBridge(name: name, baseURL: baseURL, certificatePin: pin)
    }
}
