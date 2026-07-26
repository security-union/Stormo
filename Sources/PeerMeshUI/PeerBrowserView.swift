#if canImport(SwiftUI)
import PeerMesh
import SwiftUI

/// SwiftUI replacement for `MCBrowserViewController` (FR-23): lists discovered
/// peers and lets the user invite them. Fully restyleable; built solely on
/// public PeerMesh APIs.
public struct PeerBrowserView: View {
    private let session: PeerSession
    @State private var peers: [DiscoveredPeer] = []

    public init(session: PeerSession) {
        self.session = session
    }

    public var body: some View {
        // TODO(Phase 2): live list driven by session.discoveries, invite
        // action with progress/error states, empty-state and permission-denied
        // (FR-4) presentations.
        List(peers, id: \.id) { peer in
            Text(peer.id.displayName)
        }
        .task {
            for await event in session.discoveries {
                switch event {
                case .found(let peer), .updated(let peer):
                    peers.removeAll { $0.id == peer.id }
                    peers.append(peer)
                case .lost(let id):
                    peers.removeAll { $0.id == id }
                }
            }
        }
    }
}

/// SwiftUI replacement for `MCAdvertiserAssistant`'s consent UI (FR-23): a
/// sheet presenting an incoming invitation for the user to accept or decline —
/// the authorization step of `.automatic` trust (FR-21, DD-2).
public struct InvitationConsentSheet: View {
    private let invitation: Invitation

    public init(invitation: Invitation) {
        self.invitation = invitation
    }

    public var body: some View {
        // TODO(Phase 2): full consent UI (inviter name, key-continuity badge,
        // context preview hook).
        VStack(spacing: 16) {
            Text("“\(invitation.from.displayName)” wants to connect")
                .font(.headline)
            HStack {
                Button("Decline") { Task { await invitation.decline() } }
                Button("Accept") { Task { await invitation.accept() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
#endif
