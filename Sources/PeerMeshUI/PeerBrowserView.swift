#if canImport(SwiftUI)
import Stromo
import SwiftUI

/// SwiftUI replacement for `MCBrowserViewController` (FR-23): lists discovered
/// peers and lets the user invite them. Fully restyleable; built solely on
/// public Stromo APIs.
///
/// - Warning: Experimental preview — the API is unstable and this view is a
///   minimal skeleton. TODO(ui-completion): invite action with progress/error
///   states, empty-state, and permission-denied (FR-4) presentation.
public struct PeerBrowserView: View {
    private let session: PeerSession
    @State private var peers: [DiscoveredPeer] = []

    public init(session: PeerSession) {
        self.session = session
    }

    public var body: some View {
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
///
/// - Warning: Experimental preview — the API is unstable and this view is a
///   minimal skeleton. TODO(ui-completion): inviter name, key-continuity badge,
///   and context-preview hook.
public struct InvitationConsentSheet: View {
    private let invitation: Invitation

    public init(invitation: Invitation) {
        self.invitation = invitation
    }

    public var body: some View {
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
