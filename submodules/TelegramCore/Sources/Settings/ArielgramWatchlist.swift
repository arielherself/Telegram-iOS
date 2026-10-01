import Foundation
import Postbox
import SwiftSignalKit

/// Account-local bookmarks. No chat-list inclusion, read counters, or network
/// subscriptions are created for these peers. Profiles remain in the peer table.
public struct ArielgramWatchlist: Codable, Equatable {
    public let peerIds: [Int64]

    public init(peerIds: [Int64] = []) {
        var seen = Set<Int64>()
        self.peerIds = peerIds.filter { id in
            PeerId(id).namespace == Namespaces.Peer.CloudChannel && seen.insert(id).inserted
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.init(peerIds: try container.decodeIfPresent([Int64].self, forKey: "peers") ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.peerIds, forKey: "peers")
    }

    public func contains(_ peerId: PeerId) -> Bool {
        return self.peerIds.contains(peerId.toInt64())
    }

    public func withUpdatedPeer(_ peerId: PeerId, watched: Bool) -> ArielgramWatchlist {
        var ids = self.peerIds
        if watched {
            if !ids.contains(peerId.toInt64()) { ids.append(peerId.toInt64()) }
        } else {
            ids.removeAll(where: { $0 == peerId.toInt64() })
        }
        return ArielgramWatchlist(peerIds: ids)
    }
}

public func arielgramCanWatchPeer(_ peer: Peer) -> Bool {
    guard let channel = peer as? TelegramChannel, case .left = channel.participationStatus else { return false }
    return !(channel.username ?? "").isEmpty || channel.usernames.contains(where: { $0.isActive && !$0.username.isEmpty })
}

public func arielgramWatchlist(account: Account) -> Signal<ArielgramWatchlist, NoError> {
    return account.postbox.preferencesView(keys: [PreferencesKeys.arielgramWatchlist])
    |> map { view in
        return view.values[PreferencesKeys.arielgramWatchlist]?.get(ArielgramWatchlist.self) ?? ArielgramWatchlist()
    }
    |> distinctUntilChanged
}

public func arielgramSetPeerWatched(account: Account, peerId: PeerId, watched: Bool) -> Signal<Bool, NoError> {
    return account.postbox.transaction { transaction -> Bool in
        // Removing a bookmark is always allowed, including after a peer becomes
        // private, inaccessible, or joined. Adding never performs a join.
        if watched {
            guard let peer = transaction.getPeer(peerId), arielgramCanWatchPeer(peer) else { return false }
        }
        transaction.updatePreferencesEntry(key: PreferencesKeys.arielgramWatchlist, { entry in
            let current = entry?.get(ArielgramWatchlist.self) ?? ArielgramWatchlist()
            return PreferencesEntry(current.withUpdatedPeer(peerId, watched: watched))
        })
        return true
    }
}

public func arielgramWatchlistPeers(account: Account) -> Signal<[EnginePeer], NoError> {
    return arielgramWatchlist(account: account)
    |> mapToSignal { state -> Signal<[EnginePeer], NoError> in
        let ids = state.peerIds.map(PeerId.init)
        if ids.isEmpty { return .single([]) }
        return account.postbox.combinedView(keys: ids.map { .basicPeer($0) })
        |> map { view in
            return ids.compactMap { id in
                return (view.views[.basicPeer(id)] as? BasicPeerView)?.peer.map(EnginePeer.init)
            }
        }
    }
}
