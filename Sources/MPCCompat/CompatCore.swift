import Foundation
import PeerMesh

/// The shared runtime backing an `MPCCompat` device.
///
/// MultipeerConnectivity splits one logical peer across three objects — an
/// `MCSession`, an `MCNearbyServiceAdvertiser`, and an `MCNearbyServiceBrowser`
/// — that an app constructs with the *same* `MCPeerID` and expects to cooperate.
/// PeerMesh unifies discovery, advertising, invitation, membership, and
/// messaging into a single ``PeerSession`` actor. `CompatCore` is the bridge:
/// exactly one instance exists per `(PeerID, serviceType)` pair (see
/// ``CompatRegistry``), owns the underlying `PeerSession`, runs long-lived pump
/// tasks that translate the session's `AsyncSequence` events into MC-style
/// delegate callbacks, and routes MC-style actions back onto the session.
///
/// ### Concurrency discipline
/// All delegate callbacks are dispatched on ``delegateQueue`` — a single serial
/// queue, matching `MCSession`'s documented "callbacks arrive on one queue"
/// behavior. Internal mutable state (`_session`, `pumpTasks`, `discovered`) is
/// guarded by ``lock``. The delegate-target back-references
/// (``boundSession`` / ``advertiser`` / ``browser``) are `weak` — the app owns
/// those objects, the core only borrows them for dispatch — and are written
/// under ``lock``. Hence `@unchecked Sendable`.
///
/// ### Fresh-session-after-disconnect
/// `MCSession` is (in practice) reusable after `disconnect()`; remote-shutter
/// relies on this via `rebuildSessionIfIdle`. ``teardown()`` cancels the pumps
/// and disconnects the `PeerSession`; the next action lazily rebuilds a fresh
/// `PeerSession` under the *same* identity via ``liveSession()``.
final class CompatCore: @unchecked Sendable {

    /// The app-facing `PeerID` this core was keyed on (registry identity).
    let peer: PeerID
    /// The Bonjour service type resolved from the advertiser/browser.
    let serviceType: String

    /// Serial queue for all delegate dispatch (MCSession semantics).
    let delegateQueue: DispatchQueue

    private let identity: PeerIdentity
    private let transport: (any PeerTransport)?

    private let lock = NSLock()
    private var _session: PeerSession?
    private var pumpTasks: [Task<Void, Never>] = []
    /// Discovered peers, retained so `invitePeer(_ peerID:)` can recover the
    /// `DiscoveredPeer` endpoint `PeerSession.invite(_:)` requires.
    private var discovered: [PeerID: DiscoveredPeer] = [:]

    // Delegate targets (weak — owned by the app). Written under `lock`.
    weak var boundSession: MultipeerSession?
    weak var advertiser: NearbyServiceAdvertiser?
    weak var browser: NearbyServiceBrowser?

    init(peer: PeerID, serviceType: String, transport: (any PeerTransport)?) {
        self.peer = peer
        self.serviceType = serviceType
        self.transport = transport
        // We only hold the app's PeerID (public-key hash + display name), never
        // its private key, so we derive a fresh key-derived identity for the
        // underlying session. Remote peer IDs surfaced to delegates therefore
        // carry the PeerMesh identity's key hash (stable per device/session),
        // not a hash the app could precompute — see MultipeerSession docs.
        self.identity = PeerIdentity(name: peer.displayName)
        self.delegateQueue = DispatchQueue(label: "mpccompat.core.\(serviceType)")
    }

    // MARK: Session lifecycle

    /// The live `PeerSession`, building it (and starting the pumps) on first use
    /// or after a ``teardown()``.
    func liveSession() -> PeerSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = _session { return session }
        let session = PeerSession(
            identity: identity,
            service: ServiceDescriptor(type: serviceType),
            transport: transport)
        _session = session
        startPumps(on: session)  // lock held; startPumps must not re-enter
        return session
    }

    /// The current session without building one — `nil` after ``teardown()``.
    private func currentSession() -> PeerSession? {
        lock.lock()
        defer { lock.unlock() }
        return _session
    }

    /// Tear down the `PeerSession` and stop the pumps; a subsequent action
    /// rebuilds a fresh session under the same identity (MCSession reuse).
    func teardown() {
        lock.lock()
        let session = _session
        let tasks = pumpTasks
        _session = nil
        pumpTasks = []
        lock.unlock()
        for task in tasks { task.cancel() }
        if let session {
            // Async by nature (PeerSession is an actor); `.leave` closes open
            // connections so the survivor observes `.notConnected`.
            Task { await session.disconnect() }
        }
    }

    // MARK: Pumps (PeerSession event streams -> MC delegate callbacks)

    /// - Important: called with ``lock`` already held (from ``liveSession()``).
    private func startPumps(on session: PeerSession) {
        pumpTasks.append(Task { [weak self] in
            for await event in session.membership { self?.handleMembership(event) }
        })
        pumpTasks.append(Task { [weak self] in
            for await message in session.messages { self?.handleMessage(message) }
        })
        pumpTasks.append(Task { [weak self] in
            for await invitation in session.invitations { self?.handleInvitation(invitation) }
        })
        pumpTasks.append(Task { [weak self] in
            for await event in session.discoveries { self?.handleDiscovery(event) }
        })
        pumpTasks.append(Task { [weak self] in
            for await event in session.resources { self?.handleResource(event) }
        })
    }

    private func handleResource(_ event: ResourceEvent) {
        delegateQueue.async { [weak self] in
            guard let self, let session = self.boundSession else { return }
            switch event {
            case .started(let name, let from, let progress):
                session.delegate?.session(
                    session, didStartReceivingResourceWithName: name,
                    fromPeer: from, with: progress)
            case .finished(let name, let from, let url):
                session.delegate?.session(
                    session, didFinishReceivingResourceWithName: name,
                    fromPeer: from, at: url, withError: nil)
            case .failed(let name, let from, let error):
                session.delegate?.session(
                    session, didFinishReceivingResourceWithName: name,
                    fromPeer: from, at: nil, withError: error)
            }
        }
    }

    private func handleMembership(_ event: MembershipEvent) {
        switch event {
        case .joined(let member):
            emitState(peer: member.id, state: .connected)
        case .left(let id), .unreachable(let id):
            emitState(peer: id, state: .notConnected)
        case .identityChanged:
            // TOFU continuity warning (FR-21) has no MCSession analog; ignore.
            break
        }
    }

    private func handleMessage(_ message: InboundMessage) {
        delegateQueue.async { [weak self] in
            guard let self, let session = self.boundSession else { return }
            session.delegate?.session(session, didReceive: message.payload, fromPeer: message.sender)
        }
    }

    private func handleInvitation(_ invitation: Invitation) {
        delegateQueue.async { [weak self] in
            guard let self, let advertiser = self.advertiser else { return }
            let handler: @Sendable (Bool, MultipeerSession?) -> Void = { accept, session in
                if accept {
                    // invitationHandler(true, session): the accepting session is
                    // adopted as this core's delegate target, then we accept.
                    session?.bind(to: self)
                    Task { await invitation.accept() }
                } else {
                    Task { await invitation.decline() }
                }
            }
            advertiser.delegate?.advertiser(
                advertiser,
                didReceiveInvitationFromPeer: invitation.from,
                withContext: invitation.context,
                invitationHandler: handler)
        }
    }

    private func handleDiscovery(_ event: DiscoveryEvent) {
        // Record the endpoint before notifying, so a delegate that immediately
        // calls invitePeer(_:) finds it.
        lock.lock()
        switch event {
        case .found(let peer), .updated(let peer): discovered[peer.id] = peer
        case .lost(let id): discovered.removeValue(forKey: id)
        }
        lock.unlock()

        delegateQueue.async { [weak self] in
            guard let self, let browser = self.browser else { return }
            switch event {
            case .found(let peer), .updated(let peer):
                let info = peer.metadata.isEmpty ? nil : peer.metadata
                browser.delegate?.browser(browser, foundPeer: peer.id, withDiscoveryInfo: info)
            case .lost(let id):
                browser.delegate?.browser(browser, lostPeer: id)
            }
        }
    }

    // MARK: Actions (MC API -> PeerSession)

    func startAdvertising(metadata: [String: String]) {
        let session = liveSession()
        Task { [weak self] in
            do {
                try await session.startAdvertising(metadata: metadata)
            } catch {
                self?.reportAdvertiserError(error)
            }
        }
    }

    func stopAdvertising() {
        guard let session = currentSession() else { return }
        Task { await session.stopAdvertising() }
    }

    func startBrowsing() {
        let session = liveSession()
        Task { [weak self] in
            do {
                try await session.startBrowsing()
            } catch {
                self?.reportBrowserError(error)
            }
        }
    }

    func stopBrowsing() {
        guard let session = currentSession() else { return }
        Task { await session.stopBrowsing() }
    }

    func invite(peerID: PeerID, context: Data?, timeout: TimeInterval) {
        let session = liveSession()
        lock.lock()
        let target = discovered[peerID]
        lock.unlock()
        guard let target else {
            // Never discovered -> unreachable, surfaced MCSession-style.
            emitState(peer: peerID, state: .notConnected)
            return
        }
        // MCSession surfaces invite progress via session state: .connecting on
        // start, .connected on success (via the membership pump), .notConnected
        // on decline/timeout/failure. This matches remote-shutter's delegate.
        emitState(peer: peerID, state: .connecting)
        Task { [weak self] in
            do {
                _ = try await session.invite(target, context: context, timeout: timeout)
                // Success -> membership pump emits peerJoined -> .connected.
            } catch {
                self?.emitState(peer: peerID, state: .notConnected)
            }
        }
    }

    /// Synchronous enqueue (MCSession's `send` is synchronous). Delivery errors
    /// surface on the delegate path rather than as a throw here.
    func send(_ data: Data, to peerIDs: [PeerID], delivery: Delivery) {
        guard let session = currentSession() else { return }
        let recipients: Recipients = peerIDs.isEmpty ? .all : .peers(peerIDs)
        Task { try? await session.send(data, to: recipients, delivery: delivery) }
    }

    /// `MCSession.sendResource` bridge: synchronously returns a proxy `Progress`
    /// that adopts the transfer's real progress once the async send starts.
    /// Completion fires when the sender finishes streaming (or on error/cancel);
    /// note MCSession fired it on *recipient* receipt — semantic delta documented
    /// in `MultipeerSession`.
    func sendResource(
        at url: URL,
        name: String,
        to peerID: PeerID,
        completion: (@Sendable (Error?) -> Void)?
    ) -> Progress {
        let proxy = Progress(totalUnitCount: 1)
        proxy.isCancellable = true
        let session = liveSession()
        Task { [weak self] in
            do {
                let transfer = try await session.sendResource(at: url, to: peerID, name: name)
                proxy.addChild(transfer.progress, withPendingUnitCount: 1)
                self?.watchForCompletion(transfer.progress, completion: completion)
            } catch {
                proxy.cancel()
                self?.delegateQueue.async { completion?(error) }
            }
        }
        return proxy
    }

    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    private func watchForCompletion(
        _ progress: Progress, completion: (@Sendable (Error?) -> Void)?
    ) {
        guard let completion else { return }
        let token = UUID()
        let observation = progress.observe(\.fractionCompleted, options: [.new, .initial]) {
            [weak self] progress, _ in
            guard progress.isFinished || progress.isCancelled else { return }
            self?.delegateQueue.async {
                completion(progress.isCancelled ? CocoaError(.userCancelled) : nil)
            }
            self?.lock.lock()
            self?.progressObservations.removeValue(forKey: token)
            self?.lock.unlock()
        }
        lock.lock()
        progressObservations[token] = observation
        lock.unlock()
    }

    // MARK: Delegate dispatch helpers

    private func emitState(peer: PeerID, state: MultipeerSession.PeerState) {
        delegateQueue.async { [weak self] in
            guard let self, let session = self.boundSession else { return }
            switch state {
            case .connected: session.setConnected(peer: peer, connected: true)
            case .notConnected: session.setConnected(peer: peer, connected: false)
            case .connecting: break
            }
            session.delegate?.session(session, peer: peer, didChange: state)
        }
    }

    private func reportAdvertiserError(_ error: Error) {
        delegateQueue.async { [weak self] in
            guard let self, let advertiser = self.advertiser else { return }
            advertiser.delegate?.advertiser(advertiser, didNotStartAdvertisingPeer: error)
        }
    }

    private func reportBrowserError(_ error: Error) {
        delegateQueue.async { [weak self] in
            guard let self, let browser = self.browser else { return }
            browser.delegate?.browser(browser, didNotStartBrowsingForPeers: error)
        }
    }

    // MARK: Delegate-target attachment (written under `lock`)

    func attachSession(_ session: MultipeerSession) {
        lock.lock(); boundSession = session; lock.unlock()
    }

    func attachAdvertiser(_ advertiser: NearbyServiceAdvertiser) {
        lock.lock(); self.advertiser = advertiser; lock.unlock()
    }

    func attachBrowser(_ browser: NearbyServiceBrowser) {
        lock.lock(); self.browser = browser; lock.unlock()
    }
}

/// Process-wide map of `(PeerID, serviceType)` -> ``CompatCore``.
///
/// MultipeerConnectivity apps construct an `MCSession`, advertiser, and browser
/// with the same `MCPeerID`; the registry is how those independently-created
/// `MPCCompat` objects find the *one* shared ``CompatCore`` (and thus one
/// `PeerSession`). Cores are held weakly: the app's advertiser/browser/session
/// hold the strong references, so a core lives exactly as long as some compat
/// object uses it, then is reclaimed.
final class CompatRegistry: @unchecked Sendable {
    static let shared = CompatRegistry()

    struct Key: Hashable {
        let peer: PeerID
        let serviceType: String
    }

    private final class WeakBox {
        weak var core: CompatCore?
        init(_ core: CompatCore) { self.core = core }
    }

    private let lock = NSLock()
    private var cores: [Key: WeakBox] = [:]

    /// The shared core for `(peer, serviceType)`, creating it on first request.
    /// The `transport` of the *creating* caller wins; later callers for the same
    /// key reuse the existing core (and its transport) regardless.
    func core(
        peer: PeerID,
        serviceType: String,
        transport: (any PeerTransport)?
    ) -> CompatCore {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(peer: peer, serviceType: serviceType)
        if let existing = cores[key]?.core { return existing }
        let core = CompatCore(peer: peer, serviceType: serviceType, transport: transport)
        cores[key] = WeakBox(core)
        return core
    }
}
