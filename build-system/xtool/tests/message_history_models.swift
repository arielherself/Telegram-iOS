// Minimal message interfaces for executing the production history policy on
// Linux. Serialization uses the repository's real Postbox codec, not a mock.
import Foundation

func postboxLog(_ message: String) { print(message) }
func mdb_cmp_memn(_ lhs: UnsafeMutableRawPointer, _ lhsLength: Int, _ rhs: UnsafeMutableRawPointer, _ rhsLength: Int) -> Int32 {
    let result = memcmp(lhs, rhs, min(lhsLength, rhsLength))
    return result == 0 ? Int32(lhsLength - rhsLength) : result
}

public struct PeerId: Hashable {
    public let namespace: Int32
    public init(namespace: Int32) { self.namespace = namespace }
}
public struct MessageId: Hashable {
    public let peerId: PeerId
    public let namespace: Int32
    public let id: Int32
    public init(peerId: PeerId, namespace: Int32, id: Int32) {
        self.peerId = peerId; self.namespace = namespace; self.id = id
    }
}
public struct MediaId: Hashable {
    public let id: Int32
    public init(id: Int32) { self.id = id }
}
public protocol Media: AnyObject, PostboxCoding {
    var id: MediaId? { get }
    func isEqual(to: Media) -> Bool
}
public struct StoryId: Hashable { public init() {} }
public protocol MessageAttribute: AnyObject, PostboxCoding {
    var associatedMediaIds: [MediaId] { get }
    var associatedPeerIds: [PeerId] { get }
    var associatedMessageIds: [MessageId] { get }
    var associatedStoryIds: [StoryId] { get }
}
public extension MessageAttribute {
    var associatedMediaIds: [MediaId] { [] }
    var associatedPeerIds: [PeerId] { [] }
    var associatedMessageIds: [MessageId] { [] }
    var associatedStoryIds: [StoryId] { [] }
}
public protocol MessageMediaHistoryAttribute { var mediaForStorage: [Media] { get } }
public struct MessageTags: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let unseenPersonalMessage = MessageTags(rawValue: 1)
    public static let unseenReaction = MessageTags(rawValue: 2)
    public static let pinned = MessageTags(rawValue: 4)
}
public struct StoreMessageFlags {
    public init(_ value: StoreMessageFlags) { self = value }
    public init() {}
}
public struct StoreMessageForwardInfo { public init(_ value: StoreMessageForwardInfo) { self = value } }
public final class Peer { public var id = PeerId(namespace: 0) }
public final class Message {
    public let id: MessageId
    public let text: String
    public let attributes: [MessageAttribute]
    public let media: [Media]
    public var timestamp: Int32 = 10
    public var stableId: UInt32 = 1
    public var globallyUniqueId: Int64? = nil
    public var groupingKey: Int64? = nil
    public var threadId: Int64? = nil
    public var flags = StoreMessageFlags()
    public var tags: MessageTags = []
    public var globalTags: MessageTags = []
    public var localTags: MessageTags = []
    public var forwardInfo: StoreMessageForwardInfo? = nil
    public var author: Peer? = nil
    public var effectiveMedia: [Media] { self.media }
    public init(id: MessageId, text: String, attributes: [MessageAttribute] = [], media: [Media] = []) {
        self.id = id; self.text = text; self.attributes = attributes; self.media = media
    }
    public convenience init(_ stored: StoreMessage) {
        self.init(id: stored.id, text: stored.text, attributes: stored.attributes, media: stored.media)
    }
}
public final class StoreMessage {
    public let id: MessageId
    public let text: String
    public let attributes: [MessageAttribute]
    public let media: [Media]
    public init(id: MessageId, customStableId: UInt32?, globallyUniqueId: Int64?, groupingKey: Int64?, threadId: Int64?, timestamp: Int32, flags: StoreMessageFlags, tags: MessageTags, globalTags: MessageTags, localTags: MessageTags, forwardInfo: StoreMessageForwardInfo?, authorId: PeerId?, text: String, attributes: [MessageAttribute], media: [Media]) {
        self.id = id; self.text = text; self.attributes = attributes; self.media = media
    }
    public init(_ message: Message) {
        self.id = message.id; self.text = message.text; self.attributes = message.attributes; self.media = message.media
    }
    public func withUpdatedAttributes(_ attributes: [MessageAttribute]) -> StoreMessage {
        return StoreMessage(Message(id: self.id, text: self.text, attributes: attributes, media: self.media))
    }
}
public enum PostboxUpdateMessage { case update(StoreMessage) }
public final class Transaction {
    public var messages: [MessageId: Message]
    public init(_ messages: [MessageId: Message]) { self.messages = messages }
    public func getMessage(_ id: MessageId) -> Message? { return self.messages[id] }
    public func updateMessage(_ id: MessageId, update: (Message) -> PostboxUpdateMessage) {
        if let message = self.messages[id], case let .update(updated) = update(message) {
            self.messages[id] = Message(updated)
        }
    }
}
