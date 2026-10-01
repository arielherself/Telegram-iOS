import Foundation
import Postbox

/// Local service-message metadata. Images participate in the same media index
/// and cache cleanup as archived message media; this is not a second database.
public final class ArielgramPeerProfileChangeAttribute: MessageAttribute, MessageMediaHistoryAttribute {
    public enum Kind: Int32 {
        case name = 0
        case avatar = 1
    }

    public let kind: Kind
    public let peerId: PeerId
    public let previousName: String
    public let updatedName: String
    public let previousImage: TelegramMediaImage?
    public let updatedImage: TelegramMediaImage?
    public let peerReference: PeerReference?

    public var associatedPeerIds: [PeerId] { return [self.peerId] }
    public var mediaForStorage: [Media] { return [self.previousImage, self.updatedImage].compactMap { $0 } }

    public init(kind: Kind, peerId: PeerId, previousName: String, updatedName: String, previousImage: TelegramMediaImage?, updatedImage: TelegramMediaImage?, peerReference: PeerReference?) {
        self.kind = kind
        self.peerId = peerId
        self.previousName = previousName
        self.updatedName = updatedName
        self.previousImage = previousImage
        self.updatedImage = updatedImage
        self.peerReference = peerReference
    }

    public init(decoder: PostboxDecoder) {
        self.kind = Kind(rawValue: decoder.decodeInt32ForKey("k", orElse: 0)) ?? .name
        self.peerId = PeerId(decoder.decodeInt64ForKey("p", orElse: 0))
        self.previousName = decoder.decodeStringForKey("o", orElse: "")
        self.updatedName = decoder.decodeStringForKey("n", orElse: "")
        self.previousImage = decoder.decodeObjectForKey("oi") as? TelegramMediaImage
        self.updatedImage = decoder.decodeObjectForKey("ni") as? TelegramMediaImage
        self.peerReference = decoder.decodeObjectForKey("r") as? PeerReference
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.kind.rawValue, forKey: "k")
        encoder.encodeInt64(self.peerId.toInt64(), forKey: "p")
        encoder.encodeString(self.previousName, forKey: "o")
        encoder.encodeString(self.updatedName, forKey: "n")
        if let image = self.previousImage { encoder.encodeObject(image, forKey: "oi") } else { encoder.encodeNil(forKey: "oi") }
        if let image = self.updatedImage { encoder.encodeObject(image, forKey: "ni") } else { encoder.encodeNil(forKey: "ni") }
        if let reference = self.peerReference { encoder.encodeObject(reference, forKey: "r") } else { encoder.encodeNil(forKey: "r") }
    }

    public func text(languageCode: String) -> String {
        if languageCode.lowercased().hasPrefix("zh") {
            switch self.kind {
            case .name: return "“\(self.previousName)” 将名字改为 “\(self.updatedName)”"
            case .avatar: return "\(self.updatedName) 更换了头像"
            }
        } else {
            switch self.kind {
            case .name: return "“\(self.previousName)” changed their name to “\(self.updatedName)”"
            case .avatar: return "\(self.updatedName) changed their photo"
            }
        }
    }
}

/// Only membership learned through the normal member-list requests is cached.
/// An explicit nonmember overrides older messages from that user.
private struct ArielgramObservedGroupMembers: Codable {
    private struct Observation: Codable {
        let peerId: Int64
        let timestamp: Int32
    }

    private enum CodingKeys: String, CodingKey {
        case members, nonmembers, observations
    }

    var members: Set<Int64> = []
    var nonmembers: Set<Int64> = []
    var observedAt: [Int64: Int32] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.members = try container.decode(Set<Int64>.self, forKey: .members)
        self.nonmembers = try container.decode(Set<Int64>.self, forKey: .nonmembers)
        let observations = try container.decodeIfPresent([Observation].self, forKey: .observations) ?? []
        self.observedAt = Dictionary(observations.map { ($0.peerId, $0.timestamp) }, uniquingKeysWith: { max($0, $1) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.members, forKey: .members)
        try container.encode(self.nonmembers, forKey: .nonmembers)
        // The Postbox adapter supports homogeneous object arrays, but neither
        // mixed numeric-key dictionaries nor generic primitive dictionary values.
        let observations = self.observedAt.keys.sorted().map { Observation(peerId: $0, timestamp: self.observedAt[$0]!) }
        try container.encode(observations, forKey: .observations)
    }
}

private func arielgramMembersCacheId(_ groupId: PeerId) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 8)
    key.setInt64(0, value: groupId.toInt64())
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.arielgramObservedGroupMembers, key: key)
}

func arielgramObserveGroupParticipants(transaction: Transaction, groupId: PeerId, participants: [ChannelParticipant]) {
    let id = arielgramMembersCacheId(groupId)
    var cached = transaction.retrieveItemCacheEntry(id: id)?.get(ArielgramObservedGroupMembers.self) ?? ArielgramObservedGroupMembers()
    var observedAt = cached.observedAt
    let timestamp = Int32(Date().timeIntervalSince1970)
    for participant in participants {
        let isMember: Bool
        switch participant {
        case .creator: isMember = true
        case let .member(_, invitedAt, _, banInfo, _, _): isMember = banInfo?.isMember ?? (invitedAt != 0)
        }
        let peerId = participant.peerId.toInt64()
        observedAt[peerId] = timestamp
        if isMember {
            cached.members.insert(peerId)
            cached.nonmembers.remove(peerId)
        } else {
            cached.members.remove(peerId)
            cached.nonmembers.insert(peerId)
        }
    }
    cached.observedAt = observedAt
    if let entry = CodableEntry(cached) { transaction.putItemCacheEntry(id: id, entry: entry) }
}

private func arielgramProfile(_ peer: Peer) -> (name: String, photo: [TelegramMediaImageRepresentation])? {
    if let peer = peer as? TelegramUser {
        // Empty users are not a baseline for an observed change.
        let name = [peer.firstName, peer.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : (name, peer.photo)
    } else if let peer = peer as? TelegramGroup {
        return peer.title.isEmpty ? nil : (peer.title, peer.photo)
    } else if let peer = peer as? TelegramChannel {
        return peer.title.isEmpty ? nil : (peer.title, peer.photo)
    }
    return nil
}

private func arielgramAvatarIdentity(_ photo: [TelegramMediaImageRepresentation]) -> String? {
    guard let representation = photo.first else { return nil }
    if let resource = representation.resource as? CloudPeerPhotoSizeMediaResource, let id = resource.photoId {
        return "photo:\(id)"
    }
    return representation.resource.id.stringRepresentation
}

private func arielgramProfileImage(_ photo: [TelegramMediaImageRepresentation]) -> TelegramMediaImage? {
    guard !photo.isEmpty else { return nil }
    let id = (photo.first?.resource as? CloudPeerPhotoSizeMediaResource)?.photoId ?? Int64.random(in: 1 ... Int64.max)
    return TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id), representations: photo, immediateThumbnailData: photo.first?.immediateThumbnailData, reference: nil, partialReference: nil, flags: [])
}

private func arielgramIsGroupMember(transaction: Transaction, userId: PeerId, group: Peer) -> Bool {
    if let data = transaction.getPeerCachedData(peerId: group.id) as? CachedGroupData, let participants = data.participants {
        return participants.participants.contains { $0.peerId == userId }
    }
    if let cached = transaction.retrieveItemCacheEntry(id: arielgramMembersCacheId(group.id))?.get(ArielgramObservedGroupMembers.self) {
        if cached.nonmembers.contains(userId.toInt64()) {
            guard let timestamp = cached.observedAt[userId.toInt64()] else { return false }
            return transaction.hasMessageWithAuthor(peerId: group.id, namespace: Namespaces.Message.Cloud, authorId: userId, afterTimestamp: timestamp)
        }
        if cached.members.contains(userId.toInt64()) { return true }
    }
    // Existing history provides a baseline for members observed before this
    // feature was installed. No participant query or profile refresh is made.
    return transaction.hasMessageWithAuthor(peerId: group.id, namespace: Namespaces.Message.Cloud, authorId: userId)
}

func arielgramRecordPeerProfileChange(transaction: Transaction, previous: Peer, updated: Peer) {
    guard previous.id == updated.id,
          let old = arielgramProfile(previous), let new = arielgramProfile(updated) else { return }
    let nameChanged = old.name != new.name
    let photoChanged = arielgramAvatarIdentity(old.photo) != arielgramAvatarIdentity(new.photo)
    guard nameChanged || photoChanged else { return }

    var destinations = Set<PeerId>()
    if transaction.getPeerChatListIndex(updated.id) != nil || transaction.getTopPeerMessageIndex(peerId: updated.id) != nil || transaction.getPeerChatInterfaceState(updated.id) != nil {
        destinations.insert(updated.id)
    }
    if updated is TelegramUser {
        for groupId in transaction.chatListGetAllPeerIds() {
            guard let group = transaction.getPeer(groupId) else { continue }
            if let group = group as? TelegramGroup {
                guard group.membership == .Member, !group.flags.contains(.deactivated) else { continue }
            } else if let group = group as? TelegramChannel {
                guard group.participationStatus == .member, case .group = group.info else { continue }
            } else {
                continue
            }
            if arielgramIsGroupMember(transaction: transaction, userId: updated.id, group: group) { destinations.insert(groupId) }
        }
    }
    guard !destinations.isEmpty else { return }
    var changes: [ArielgramPeerProfileChangeAttribute] = []
    if nameChanged {
        changes.append(ArielgramPeerProfileChangeAttribute(kind: .name, peerId: updated.id, previousName: old.name, updatedName: new.name, previousImage: nil, updatedImage: nil, peerReference: nil))
    }
    if photoChanged {
        changes.append(ArielgramPeerProfileChangeAttribute(kind: .avatar, peerId: updated.id, previousName: old.name, updatedName: new.name, previousImage: arielgramProfileImage(old.photo), updatedImage: arielgramProfileImage(new.photo), peerReference: PeerReference(updated)))
    }
    let timestamp = Int32(Date().timeIntervalSince1970)
    for destination in destinations.sorted() {
        for change in changes {
            var existingService: Message?
            transaction.scanTopMessages(peerId: destination, namespace: Namespaces.Message.Cloud, limit: 10) { message in
                if existingService == nil, abs(Int64(message.timestamp) - Int64(timestamp)) <= 60,
                   message.attributes.allSatisfy({ !($0 is ArielgramPeerProfileChangeAttribute) }),
                   arielgramServiceMatches(message.media, change: change, chatId: destination) {
                    existingService = message
                }
                return true
            }
            if let existingService {
                transaction.updateMessage(existingService.id, update: { message in
                    return .update(arielgramCopyMessage(message, attributes: message.attributes + [change]))
                })
                continue
            }
            let text = change.text(languageCode: "en")
            let message = StoreMessage(peerId: destination, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: timestamp, flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: text, attributes: [change], media: [TelegramMediaAction(action: .customText(text: text, entities: [], additionalAttributes: nil))])
            let _ = transaction.addMessages([message], location: .Random)
        }
    }
}

private func arielgramServiceMatches(_ media: [Media], change: ArielgramPeerProfileChangeAttribute, chatId: PeerId) -> Bool {
    guard change.peerId == chatId else { return false }
    for media in media {
        guard let action = media as? TelegramMediaAction else { continue }
        switch action.action {
        case let .titleUpdated(title):
            return change.kind == .name && title == change.updatedName
        case let .photoUpdated(image):
            return change.kind == .avatar && image?.imageId.id == change.updatedImage?.imageId.id
        default: break
        }
    }
    return false
}

private func arielgramCopyMessage(_ message: Message, attributes: [MessageAttribute]) -> StoreMessage {
    let forwardInfo = message.forwardInfo.map { info in
        return StoreMessageForwardInfo(authorId: info.author?.id, sourceId: info.source?.id, sourceMessageId: info.sourceMessageId, date: info.date, authorSignature: info.authorSignature, psaType: info.psaType, flags: info.flags)
    }
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: forwardInfo, authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media)
}

/// Merge a local observation into an arriving official group/channel service
/// message, rather than showing two notifications for the same observed change.
func arielgramProcessProfileServiceMessage(transaction: Transaction, message: StoreMessage) -> StoreMessage {
    guard message.id.namespace == Namespaces.Message.Cloud,
          let action = message.media.compactMap({ $0 as? TelegramMediaAction }).first else { return message }
    var membership: [(PeerId, Bool)] = []
    switch action.action {
    case let .addedMembers(ids): membership = ids.map { ($0, true) }
    case let .removedMembers(ids): membership = ids.map { ($0, false) }
    case .joinedByLink, .joinedByRequest:
        if let author = message.authorId { membership = [(author, true)] }
    default: break
    }
    if !membership.isEmpty {
        let id = arielgramMembersCacheId(message.id.peerId)
        var cached = transaction.retrieveItemCacheEntry(id: id)?.get(ArielgramObservedGroupMembers.self) ?? ArielgramObservedGroupMembers()
        var observedAt = cached.observedAt
        for (peerId, isMember) in membership {
            if let timestamp = observedAt[peerId.toInt64()], timestamp > message.timestamp { continue }
            observedAt[peerId.toInt64()] = message.timestamp
            if isMember { cached.members.insert(peerId.toInt64()); cached.nonmembers.remove(peerId.toInt64()) }
            else { cached.members.remove(peerId.toInt64()); cached.nonmembers.insert(peerId.toInt64()) }
        }
        cached.observedAt = observedAt
        if let entry = CodableEntry(cached) { transaction.putItemCacheEntry(id: id, entry: entry) }
    }
    switch action.action {
    case .titleUpdated, .photoUpdated: break
    default: return message
    }
    guard !message.attributes.contains(where: { $0 is ArielgramPeerProfileChangeAttribute }) else { return message }
    var localObservation: (MessageId, ArielgramPeerProfileChangeAttribute)?
    transaction.scanTopMessages(peerId: message.id.peerId, namespace: Namespaces.Message.Local, limit: 10) { local in
        if localObservation == nil, abs(Int64(local.timestamp) - Int64(message.timestamp)) <= 60,
           let change = local.attributes.compactMap({ $0 as? ArielgramPeerProfileChangeAttribute }).first,
           arielgramServiceMatches(message.media, change: change, chatId: message.id.peerId) {
            localObservation = (local.id, change)
        }
        return true
    }
    guard let (id, change) = localObservation, case let .Id(messageId) = message.id else { return message }
    transaction.deleteMessages([id], forEachMedia: nil)
    return StoreMessage(id: messageId, customStableId: message.customStableId, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: message.flags, tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo, authorId: message.authorId, text: message.text, attributes: message.attributes + [change], media: message.media)
}
