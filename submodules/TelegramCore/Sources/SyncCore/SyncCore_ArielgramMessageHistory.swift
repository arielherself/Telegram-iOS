import Foundation
import Postbox

/// A complete content snapshot. History itself is excluded to avoid recursive
/// archives; the containing message supplies its unchanged peer/reply context.
public final class ArielgramMessageVersion: PostboxCoding {
    public let timestamp: Int32
    public let text: String
    public let attributes: [MessageAttribute]
    public let media: [Media]

    public init(message: Message) {
        self.timestamp = message.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first ?? message.timestamp
        self.text = message.text
        self.attributes = message.attributes.filter { !($0 is ArielgramMessageHistoryAttribute) }
        self.media = message.media
    }

    public init(decoder: PostboxDecoder) {
        self.timestamp = decoder.decodeInt32ForKey("t", orElse: 0)
        self.text = decoder.decodeStringForKey("s", orElse: "")
        self.attributes = (decoder.decodeObjectArrayForKey("a") as [PostboxCoding]).compactMap { $0 as? MessageAttribute }
        self.media = (decoder.decodeObjectArrayForKey("m") as [PostboxCoding]).compactMap { $0 as? Media }
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.timestamp, forKey: "t")
        encoder.encodeString(self.text, forKey: "s")
        encoder.encodeGenericObjectArray(self.attributes, forKey: "a")
        encoder.encodeGenericObjectArray(self.media, forKey: "m")
    }
}

public final class ArielgramMessageHistoryAttribute: MessageAttribute, MessageMediaHistoryAttribute {
    /// Oldest first. The current message is the final version, so it is stored
    /// only once, in the ordinary message record.
    public let versions: [ArielgramMessageVersion]
    public let deletedAt: Int32?

    public var mediaForStorage: [Media] {
        return self.versions.flatMap { version -> [Media] in
            if !version.media.isEmpty { return version.media }
            return version.attributes.compactMap { $0 as? RichTextMessageAttribute }.first?.instantPage.allMedia() ?? []
        }
    }

    // Keep old emoji, mention, reply and story references in Postbox's ordinary
    // associated-data lifecycle so complete historical bubbles can resolve them.
    public var associatedMediaIds: [MediaId] {
        return Array(Set(self.versions.flatMap { $0.attributes.flatMap { $0.associatedMediaIds } }))
    }
    public var associatedPeerIds: [PeerId] {
        return Array(Set(self.versions.flatMap { $0.attributes.flatMap { $0.associatedPeerIds } }))
    }
    public var associatedMessageIds: [MessageId] {
        return Array(Set(self.versions.flatMap { $0.attributes.flatMap { $0.associatedMessageIds } }))
    }
    public var associatedStoryIds: [StoryId] {
        return Array(Set(self.versions.flatMap { $0.attributes.flatMap { $0.associatedStoryIds } }))
    }

    public init(versions: [ArielgramMessageVersion], deletedAt: Int32?) {
        self.versions = versions
        self.deletedAt = deletedAt
    }

    public init(decoder: PostboxDecoder) {
        self.versions = decoder.decodeObjectArrayWithDecoderForKey("v")
        self.deletedAt = decoder.decodeOptionalInt32ForKey("d")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectArray(self.versions, forKey: "v")
        if let deletedAt = self.deletedAt {
            encoder.encodeInt32(deletedAt, forKey: "d")
        } else {
            encoder.encodeNil(forKey: "d")
        }
    }
}

/// Presentation-only metadata on synthetic History messages, never written to
/// the account database or sent to Telegram.
public final class ArielgramHistoryDisplayAttribute: MessageAttribute {
    public let sourceMessageId: MessageId?
    public let previousText: String?
    public let previousEntities: [MessageTextEntity]
    public let mediaEdited: Bool

    public init(sourceMessageId: MessageId, previousText: String?, previousEntities: [MessageTextEntity], mediaEdited: Bool) {
        self.sourceMessageId = sourceMessageId
        self.previousText = previousText
        self.previousEntities = previousEntities
        self.mediaEdited = mediaEdited
    }

    public init(decoder: PostboxDecoder) {
        self.sourceMessageId = nil
        self.previousText = nil
        self.previousEntities = []
        self.mediaEdited = false
    }

    public func encode(_ encoder: PostboxEncoder) {
    }
}

public extension Message {
    var arielgramHistory: ArielgramMessageHistoryAttribute? {
        return self.attributes.compactMap { $0 as? ArielgramMessageHistoryAttribute }.first
    }

    var arielgramMediaForStorage: [Media] {
        var seen = Set<MediaId>()
        return (self.effectiveMedia + self.attributes.compactMap { $0 as? MessageMediaHistoryAttribute }.flatMap { $0.mediaForStorage }).filter { media in
            guard let id = media.id else { return true }
            return seen.insert(id).inserted
        }
    }
}

public func arielgramMediaContentEqual(_ lhs: [Media], _ rhs: [Media]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (left, right) in zip(lhs, rhs) {
        // Resource references, thumbnails and fetched webpage/poll metadata may
        // refresh without a user editing the attachment.
        if let leftId = left.id, let rightId = right.id {
            if leftId != rightId { return false }
        } else if !left.isEqual(to: right) {
            return false
        }
    }
    return true
}

private func arielgramIsTimedMessage(_ attributes: [MessageAttribute]) -> Bool {
    return attributes.contains { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }
}

public func arielgramPreserveMessageHistory(_ previous: Message, _ updated: StoreMessage) -> StoreMessage {
    guard previous.id.namespace == Namespaces.Message.Cloud,
          previous.id.peerId.namespace != Namespaces.Peer.SecretChat,
          !previous.media.contains(where: { $0 is TelegramMediaAction }),
          !arielgramIsTimedMessage(previous.attributes),
          !arielgramIsTimedMessage(updated.attributes) else {
        return updated
    }
    let oldHistory = previous.arielgramHistory
    let suppliedHistory = updated.attributes.compactMap { $0 as? ArielgramMessageHistoryAttribute }.first
    var versions = oldHistory?.versions ?? []
    let oldEntities = previous.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? []
    let newEntities = updated.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? []
    let oldEditDate = previous.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first
    let newEditDate = updated.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first
    let sameIdMediaEdit = newEditDate != nil && oldEditDate != newEditDate && previous.media.count == updated.media.count && zip(previous.media, updated.media).contains(where: { !$0.0.isEqual(to: $0.1) })
    let oldRichText = previous.attributes.compactMap { $0 as? RichTextMessageAttribute }.first
    let newRichText = updated.attributes.compactMap { $0 as? RichTextMessageAttribute }.first
    let richTextChanged = oldRichText?.instantPage != newRichText?.instantPage
    let contentChanged = richTextChanged || previous.text != updated.text || oldEntities != newEntities || !arielgramMediaContentEqual(previous.media, updated.media) || sameIdMediaEdit
    if contentChanged && oldHistory?.deletedAt == nil {
        versions.append(ArielgramMessageVersion(message: previous))
    }
    let deletedAt = oldHistory?.deletedAt ?? suppliedHistory?.deletedAt
    if versions.isEmpty && deletedAt == nil {
        return updated
    }
    var attributes = updated.attributes.filter { !($0 is ArielgramMessageHistoryAttribute) }
    attributes.append(ArielgramMessageHistoryAttribute(versions: versions, deletedAt: deletedAt))
    // A stale history fetch must not revive or replace a remotely deleted copy.
    if oldHistory?.deletedAt != nil && contentChanged {
        return StoreMessage(id: previous.id, customStableId: previous.stableId, globallyUniqueId: previous.globallyUniqueId, groupingKey: previous.groupingKey, threadId: previous.threadId, timestamp: previous.timestamp, flags: StoreMessageFlags(previous.flags), tags: previous.tags, globalTags: previous.globalTags, localTags: previous.localTags, forwardInfo: previous.forwardInfo.map(StoreMessageForwardInfo.init), authorId: previous.author?.id, text: previous.text, attributes: previous.attributes, media: previous.media)
    }
    return updated.withUpdatedAttributes(attributes)
}

/// Returns ids that still need physical deletion (unseen, local or secret-chat
/// messages). Retained messages keep their normal id and position in the chat.
func arielgramMarkMessagesDeleted(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    var remove: [MessageId] = []
    let now = Int32(Date().timeIntervalSince1970)
    for id in ids {
        guard id.namespace == Namespaces.Message.Cloud,
              id.peerId.namespace != Namespaces.Peer.SecretChat,
              let message = transaction.getMessage(id),
              !message.media.contains(where: { $0 is TelegramMediaAction }),
              !arielgramIsTimedMessage(message.attributes) else {
            remove.append(id)
            continue
        }
        if message.arielgramHistory?.deletedAt != nil { continue }
        transaction.updateMessage(id, update: { message in
            var attributes = message.attributes.filter { !($0 is ArielgramMessageHistoryAttribute) }
            attributes.append(ArielgramMessageHistoryAttribute(versions: message.arielgramHistory?.versions ?? [], deletedAt: now))
            return .update(StoreMessage(id: message.id, customStableId: message.stableId, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags.subtracting([.unseenPersonalMessage, .unseenReaction, .pinned]), globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.map(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media))
        })
    }
    return remove
}

/// Local-only upload hint for copying protected content as a new message.
/// No deletion/edit history is copied into the outgoing message.
public final class ArielgramReuploadCopiedMediaAttribute: MessageAttribute {
    public init() {}
    public init(decoder: PostboxDecoder) {}
    public func encode(_ encoder: PostboxEncoder) {}
}
