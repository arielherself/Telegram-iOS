// Host interfaces for the production profile-change policy. Serialization below
// is supplied by the repository's actual Postbox encoder and decoder.
import Foundation
func postboxLog(_ message: String) {}
func mdb_cmp_memn(_ lhs: UnsafeMutableRawPointer, _ lhsLength: Int, _ rhs: UnsafeMutableRawPointer, _ rhsLength: Int) -> Int32 {
    let result = memcmp(lhs, rhs, min(lhsLength, rhsLength))
    return result == 0 ? Int32(lhsLength - rhsLength) : result
}
struct PeerId: Hashable, Comparable {
    let namespace: Int32
    let value: Int64
    init(namespace: Int32 = 0, value: Int64) { self.namespace = namespace; self.value = value }
    init(_ value: Int64) { self.namespace = Int32(value >> 56); self.value = value & 0x00ffffffffffffff }
    func toInt64() -> Int64 { (Int64(self.namespace) << 56) | self.value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.toInt64() < rhs.toInt64() }
}
protocol Peer: AnyObject { var id: PeerId { get } }
struct ResourceId { let stringRepresentation: String }
class Resource { let id: ResourceId; init(_ id: String) { self.id = ResourceId(stringRepresentation: id) } }
final class CloudPeerPhotoSizeMediaResource: Resource {
    let photoId: Int64?
    init(_ photoId: Int64?, resourceId: String) { self.photoId = photoId; super.init(resourceId) }
}
struct Dimensions { var width: Int32 = 80 }
struct TelegramMediaImageRepresentation {
    let resource: Resource
    var immediateThumbnailData: Data? = nil
    var dimensions = Dimensions()
}
final class TelegramUser: Peer {
    let id: PeerId; let firstName: String?; let lastName: String?; let photo: [TelegramMediaImageRepresentation]
    init(_ id: PeerId, name: String?, lastName: String? = nil, photo: [TelegramMediaImageRepresentation] = []) { self.id = id; self.firstName = name; self.lastName = lastName; self.photo = photo }
}
struct GroupFlags: OptionSet { let rawValue: Int; static let deactivated = Self(rawValue: 1) }
enum GroupMembership { case Member, Left }
final class TelegramGroup: Peer {
    let id: PeerId; let title: String; let photo: [TelegramMediaImageRepresentation]
    var membership = GroupMembership.Member; var flags: GroupFlags = []
    init(_ id: PeerId, title: String, photo: [TelegramMediaImageRepresentation] = []) { self.id = id; self.title = title; self.photo = photo }
}
enum ChannelStatus { case member, left }
enum ChannelInfo { case group, broadcast }
final class TelegramChannel: Peer {
    let id: PeerId; let title: String; let photo: [TelegramMediaImageRepresentation]
    var participationStatus = ChannelStatus.member; var info: ChannelInfo
    init(_ id: PeerId, title: String, info: ChannelInfo = .group, photo: [TelegramMediaImageRepresentation] = []) { self.id = id; self.title = title; self.info = info; self.photo = photo }
}
struct PeerReference: PostboxCoding {
    let value: Int64
    init?(_ peer: Peer) { self.value = peer.id.toInt64() }
    init(decoder: PostboxDecoder) { self.value = decoder.decodeInt64ForKey("p", orElse: 0) }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeInt64(self.value, forKey: "p") }
}
struct MediaId: Hashable { let namespace: Int32; let id: Int64 }
protocol Media: AnyObject, PostboxCoding { var id: MediaId? { get } }
protocol MessageAttribute: AnyObject, PostboxCoding {}
protocol MessageMediaHistoryAttribute { var mediaForStorage: [Media] { get } }
final class TelegramMediaImage: Media {
    let imageId: MediaId; let representations: [TelegramMediaImageRepresentation]; let immediateThumbnailData: Data?
    var id: MediaId? { self.imageId }
    init(imageId: MediaId, representations: [TelegramMediaImageRepresentation], immediateThumbnailData: Data?, reference: Int?, partialReference: Int?, flags: [Int]) { self.imageId = imageId; self.representations = representations; self.immediateThumbnailData = immediateThumbnailData }
    init(decoder: PostboxDecoder) {
        self.imageId = MediaId(namespace: decoder.decodeInt32ForKey("n", orElse: 0), id: decoder.decodeInt64ForKey("i", orElse: 0))
        self.representations = decoder.decodeStringArrayForKey("r").map { TelegramMediaImageRepresentation(resource: Resource($0)) }
        self.immediateThumbnailData = decoder.decodeBytesForKey("t")?.makeData()
    }
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.imageId.namespace, forKey: "n"); encoder.encodeInt64(self.imageId.id, forKey: "i")
        encoder.encodeStringArray(self.representations.map { $0.resource.id.stringRepresentation }, forKey: "r")
        if let data = self.immediateThumbnailData { encoder.encodeBytes(MemoryBuffer(data: data), forKey: "t") } else { encoder.encodeNil(forKey: "t") }
    }
}
enum TelegramMediaActionType {
    case titleUpdated(title: String), photoUpdated(image: TelegramMediaImage?)
    case addedMembers(peerIds: [PeerId]), removedMembers(peerIds: [PeerId])
    case joinedByLink(inviter: PeerId), joinedByRequest
    case customText(text: String, entities: [Int], additionalAttributes: Int?)
}
final class TelegramMediaAction: Media {
    let action: TelegramMediaActionType; var id: MediaId? { nil }
    init(action: TelegramMediaActionType) { self.action = action }
    init(decoder: PostboxDecoder) { self.action = .customText(text: "", entities: [], additionalAttributes: nil) }
    func encode(_ encoder: PostboxEncoder) {}
}
struct MessageId: Hashable { let peerId: PeerId; let namespace: Int32; let id: Int32 }
enum StoreMessageId {
    case Id(MessageId), Partial(PeerId, Int32)
    var peerId: PeerId { switch self { case let .Id(id): return id.peerId; case let .Partial(id, _): return id } }
    var namespace: Int32 { switch self { case let .Id(id): return id.namespace; case let .Partial(_, namespace): return namespace } }
}
struct StoreMessageFlags: OptionSet {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(_ value: Self) { self = value }
    static let Incoming = Self(rawValue: 1)
}
struct StoreMessageForwardInfo {
    let author: Peer? = nil; let source: Peer? = nil; let sourceMessageId: MessageId? = nil
    let date: Int32 = 0; let authorSignature: String? = nil; let psaType: String? = nil; let flags: Int = 0
    init(authorId: PeerId?, sourceId: PeerId?, sourceMessageId: MessageId?, date: Int32, authorSignature: String?, psaType: String?, flags: Int) {}
}
final class StoreMessage {
    let id: StoreMessageId; let customStableId: UInt32?; let globallyUniqueId: Int64?; let groupingKey: Int64?; let threadId: Int64?; let timestamp: Int32
    let flags: StoreMessageFlags; let tags: [Int]; let globalTags: [Int]; let localTags: [Int]; let forwardInfo: StoreMessageForwardInfo?; let authorId: PeerId?; let text: String; let attributes: [MessageAttribute]; let media: [Media]
    init(id: MessageId, customStableId: UInt32?, globallyUniqueId: Int64?, groupingKey: Int64?, threadId: Int64?, timestamp: Int32, flags: StoreMessageFlags, tags: [Int], globalTags: [Int], localTags: [Int], forwardInfo: StoreMessageForwardInfo?, authorId: PeerId?, text: String, attributes: [MessageAttribute], media: [Media]) {
        self.id = .Id(id); self.customStableId = customStableId; self.globallyUniqueId = globallyUniqueId; self.groupingKey = groupingKey; self.threadId = threadId; self.timestamp = timestamp; self.flags = flags; self.tags = tags; self.globalTags = globalTags; self.localTags = localTags; self.forwardInfo = forwardInfo; self.authorId = authorId; self.text = text; self.attributes = attributes; self.media = media
    }
    init(peerId: PeerId, namespace: Int32, customStableId: UInt32?, globallyUniqueId: Int64?, groupingKey: Int64?, threadId: Int64?, timestamp: Int32, flags: StoreMessageFlags, tags: [Int], globalTags: [Int], localTags: [Int], forwardInfo: StoreMessageForwardInfo?, authorId: PeerId?, text: String, attributes: [MessageAttribute], media: [Media]) {
        self.id = .Partial(peerId, namespace); self.customStableId = customStableId; self.globallyUniqueId = globallyUniqueId; self.groupingKey = groupingKey; self.threadId = threadId; self.timestamp = timestamp; self.flags = flags; self.tags = tags; self.globalTags = globalTags; self.localTags = localTags; self.forwardInfo = forwardInfo; self.authorId = authorId; self.text = text; self.attributes = attributes; self.media = media
    }
}
final class Message {
    let id: MessageId; let stored: StoreMessage; var author: Peer?
    init(id: MessageId, stored: StoreMessage, author: Peer? = nil) { self.id = id; self.stored = stored; self.author = author }
    var attributes: [MessageAttribute] { stored.attributes }; var media: [Media] { stored.media }; var timestamp: Int32 { stored.timestamp }
    var flags: StoreMessageFlags { stored.flags }; var globallyUniqueId: Int64? { stored.globallyUniqueId }; var groupingKey: Int64? { stored.groupingKey }; var threadId: Int64? { stored.threadId }
    var tags: [Int] { stored.tags }; var globalTags: [Int] { stored.globalTags }; var localTags: [Int] { stored.localTags }; var forwardInfo: StoreMessageForwardInfo? { stored.forwardInfo }; var text: String { stored.text }
}
final class ValueBoxKey { var value: Int64 = 0; init(length: Int) {}; func setInt64(_ offset: Int, value: Int64) { self.value = value } }
struct ItemCacheEntryId: Hashable { let collectionId: Int8; let value: Int64; init(collectionId: Int8, key: ValueBoxKey) { self.collectionId = collectionId; self.value = key.value } }
struct CodableEntry {
    let data: Data
    init?<T: Encodable>(_ value: T) { guard let data = try? JSONEncoder().encode(value) else { return nil }; self.data = data }
    func get<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: self.data) }
}
struct BanInfo { var isMember: Bool }
enum ChannelParticipant {
    case creator(PeerId)
    case member(PeerId, Int32, Bool?, BanInfo?, String?, Int32?)
    var peerId: PeerId { switch self { case let .creator(id): return id; case let .member(id, _, _, _, _, _): return id } }
}
struct GroupParticipant { let peerId: PeerId }
struct CachedGroupParticipants { let participants: [GroupParticipant] }
struct CachedGroupData { let participants: CachedGroupParticipants? }
enum AddMessagesLocation { case Random }
enum PostboxUpdateMessage { case update(StoreMessage) }
final class Transaction {
    var peers: [PeerId: Peer] = [:]; var chats: Set<PeerId> = []; var messages: [MessageId: Message] = [:]
    var cachedGroups: [PeerId: CachedGroupData] = [:]; var cache: [ItemCacheEntryId: CodableEntry] = [:]; var nextId: Int32 = 1
    func getPeer(_ id: PeerId) -> Peer? { peers[id] }
    func getPeerChatInterfaceState(_ id: PeerId) -> Bool? { nil }
    func getPeerChatListIndex(_ id: PeerId) -> Bool? { chats.contains(id) ? true : nil }
    func getTopPeerMessageIndex(peerId: PeerId) -> Bool? { messages.keys.contains { $0.peerId == peerId } ? true : nil }
    func chatListGetAllPeerIds() -> [PeerId] { Array(chats) }
    func getPeerCachedData(peerId: PeerId) -> Any? { cachedGroups[peerId] }
    func retrieveItemCacheEntry(id: ItemCacheEntryId) -> CodableEntry? { cache[id] }
    func putItemCacheEntry(id: ItemCacheEntryId, entry: CodableEntry) { cache[id] = entry }
    func hasMessageWithAuthor(peerId: PeerId, namespace: Int32, authorId: PeerId, afterTimestamp: Int32? = nil) -> Bool { messages.values.contains { $0.id.peerId == peerId && $0.id.namespace == namespace && $0.author?.id == authorId && (afterTimestamp == nil || $0.timestamp > afterTimestamp!) } }
    func scanTopMessages(peerId: PeerId, namespace: Int32, limit: Int, _ f: (Message) -> Bool) {
        for message in messages.values.filter({ $0.id.peerId == peerId && $0.id.namespace == namespace }).sorted(by: { $0.id.id > $1.id.id }).prefix(limit) { if !f(message) { break } }
    }
    func addMessages(_ values: [StoreMessage], location: AddMessagesLocation) -> [Int64: MessageId] {
        for stored in values {
            let id: MessageId
            switch stored.id { case let .Id(value): id = value; case let .Partial(peerId, namespace): id = MessageId(peerId: peerId, namespace: namespace, id: nextId); nextId += 1 }
            messages[id] = Message(id: id, stored: stored, author: stored.authorId.flatMap { peers[$0] })
        }
        return [:]
    }
    func updateMessage(_ id: MessageId, update: (Message) -> PostboxUpdateMessage) {
        if let previous = messages[id], case let .update(updated) = update(previous) { messages[id] = Message(id: id, stored: updated, author: previous.author) }
    }
    func deleteMessages(_ ids: [MessageId], forEachMedia: ((Media) -> Void)?) { for id in ids { messages.removeValue(forKey: id) } }
}
enum Namespaces {
    enum Message { static let Cloud: Int32 = 0; static let Local: Int32 = 1 }
    enum Media { static let LocalImage: Int32 = 7 }
    enum CachedItemCollection { static let arielgramObservedGroupMembers: Int8 = 56 }
}
