import Foundation
import Network
import dnssd

/// Discovers Capture Studio Phone instances on the local network via Bonjour.
@MainActor
final class PhoneBrowser: ObservableObject {
    static let shared = PhoneBrowser()
    static let serviceType = "_capturestudio._tcp"

    @Published private(set) var phones: [PhoneDevice] = []
    @Published private(set) var isBrowsing = false
    /// Sticky across stop/start: set when the OS reports a Local Network policy denial.
    @Published private(set) var localNetworkDenied = false
    /// Sticky: a phone has been discovered at least once, so Local Network is allowed.
    @Published private(set) var hasSeenPhone = false

    /// kDNSServiceErr_PolicyDenied — Local Network permission refused.
    nonisolated static let policyDeniedCode: DNSServiceErrorType = -65570

    nonisolated static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDeniedCode }
        return false
    }

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                          using: .tcp)
        b.stateUpdateHandler = { [weak self, weak b] state in
            Task { @MainActor [weak self, weak b] in
                guard let self, let b, self.browser === b else { return }
                switch state {
                case .waiting(let error):
                    Log.recorder.error("Phone browser waiting: \(error.localizedDescription)")
                    if Self.isLocalNetworkDenied(error) { self.localNetworkDenied = true }
                case .ready:
                    self.isBrowsing = true
                    self.localNetworkDenied = false
                case .failed(let error):
                    Log.recorder.error("Phone browser failed: \(error.localizedDescription)")
                    if Self.isLocalNetworkDenied(error) { self.localNetworkDenied = true }
                    self.reset()
                case .cancelled:
                    self.reset()
                default:
                    break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            Task { @MainActor [weak self, weak b] in
                guard let self, let b, self.browser === b else { return }
                self.phones = Self.devices(from: results)
                if !self.phones.isEmpty {
                    self.hasSeenPhone = true
                    self.localNetworkDenied = false
                }
            }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        let b = browser
        reset()
        b?.cancel()
    }

    func device(id: String) -> PhoneDevice? {
        phones.first { $0.id == id }
    }

    /// Starts if needed and waits ≤ timeout for the id (hotkey path).
    func waitForDevice(id: String, timeout: Duration) async -> PhoneDevice? {
        if let d = device(id: id) { return d }
        start()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let d = device(id: id) { return d }
        }
        return device(id: id)
    }

    private func reset() {
        browser = nil
        phones = []
        isBrowsing = false
    }

    private static func devices(from results: Set<NWBrowser.Result>) -> [PhoneDevice] {
        var seen = Set<String>()
        var out: [PhoneDevice] = []
        let list = results.compactMap { r -> PhoneDevice? in
            guard case .bonjour(let txt) = r.metadata,
                  let id = txt.dictionary["id"], !id.isEmpty else { return nil }
            var name = txt.dictionary["name"] ?? "Phone"
            if txt.dictionary["name"] == nil, case .service(let n, _, _, _) = r.endpoint {
                name = n
            }
            let pv = txt.dictionary["pv"].flatMap { Int($0) } ?? 1
            return PhoneDevice(id: id, name: name, protocolMajor: pv, endpoint: r.endpoint)
        }
        for d in list.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) where seen.insert(d.id).inserted {
            out.append(d)
        }
        return out
    }
}
