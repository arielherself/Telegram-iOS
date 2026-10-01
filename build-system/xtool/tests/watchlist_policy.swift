import Foundation

func channelId(_ value: Int64) -> PeerId { PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(value)) }
let a = channelId(1), b = channelId(8_000_000_001)
let nonChannel = PeerId(namespace: ._internalFromInt32Value(0), id: ._internalFromInt64Value(123))
let state = ArielgramWatchlist(peerIds: [a.toInt64(), a.toInt64(), nonChannel.toInt64(), b.toInt64()])
precondition(state.peerIds == [a.toInt64(), b.toInt64()])
precondition(state.withUpdatedPeer(a, watched: true) == state)
precondition(state.withUpdatedPeer(a, watched: false).peerIds == [b.toInt64()])
precondition(state.withUpdatedPeer(nonChannel, watched: true) == state)

// Run the real Postbox PreferencesEntry codec, including 64-bit peer IDs.
let stored = PreferencesEntry(state)!
precondition(PreferencesEntry(data: stored.data).get(ArielgramWatchlist.self) == state)
precondition(PreferencesEntry(ArielgramWatchlist())!.get(ArielgramWatchlist.self) == ArielgramWatchlist())

let account = Account(), otherAccount = Account()
let channel = TelegramChannel(a)
account.postbox.peers[a] = channel
precondition(arielgramCanWatchPeer(channel))
precondition(arielgramSetPeerWatched(account: account, peerId: a, watched: true).value)
precondition(channel.participationStatus == .left)
precondition(arielgramWatchlist(account: account).value.contains(a))
precondition(!arielgramWatchlist(account: otherAccount).value.contains(a))
precondition(arielgramWatchlistPeers(account: account).value.map(\.id) == [a])
channel.username = nil
precondition(!arielgramCanWatchPeer(channel))
channel.usernames = [Username(username: "alias", isActive: false)]
precondition(!arielgramCanWatchPeer(channel))
channel.usernames = [Username(username: "alias", isActive: true)]
precondition(arielgramCanWatchPeer(channel))
channel.participationStatus = .member
precondition(!arielgramCanWatchPeer(channel))
precondition(!arielgramSetPeerWatched(account: account, peerId: a, watched: true).value)
channel.participationStatus = .kicked
precondition(!arielgramCanWatchPeer(channel))
precondition(arielgramSetPeerWatched(account: account, peerId: a, watched: false).value)
precondition(arielgramWatchlistPeers(account: account).value.isEmpty)
precondition(!arielgramSetPeerWatched(account: account, peerId: b, watched: true).value)

// Reopen at the root or thread anchor, but preserve ordinary joined-chat behavior.
channel.participationStatus = .left
precondition(arielgramSetPeerWatched(account: account, peerId: a, watched: true).value)
account.postbox.rootStates[a] = StoredPeerChatInterfaceState(historyScrollMessageIndex: MessageIndex(value: 50))
account.postbox.threadStates[100] = StoredPeerChatInterfaceState(historyScrollMessageIndex: MessageIndex(value: 75))
let context = AccountContext(account)
let root = watchlistHistoryAnchor(context: context, chatLocation: ChatLocation(peerId: a), tag: nil, useRootInterfaceStateForThread: false).value
precondition(root.watched && root.index?.value == 50)
let thread = watchlistHistoryAnchor(context: context, chatLocation: ChatLocation(peerId: a, threadId: 100), tag: nil, useRootInterfaceStateForThread: false).value
precondition(thread.watched && thread.index?.value == 75)
let useRoot = watchlistHistoryAnchor(context: context, chatLocation: ChatLocation(peerId: a, threadId: 100), tag: nil, useRootInterfaceStateForThread: true).value
precondition(useRoot.index?.value == 50)
precondition(!watchlistHistoryAnchor(context: context, chatLocation: ChatLocation(peerId: a), tag: HistoryViewInputTag(), useRootInterfaceStateForThread: false).value.watched)
channel.participationStatus = .member
precondition(!watchlistHistoryAnchor(context: context, chatLocation: ChatLocation(peerId: a), tag: nil, useRootInterfaceStateForThread: false).value.watched)

// Retain a visible bottom message so future arrivals cannot move the resume point.
let node = HistoryNode(), message = Message(50)
node.historyView = HistoryView(filteredEntries: [.MessageEntry(message, 0, 0, 0, 0, 0)], originalView: OriginalView())
node.nodes = [ChatMessageItemView(message)]
precondition(node.immediateScrollState() == nil)
let bottom = node.immediateScrollState(preserveBottom: true)!
precondition(bottom.messageIndex.value == 50 && bottom.relativeOffset == 17.0)
node.historyView = HistoryView(filteredEntries: [.MessageGroupEntry(0, [(message, 0)], 0)], originalView: OriginalView())
precondition(node.immediateScrollState(preserveBottom: true)?.messageIndex.value == 50)
node.historyView = nil
precondition(node.immediateScrollState(preserveBottom: true) == nil)
print("Watchlist persistence, account isolation, eligibility, and reading-position checks passed")
