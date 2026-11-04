import CoreMedia
import CryptoKit
import Foundation
import Network
import Security

/// Streaming callbacks. Always invoked on `PhoneConnection.queue`.
protocol PhoneConnectionDelegate: AnyObject {
    func phoneConnection(_ c: PhoneConnection, videoConfig: VideoConfigPayload)
    func phoneConnection(_ c: PhoneConnection, videoFrame: VideoFramePayload)
    func phoneConnection(_ c: PhoneConnection, audioConfig asc: Data)
    func phoneConnection(_ c: PhoneConnection, audioFrame: AudioFramePayload)
    func phoneConnection(_ c: PhoneConnection, didFail message: String)
}

enum PhoneConnectionError: LocalizedError, Equatable {
    case notReachable, identityChanged, pairingDenied, pairingTimedOut, authFailed, busy
    case versionMismatch(Int)
    case cancelled
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notReachable: return "Phone not reachable."
        case .identityChanged: return "Phone identity changed."
        case .pairingDenied: return "Pairing was denied on the phone."
        case .pairingTimedOut: return "Pairing timed out."
        case .authFailed: return "Phone rejected the pairing token."
        case .busy: return "Phone is in use by another computer."
        case .versionMismatch(let n): return "Update required (protocol v\(n))."
        case .cancelled: return "Cancelled."
        case .network(let m): return m
        }
    }
}

/// Mac-side client for Capture Studio Phone: TLS with certificate pinning
/// (trust-on-first-use confirmed by the pairing code), the control handshake,
/// clock sync, and streaming dispatch to `delegate`.
///
/// `@unchecked Sendable`: every piece of mutable state below is read and written
/// only on `queue` (the NWConnection, its handlers, the TLS verify block, and all
/// timeouts run there; public async methods hop onto it).
final class PhoneConnection: @unchecked Sendable {
    let queue = DispatchQueue(label: "capturestudio.phone.connection")
    weak var delegate: PhoneConnectionDelegate?

    private static let protocolVersion = 1
    private static let controlTimeout: TimeInterval = 10
    private static let pairingTimeout: TimeInterval = 120
    private static let connectTimeout: TimeInterval = 10
    private static let stopGrace: TimeInterval = 1
    /// Streaming liveness: a CLOCK_PING every 2 s after START; no pong in 5 s fails.
    private static let streamPingInterval: TimeInterval = 2
    private static let streamPongTimeout: TimeInterval = 5
    private static let nonceLength = 32
    private static let tokenLength = 32

    private let device: PhoneDevice
    private let pairing: PhonePairing?
    private let macName: String

    // MARK: State (queue-confined)

    private struct PendingConnect {
        let cont: CheckedContinuation<Data, Error>
        let timeout: DispatchWorkItem
    }

    private struct PendingControl {
        let id: UInt64
        let cont: CheckedContinuation<PhoneMessage, Error>
        let accepts: Set<PhoneMessageType>
        let timeout: DispatchWorkItem
    }

    private struct PendingPong {
        let id: UInt64
        let cont: CheckedContinuation<ClockSample, Error>
        let macSendNs: UInt64
        let timeout: DispatchWorkItem
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private var closed = false
    private var presentedFingerprint: Data?
    private var identityRejected = false
    private var phoneProtocolVersion: Int?
    private var nextWaitID: UInt64 = 0
    private var pendingConnect: PendingConnect?
    private var pendingControl: PendingControl?
    private var pendingPong: PendingPong?
    private var streamPingTimer: DispatchSourceTimer?
    /// The one streaming ping in flight (matched on its `macSendHostNs` echo).
    private var streamPingOutstanding: (macSendNs: UInt64, timeout: DispatchWorkItem)?
    /// Offset from the last `syncClock`, for drift logging only.
    private var syncedOffsetNs: Int64?

    init(device: PhoneDevice, pairing: PhonePairing?, macName: String) {
        self.device = device
        self.pairing = pairing
        self.macName = macName
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - Public API

    /// Opens the TLS connection. Returns the presented leaf-certificate fingerprint
    /// (SHA-256 of its DER). When `pairing` exists the fingerprint is pinned and a
    /// mismatch fails with `.identityChanged`.
    func connect() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async { self.beginConnect(cont) }
        }
    }

    /// HELLO/HELLO, then AUTH (paired) or the commit/nonce/reveal pairing flow.
    /// `onCode` fires once the code is known. Returns a new token when pairing happened.
    func authenticate(onCode: @escaping @Sendable (String) -> Void) async throws -> Data? {
        let hello = HelloPayload(pv: Self.protocolVersion, deviceName: macName,
                                 model: "Mac", caps: ["video", "audio"])
        let reply = try await exchange(PhoneMessage(type: .hello, payload: try JSONEncoder().encode(hello)),
                                       expecting: [.hello])
        guard let phoneHello = try? JSONDecoder().decode(HelloPayload.self, from: reply.payload) else {
            throw failAndClose(.network("malformed hello"))
        }
        await setPhoneVersion(phoneHello.pv)
        guard phoneHello.pv == Self.protocolVersion else {
            throw failAndClose(.versionMismatch(phoneHello.pv))
        }

        if let pairing {
            let r = try await exchange(PhoneMessage(type: .auth, payload: pairing.token),
                                       expecting: [.authOK, .authFail])
            guard r.type == .authOK else { throw failAndClose(.authFailed) }
            return nil
        }

        let macNonce = try Self.randomNonce()
        let nonceMsg = try await exchange(
            PhoneMessage(type: .pairCommit, payload: PairingCode.commitment(for: macNonce)),
            expecting: [.pairNonce])
        let phoneNonce = nonceMsg.payload
        guard phoneNonce.count == Self.nonceLength else {
            throw failAndClose(.network("malformed pairNonce"))
        }
        guard let fingerprint = await currentFingerprint() else {
            throw failAndClose(.network("no peer certificate"))
        }
        let code = PairingCode.derive(fingerprint: fingerprint, macNonce: macNonce, phoneNonce: phoneNonce)
        // The phone only answers after PAIR_REVEAL, which `exchange` sends after
        // registering the wait, so announcing the code first cannot miss a reply.
        onCode(code)
        let result = try await exchange(PhoneMessage(type: .pairReveal, payload: macNonce),
                                        expecting: [.pairOK, .pairDenied],
                                        timeout: Self.pairingTimeout, pairing: true)
        guard result.type == .pairOK else { throw failAndClose(.pairingDenied) }
        guard result.payload.count == Self.tokenLength else {
            throw failAndClose(.network("malformed pairOK"))
        }
        return result.payload
    }

    /// `samples` sequential CLOCK_PING/PONG round trips. Offset maps phone BOOTTIME
    /// onto the host clock (the clock behind every recorder's `sessionStartHostTime`).
    func syncClock(samples: Int = 20) async throws -> (offsetNs: Int64, minRTTNs: UInt64) {
        var collected: [ClockSample] = []
        for _ in 0..<max(0, samples) {
            collected.append(try await ping())
        }
        guard let offset = ClockSync.offset(samples: collected),
              let minRTT = collected.map(\.rttNs).min() else {
            throw PhoneConnectionError.network("clock sync failed")
        }
        queue.async { self.syncedOffsetNs = offset }
        return (offset, minRTT)
    }

    /// Sends START (no reply expected); returns once the bytes are handed to the stack.
    func start(_ config: StartConfig) async throws {
        let payload = try JSONEncoder().encode(config)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, self.connection != nil else {
                    cont.resume(throwing: PhoneConnectionError.cancelled)
                    return
                }
                self.send(PhoneMessage(type: .start, payload: payload)) { error in
                    if let error {
                        cont.resume(throwing: PhoneConnectionError.network(error.localizedDescription))
                    } else {
                        self.startStreamPings()
                        cont.resume()
                    }
                }
            }
        }
    }

    func requestKeyframe() {
        queue.async {
            guard !self.closed else { return }
            self.send(PhoneMessage(type: .keyframeReq, payload: Data()))
        }
    }

    /// Sends STOP, waits ≤ 1 s for it to be processed, then closes.
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard !self.closed, self.connection != nil else {
                    self.closeLocked(resuming: .cancelled)
                    cont.resume()
                    return
                }
                self.stopStreamPings() // nothing more after STOP
                let once = OnceFlag()
                let finish = {
                    guard once.claim() else { return }
                    self.closeLocked(resuming: .cancelled)
                    cont.resume()
                }
                self.send(PhoneMessage(type: .stop, payload: Data())) { _ in finish() }
                self.queue.asyncAfter(deadline: .now() + Self.stopGrace) { finish() }
            }
        }
    }

    /// Cancels the connection; every pending wait resumes with `.cancelled`.
    func close() {
        queue.async { self.closeLocked(resuming: .cancelled) }
    }

    // MARK: - Connect (queue)

    private func beginConnect(_ cont: CheckedContinuation<Data, Error>) {
        guard !closed else { cont.resume(throwing: PhoneConnectionError.cancelled); return }
        guard connection == nil, pendingConnect == nil else {
            cont.resume(throwing: PhoneConnectionError.network("already connected"))
            return
        }
        let conn = NWConnection(to: device.endpoint, using: makeParameters())
        connection = conn
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pendingConnect else { return }
            self.pendingConnect = nil
            p.cont.resume(throwing: PhoneConnectionError.notReachable)
            self.closeLocked(resuming: .cancelled)
        }
        pendingConnect = PendingConnect(cont: cont, timeout: timeout)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            self.handleState(state)
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let p = takeConnect() else { return }
            guard let fingerprint = presentedFingerprint else {
                p.cont.resume(throwing: PhoneConnectionError.network("no peer certificate"))
                closeLocked(resuming: .cancelled)
                return
            }
            p.cont.resume(returning: fingerprint)
            if let connection { receiveNext(on: connection) }
        case .failed(let error):
            let err: PhoneConnectionError = identityRejected
                ? .identityChanged : .network(error.localizedDescription)
            fail(err)
        case .cancelled:
            closeLocked(resuming: .cancelled)
        case .waiting(let error):
            // Keep waiting; the connect timeout turns this into `.notReachable`.
            Log.recorder.info("Phone connection waiting: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func takeConnect() -> PendingConnect? {
        guard let p = pendingConnect else { return nil }
        pendingConnect = nil
        p.timeout.cancel()
        return p
    }

    private func makeParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        // The phone's certificate is self-signed and never passes system trust
        // evaluation; this block is the only check, by design: pin the leaf's
        // SHA-256 when paired, otherwise accept it and let the pairing code (which
        // mixes in this fingerprint) authenticate it out of band.
        sec_protocol_options_set_verify_block(sec, { [weak self] _, trust, complete in
            guard let self else { complete(false); return }
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
            if let pinned = self.pairing?.fingerprint, pinned != fingerprint {
                self.identityRejected = true
                Log.recorder.error("Phone certificate fingerprint mismatch; rejecting")
                complete(false)
                return
            }
            self.presentedFingerprint = fingerprint
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        return NWParameters(tls: tls, tcp: tcp)
    }

    // MARK: - Receive (queue)

    private func receiveNext(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                let messages: [PhoneMessage]
                do {
                    messages = try PhoneFraming.decode(&self.buffer)
                } catch {
                    self.fail(.network("Protocol error: \(error)"))
                    return
                }
                for m in messages {
                    self.handle(m)
                    if self.closed { return }
                }
            }
            if let error {
                self.fail(.network(error.localizedDescription))
                return
            }
            if isComplete {
                self.fail(.network("Phone closed the connection."))
                return
            }
            self.receiveNext(on: conn)
        }
    }

    private func handle(_ m: PhoneMessage) {
        switch m.type {
        case .videoConfig:
            guard let p = VideoConfigPayload(m.payload) else { return fail(.network("malformed videoConfig")) }
            delegate?.phoneConnection(self, videoConfig: p)
        case .videoFrame:
            guard let p = VideoFramePayload(m.payload) else { return fail(.network("malformed videoFrame")) }
            delegate?.phoneConnection(self, videoFrame: p)
        case .audioConfig:
            delegate?.phoneConnection(self, audioConfig: m.payload)
        case .audioFrame:
            guard let p = AudioFramePayload(m.payload) else { return fail(.network("malformed audioFrame")) }
            delegate?.phoneConnection(self, audioFrame: p)
        case .clockPong:
            guard let pong = ClockPongPayload(m.payload) else { return fail(.network("malformed clockPong")) }
            if let p = pendingPong, p.macSendNs == pong.macSendHostNs {
                pendingPong = nil
                p.timeout.cancel()
                p.cont.resume(returning: ClockSample(macSendNs: pong.macSendHostNs, phoneRecvNs: pong.phoneRecvNs,
                                                     phoneSendNs: pong.phoneSendNs, macRecvNs: Self.hostNowNs()))
            } else if let s = streamPingOutstanding, s.macSendNs == pong.macSendHostNs {
                streamPingOutstanding = nil
                s.timeout.cancel()
                let sample = ClockSample(macSendNs: pong.macSendHostNs, phoneRecvNs: pong.phoneRecvNs,
                                         phoneSendNs: pong.phoneSendNs, macRecvNs: Self.hostNowNs())
                let drift = syncedOffsetNs.map { sample.offsetNs - $0 } ?? 0
                Log.recorder.debug("phone ping: rtt=\(sample.rttNs) ns drift=\(drift) ns")
            } // else stray
        case .error:
            let payload = try? JSONDecoder().decode(ErrorPayload.self, from: m.payload)
            fail(mapError(payload))
        case .hello, .authOK, .authFail, .pairNonce, .pairOK, .pairDenied:
            guard let p = pendingControl, p.accepts.contains(m.type) else {
                Log.recorder.info("Phone: ignoring unexpected \(String(describing: m.type))")
                return
            }
            pendingControl = nil
            p.timeout.cancel()
            p.cont.resume(returning: m)
        case .auth, .pairCommit, .pairReveal, .clockPing, .start, .keyframeReq, .stop:
            Log.recorder.info("Phone: ignoring Mac-bound \(String(describing: m.type))")
        }
    }

    private func mapError(_ payload: ErrorPayload?) -> PhoneConnectionError {
        guard let payload else { return .network("Phone reported an error.") }
        switch payload.code {
        case "busy": return .busy
        case "version": return .versionMismatch(phoneProtocolVersion ?? 0)
        case "denied": return .pairingDenied
        default: return .network(payload.message)
        }
    }

    // MARK: - Control waits

    /// Registers a wait for one of `expecting`, then sends `message`.
    private func exchange(_ message: PhoneMessage, expecting: Set<PhoneMessageType>,
                          timeout: TimeInterval = PhoneConnection.controlTimeout,
                          pairing: Bool = false) async throws -> PhoneMessage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PhoneMessage, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: PhoneConnectionError.cancelled); return }
                guard !self.closed, self.connection != nil else {
                    cont.resume(throwing: PhoneConnectionError.cancelled)
                    return
                }
                guard self.pendingControl == nil else {
                    cont.resume(throwing: PhoneConnectionError.network("control request already pending"))
                    return
                }
                self.nextWaitID &+= 1
                let id = self.nextWaitID
                let names = expecting.map { String(describing: $0) }.sorted().joined(separator: "/")
                let item = DispatchWorkItem { [weak self] in
                    guard let self, let p = self.pendingControl, p.id == id else { return }
                    self.pendingControl = nil
                    p.cont.resume(throwing: pairing ? PhoneConnectionError.pairingTimedOut
                                                    : PhoneConnectionError.network("timeout waiting for \(names)"))
                    self.closeLocked(resuming: .cancelled)
                }
                self.pendingControl = PendingControl(id: id, cont: cont, accepts: expecting, timeout: item)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: item)
                self.send(message)
            }
        }
    }

    private func ping() async throws -> ClockSample {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ClockSample, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: PhoneConnectionError.cancelled); return }
                guard !self.closed, self.connection != nil else {
                    cont.resume(throwing: PhoneConnectionError.cancelled)
                    return
                }
                guard self.pendingPong == nil else {
                    cont.resume(throwing: PhoneConnectionError.network("clock ping already pending"))
                    return
                }
                self.nextWaitID &+= 1
                let id = self.nextWaitID
                let item = DispatchWorkItem { [weak self] in
                    guard let self, let p = self.pendingPong, p.id == id else { return }
                    self.pendingPong = nil
                    p.cont.resume(throwing: PhoneConnectionError.network("timeout waiting for clockPong"))
                    self.closeLocked(resuming: .cancelled)
                }
                let macSend = Self.hostNowNs()
                self.pendingPong = PendingPong(id: id, cont: cont, macSendNs: macSend, timeout: item)
                self.queue.asyncAfter(deadline: .now() + Self.controlTimeout, execute: item)
                self.send(PhoneMessage(type: .clockPing, payload: Self.bigEndian(macSend)))
            }
        }
    }

    /// Queue. Liveness pings while streaming; never overlaps `syncClock` (starts after START).
    private func startStreamPings() {
        guard !closed, streamPingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.streamPingInterval, repeating: Self.streamPingInterval)
        timer.setEventHandler { [weak self] in self?.sendStreamPing() }
        streamPingTimer = timer
        timer.resume()
    }

    private func stopStreamPings() {
        streamPingTimer?.cancel()
        streamPingTimer = nil
        streamPingOutstanding?.timeout.cancel()
        streamPingOutstanding = nil
    }

    /// Queue. One ping in flight at a time; its own 5 s timeout fails the connection.
    private func sendStreamPing() {
        guard !closed, connection != nil, streamPingOutstanding == nil else { return }
        let macSend = Self.hostNowNs()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let s = self.streamPingOutstanding, s.macSendNs == macSend else { return }
            self.streamPingOutstanding = nil
            self.fail(.network("Phone stopped responding."))
        }
        streamPingOutstanding = (macSend, item)
        queue.asyncAfter(deadline: .now() + Self.streamPongTimeout, execute: item)
        send(PhoneMessage(type: .clockPing, payload: Self.bigEndian(macSend)))
    }

    private func setPhoneVersion(_ pv: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { self.phoneProtocolVersion = pv; cont.resume() }
        }
    }

    private func currentFingerprint() async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async { cont.resume(returning: self.presentedFingerprint) }
        }
    }

    /// Protocol violation detected by an async method: close and hand back the error.
    private func failAndClose(_ error: PhoneConnectionError) -> PhoneConnectionError {
        close()
        return error
    }

    // MARK: - Send / teardown (queue)

    /// `completion` nil → a send error fails the connection.
    private func send(_ message: PhoneMessage, completion: ((NWError?) -> Void)? = nil) {
        guard let connection, !closed else {
            completion?(NWError.posix(.ENOTCONN))
            return
        }
        connection.send(content: PhoneFraming.encode(message), completion: .contentProcessed { [weak self] error in
            if let completion {
                completion(error)
            } else if let error, let self {
                self.fail(.network(error.localizedDescription))
            }
        })
    }

    /// Resumes whatever is pending with `error`; with nothing pending (streaming)
    /// reports it once via `didFail`. Then closes.
    private func fail(_ error: PhoneConnectionError) {
        guard !closed else { return }
        let hadPending = pendingConnect != nil || pendingControl != nil || pendingPong != nil
        if !hadPending {
            Log.recorder.error("Phone connection failed: \(error.localizedDescription)")
            delegate?.phoneConnection(self, didFail: error.localizedDescription)
        }
        closeLocked(resuming: error)
    }

    /// Idempotent. Each pending continuation is taken (nil'd) before it is resumed.
    private func closeLocked(resuming error: PhoneConnectionError) {
        closed = true
        stopStreamPings()
        if let p = takeConnect() { p.cont.resume(throwing: error) }
        if let p = pendingControl {
            pendingControl = nil
            p.timeout.cancel()
            p.cont.resume(throwing: error)
        }
        if let p = pendingPong {
            pendingPong = nil
            p.timeout.cancel()
            p.cont.resume(throwing: error)
        }
        buffer.removeAll()
        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
    }

    // MARK: - Helpers

    private static func hostNowNs() -> UInt64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(clamping: CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default).value)
    }

    private static func bigEndian(_ v: UInt64) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    private static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PhoneConnectionError.network("Could not generate a pairing nonce.")
        }
        return Data(bytes)
    }
}

/// Single-shot latch; only touched on `PhoneConnection.queue`.
private final class OnceFlag: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
