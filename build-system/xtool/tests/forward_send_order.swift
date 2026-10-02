// Host models replace Postbox/network I/O; gate and drain methods are production code.
struct PeerId: Hashable, Comparable {
    var namespace: Int32 = 0
    var id: Int64
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.namespace, lhs.id) < (rhs.namespace, rhs.id) }
}
struct MessageId: Hashable, Comparable {
    var peerId: PeerId
    var namespace: Int32 = Namespaces.Message.Local
    var id: Int32
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.peerId != rhs.peerId { return lhs.peerId < rhs.peerId }
        return (lhs.namespace, lhs.id) < (rhs.namespace, rhs.id)
    }
}
enum Namespaces {
    enum Message { static let Local: Int32 = 1; static let ScheduledCloud: Int32 = 2; static let ScheduledLocal: Int32 = 3 }
    enum Peer { static let SecretChat: Int32 = 4 }
}
struct Message {
    static let newTopicThreadId: Int64 = -1
    var id: MessageId
    var groupingKey: Int64?
    var threadId: Int64?
}
struct PeerAndThreadId: Hashable { var peerId: PeerId; var threadId: Int64? }
struct MediaId: Hashable {}
struct PeerInputActivity {}
enum PendingMessageUploadedContentType { case media }
struct PendingMessageUploadedContentProgress { var progress: Float = 0; var mediaProgress: [MediaId: Float] = [:] }
enum PendingMessageUploadError: Error { case failed }
enum PendingMessageUploadedContentResult {}
struct ForwardSourceInfoAttribute {}
struct PendingMessageUploadedContentAndReuploadInfo {
    enum Content { case text; case forward(ForwardSourceInfoAttribute) }
    var content: Content = .text
    var reuploadInfo: Int?
    var cacheReferenceKey: Int?
}
final class Queue { func isCurrent() -> Bool { true } }
func deliverOn<T, E>(_ queue: Queue) -> (Signal<T, E>) -> Signal<T, E> { { $0 } }

final class PendingMessageManager {
    let queue = Queue()
    let network = 0, postbox = 0, stateManager = 0
    let accountPeerId = PeerId(id: 99)
    var messageContexts: [MessageId: PendingMessageContext] = [:]
    var pendingMessageIds = Set<MessageId>()
    var liveTypingDraftKeys = Set<PeerAndThreadId>()
    var forwardSendGateGroups: [PeerAndThreadId: [[(PendingMessageContext, Message, ForwardSourceInfoAttribute)]]] = [:]
    // Order in which the simulated server assigns IDs, separate from local display order.
    var confirmedOrder: [Int32] = []
    func updateWaitingUploads(peerId: PeerId) {}
    func updatePendingMediaUploads() {}
    func sendMessageContent(network: Int, postbox: Int, stateManager: Int, accountPeerId: PeerId, messageId: MessageId, content: PendingMessageUploadedContentAndReuploadInfo) -> Signal<Void, NoError> {
        Signal { subscriber in
            self.confirmedOrder.append(messageId.id)
            subscriber.putNext(())
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    func sendGroupMessagesContent(network: Int, postbox: Int, stateManager: Int, accountPeerId: PeerId, group: [(MessageId, PendingMessageUploadedContentAndReuploadInfo)]) -> Signal<Void, NoError> {
        Signal { subscriber in
            self.confirmedOrder.append(contentsOf: group.map { $0.0.id }.sorted())
            subscriber.putNext(())
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    // Production gate methods.

    @discardableResult
    func add(_ id: Int32, peer: PeerId = PeerId(id: 1), thread: Int64? = nil, forward: Bool? = false, group: Int64? = nil, namespace: Int32 = Namespaces.Message.Local) -> MessageId {
        let messageId = MessageId(peerId: peer, namespace: namespace, id: id)
        let context = PendingMessageContext()
        context.threadId = thread
        context.isForward = forward
        context.state = .collectingInfo(message: Message(id: messageId, groupingKey: group, threadId: thread))
        self.messageContexts[messageId] = context
        self.pendingMessageIds.insert(messageId)
        return messageId
    }
    func parkForwards(_ ids: [MessageId]) {
        let messages = ids.map { id -> (PendingMessageContext, Message, ForwardSourceInfoAttribute) in
            let context = self.messageContexts[id]!
            context.state = .waitingForForwardSendGate
            return (context, Message(id: id, groupingKey: nil, threadId: context.threadId), ForwardSourceInfoAttribute())
        }
        let key = PeerAndThreadId(peerId: ids[0].peerId, threadId: messages[0].0.threadId)
        self.forwardSendGateGroups[key, default: []].append(messages)
    }
    func prepareText(_ id: MessageId, group: Int64? = nil) {
        self.beginSendingMessage(messageContext: self.messageContexts[id]!, messageId: id, groupId: group, content: PendingMessageUploadedContentAndReuploadInfo())
    }
    func confirmOrRemove(_ ids: [MessageId]) {
        for id in ids {
            self.pendingMessageIds.remove(id)
            // Keep the inactive context to cover surviving status subscriptions.
            self.messageContexts[id]?.state = .none
        }
        self.drainWaitingSendGates(peerIds: Set(ids.map { $0.peerId }))
    }
}

let peer = PeerId(id: 1)
let key = PeerAndThreadId(peerId: peer, threadId: nil)

// Text is ready before forward RPC registration. It must remain parked even
// when repeated drains occur, and until every forward leaves the pending set.
let ordinary = PendingMessageManager()
let f1 = ordinary.add(1, forward: true), f2 = ordinary.add(2, forward: true)
let text = ordinary.add(3)
ordinary.prepareText(text)
precondition(ordinary.confirmedOrder.isEmpty)
ordinary.parkForwards([f1, f2])
ordinary.drainSendGate(key: key)
ordinary.drainSendGate(key: key)
precondition(ordinary.confirmedOrder == [1, 2])
ordinary.confirmOrRemove([f1])
precondition(ordinary.confirmedOrder == [1, 2])
ordinary.confirmOrRemove([f2])
precondition(ordinary.confirmedOrder == [1, 2, 3])

// Releasing a typing draft previously drained singles before forwarded groups.
// Several forward groups and split accompanying text must retain server order.
let drafts = PendingMessageManager()
let forwards = (1...3).map { drafts.add(Int32($0), forward: true) }
let texts = (4...5).map { drafts.add(Int32($0)) }
drafts.liveTypingDraftKeys.insert(key)
texts.forEach { drafts.prepareText($0) }
drafts.parkForwards(Array(forwards.prefix(2)))
drafts.parkForwards([forwards[2]])
drafts.drainWaitingSendGates(peerIds: [peer])
precondition(drafts.confirmedOrder.isEmpty)
drafts.liveTypingDraftKeys.remove(key)
drafts.drainSendGate(key: key)
precondition(drafts.confirmedOrder == [1, 2, 3])
drafts.confirmOrRemove(Array(forwards.prefix(2)))
precondition(drafts.confirmedOrder == [1, 2, 3])
drafts.confirmOrRemove([forwards[2]])
precondition(drafts.confirmedOrder == [1, 2, 3, 4, 5])

// Following media albums also wait, including groups assembled out of order.
let albums = PendingMessageManager()
let albumForward = albums.add(1, forward: true)
let a1 = albums.add(2, group: 10), a2 = albums.add(3, group: 10)
albums.prepareText(a2, group: 10)
albums.prepareText(a1, group: 10)
albums.commitSendingMessageGroup(groupId: 10, messages: albums.dataForPendingMessageGroup(10)!.reversed())
precondition(albums.confirmedOrder.isEmpty)
albums.parkForwards([albumForward])
albums.drainSendGate(key: key)
albums.confirmOrRemove([albumForward])
precondition(albums.confirmedOrder == [1, 2, 3])

// Unknown earlier metadata parks text; learning it is ordinary text releases it.
let loading = PendingMessageManager()
let unknown = loading.add(1, forward: nil)
let afterUnknown = loading.add(2)
loading.prepareText(afterUnknown)
precondition(loading.confirmedOrder.isEmpty)
loading.messageContexts[unknown]!.isForward = false
loading.drainWaitingSendGates(peerIds: [peer])
precondition(loading.confirmedOrder == [2])

// Removing/cancelling a forward releases text, even if its context survives.
let cancellation = PendingMessageManager()
let cancelled = cancellation.add(1, forward: true)
let afterCancelled = cancellation.add(2)
cancellation.prepareText(afterCancelled)
cancellation.confirmOrRemove([cancelled])
precondition(cancellation.confirmedOrder == [2])

// Other peers/topics, scheduled sends, and secret chats do not wait on an
// unrelated forward. A comment intentionally preceding a forward still sends.
let isolation = PendingMessageManager()
isolation.add(1, forward: true)
for id in [isolation.add(2, peer: PeerId(id: 2)), isolation.add(3, thread: 10), isolation.add(4, namespace: Namespaces.Message.ScheduledLocal)] {
    isolation.prepareText(id)
}
precondition(isolation.confirmedOrder == [2, 3, 4])
let saved = PendingMessageManager()
let sf = saved.add(1, peer: saved.accountPeerId, forward: true)
let st = saved.add(2, peer: saved.accountPeerId)
saved.prepareText(st)
precondition(saved.confirmedOrder.isEmpty)
saved.confirmOrRemove([sf])
precondition(saved.confirmedOrder == [2])
let scheduled = PendingMessageManager()
let scheduledForward = scheduled.add(1, forward: true, namespace: Namespaces.Message.ScheduledLocal)
let scheduledText = scheduled.add(2, namespace: Namespaces.Message.ScheduledLocal)
scheduled.prepareText(scheduledText)
precondition(scheduled.confirmedOrder.isEmpty)
scheduled.confirmOrRemove([scheduledForward])
precondition(scheduled.confirmedOrder == [2])
// A draft reopened while the RPC was in flight still blocks the accompanying
// text when confirmation arrives; closing it later releases that text once.
let reopened = PendingMessageManager()
let reopenedForward = reopened.add(1, forward: true)
let reopenedText = reopened.add(2)
reopened.prepareText(reopenedText)
reopened.liveTypingDraftKeys.insert(key)
reopened.confirmOrRemove([reopenedForward])
precondition(reopened.confirmedOrder.isEmpty)
reopened.liveTypingDraftKeys.remove(key)
reopened.drainSendGate(key: key)
precondition(reopened.confirmedOrder == [2])
let secret = PendingMessageManager()
let secretPeer = PeerId(namespace: Namespaces.Peer.SecretChat, id: 1)
secret.add(1, peer: secretPeer, forward: true)
secret.prepareText(secret.add(2, peer: secretPeer))
precondition(secret.confirmedOrder == [2])
let prefix = PendingMessageManager()
let prefixText = prefix.add(1)
prefix.add(2, forward: true)
prefix.prepareText(prefixText)
precondition(prefix.confirmedOrder == [1])
print("Forward registration races, confirmation order, draft release, albums, cancellation and isolation passed")
