import Foundation
func postboxLog(_ message: String) {}
func mdb_cmp_memn(_ lhs: UnsafeMutableRawPointer, _ lhsLength: Int, _ rhs: UnsafeMutableRawPointer, _ rhsLength: Int) -> Int32 {
    let result = memcmp(lhs, rhs, min(lhsLength, rhsLength))
    return result == 0 ? Int32(lhsLength - rhsLength) : result
}
enum Namespaces { enum Peer { static let CloudChannel = PeerId.Namespace._internalFromInt32Value(2) } }
protocol Peer: AnyObject { var id: PeerId { get } }
enum ParticipationStatus { case left, member, kicked }
struct Username { let username: String; let isActive: Bool }
final class TelegramChannel: Peer {
    let id: PeerId
    var username: String?
    var usernames: [Username] = []
    var participationStatus = ParticipationStatus.left
    init(_ id: PeerId, username: String? = "public") { self.id = id; self.username = username }
}
struct EnginePeer { let peer: Peer; init(_ peer: Peer) { self.peer = peer }; var id: PeerId { peer.id } }
enum NoError: Error {}
struct Signal<T, E: Error> { let value: T; static func single(_ value: T) -> Self { Self(value: value) } }
precedencegroup PipePrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
}
infix operator |> : PipePrecedence
func |> <T, U>(lhs: T, rhs: (T) -> U) -> U { rhs(lhs) }
func map<T, U>(_ f: @escaping (T) -> U) -> (Signal<T, NoError>) -> Signal<U, NoError> { { .single(f($0.value)) } }
func mapToSignal<T, U>(_ f: @escaping (T) -> Signal<U, NoError>) -> (Signal<T, NoError>) -> Signal<U, NoError> { { f($0.value) } }
func distinctUntilChanged<T>(_ signal: Signal<T, NoError>) -> Signal<T, NoError> { signal }
func take<T>(_ count: Int) -> (Signal<T, NoError>) -> Signal<T, NoError> { { $0 } }
enum PreferencesKeys { static let arielgramWatchlist = "watchlist" }
enum ViewKey: Hashable { case basicPeer(PeerId) }
struct PreferencesView { let values: [String: PreferencesEntry] }
final class BasicPeerView { let peer: Peer?; init(_ peer: Peer?) { self.peer = peer } }
struct CombinedView { let views: [ViewKey: AnyObject] }
struct MessageIndex: Equatable { let value: Int }
struct StoredPeerChatInterfaceState { let historyScrollMessageIndex: MessageIndex? }
final class TestPostbox {
    var peers: [PeerId: Peer] = [:]
    var preferences: [String: PreferencesEntry] = [:]
    var rootStates: [PeerId: StoredPeerChatInterfaceState] = [:]
    var threadStates: [Int64: StoredPeerChatInterfaceState] = [:]
    func transaction<T>(_ action: (TestPostbox) -> T) -> Signal<T, NoError> { .single(action(self)) }
    func getPeer(_ id: PeerId) -> Peer? { peers[id] }
    func updatePreferencesEntry(key: String, _ update: (PreferencesEntry?) -> PreferencesEntry?) { preferences[key] = update(preferences[key]) }
    func preferencesView(keys: [String]) -> Signal<PreferencesView, NoError> { .single(PreferencesView(values: preferences)) }
    func combinedView(keys: [ViewKey]) -> Signal<CombinedView, NoError> {
        .single(CombinedView(views: Dictionary(uniqueKeysWithValues: keys.map { key in
            switch key { case let .basicPeer(id): return (key, BasicPeerView(peers[id]) as AnyObject) }
        })))
    }
    func getPeerChatInterfaceState(_ id: PeerId) -> StoredPeerChatInterfaceState? { rootStates[id] }
    func getPeerChatThreadInterfaceState(_ id: PeerId, threadId: Int64) -> StoredPeerChatInterfaceState? { threadStates[threadId] }
}
final class Account { let postbox = TestPostbox() }
final class AccountContext { let account: Account; init(_ account: Account) { self.account = account } }
struct ChatLocation { let peerId: PeerId?; var threadId: Int64? = nil }
struct HistoryViewInputTag {}

struct ChatInterfaceHistoryScrollState { let messageIndex: MessageIndex; let relativeOffset: Double }
final class Message { let index: MessageIndex; let id: Int; var adAttribute: Bool? = nil; init(_ id: Int) { self.id = id; self.index = MessageIndex(value: id) } }
enum HistoryEntry { case MessageEntry(Message, Int, Int, Int, Int, Int); case MessageGroupEntry(Int, [(Message, Int)], Int); case ChatInfoEntry }
struct HistoryView { var filteredEntries: [HistoryEntry]; let originalView: OriginalView }
struct OriginalView { var laterId: Int? = nil }
struct VisibleRange { let firstIndex: Int; let lastIndex: Int }
struct DisplayedRange { let visibleRange: VisibleRange? }
final class ListView {
    var displayedItemRange = DisplayedRange(visibleRange: VisibleRange(firstIndex: 0, lastIndex: 1))
    func itemNodeRelativeOffset(_ node: ChatMessageItemView) -> CGFloat? { 17.0 }
}
struct Item { let message: Message }
final class ChatMessageItemView { let item: Item?; init(_ message: Message) { self.item = Item(message: message) } }
final class HistoryNode {
    let listView = ListView()
    var historyView: HistoryView?
    var nodes: [AnyObject] = []
    func forEachItemNode(_ action: (AnyObject) -> Void) { nodes.forEach(action) }
    // Production scroll-state function goes here.
}
