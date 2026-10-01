import Foundation
var assertions = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) { assertions += 1; precondition(value(), label) }
let userId = PeerId(value: 10)
let groupId = PeerId(namespace: 1, value: 20)
let channelId = PeerId(namespace: 2, value: 30)
let broadcastId = PeerId(namespace: 2, value: 40)
func photo(_ id: Int64, resource: String? = nil, thumb: Data? = nil) -> [TelegramMediaImageRepresentation] {
    [TelegramMediaImageRepresentation(resource: CloudPeerPhotoSizeMediaResource(id, resourceId: resource ?? "photo-\(id)"), immediateThumbnailData: thumb)]
}
func makeTransaction() -> Transaction {
    let tx = Transaction(); tx.peers[userId] = TelegramUser(userId, name: "Alice"); tx.chats.insert(userId); return tx
}
func changes(_ tx: Transaction) -> [ArielgramPeerProfileChangeAttribute] { tx.messages.values.flatMap { $0.attributes.compactMap { $0 as? ArielgramPeerProfileChangeAttribute } } }
func native(_ groupId: PeerId, action: TelegramMediaActionType, timestamp: Int32 = Int32(Date().timeIntervalSince1970), id: Int32 = 100) -> StoreMessage {
    StoreMessage(id: MessageId(peerId: groupId, namespace: 0, id: id), customStableId: 42, globallyUniqueId: 88, groupingKey: nil, threadId: nil, timestamp: timestamp, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: userId, text: "", attributes: [], media: [TelegramMediaAction(action: action)])
}
// Incomplete peers and refreshes of the same photo are not profile changes.
do {
    let tx = makeTransaction()
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: nil), updated: TelegramUser(userId, name: "Alice", photo: photo(1)))
    expect(tx.messages.isEmpty, "first usable profile is a baseline")
    tx.chats.insert(groupId); tx.peers[groupId] = TelegramGroup(groupId, title: "")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramGroup(groupId, title: ""), updated: TelegramGroup(groupId, title: "Group"))
    expect(tx.messages.isEmpty, "first usable group title is a baseline")

    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice", photo: photo(1, resource: "dc1-small")), updated: TelegramUser(userId, name: "Alice", photo: photo(1, resource: "dc2-small")))
    expect(tx.messages.isEmpty, "same photo id with refreshed resource is unchanged")
}
// Name and photo observations are separate immutable local messages, without
// incoming/unsent/top-index flags or Telegram outgoing attributes.
do {
    let tx = makeTransaction()
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice", photo: photo(1, thumb: Data([1, 2]))), updated: TelegramUser(userId, name: "Bob", photo: photo(2)))
    expect(tx.messages.count == 2, "simultaneous changes produce two records")
    expect(tx.messages.values.allSatisfy { $0.flags.rawValue == 0 }, "no incoming, unsent, or top-index flags")
    expect(tx.messages.values.allSatisfy { $0.id.namespace == 1 }, "observations stay in local namespace")
    let name = changes(tx).first { $0.kind == .name }!
    let avatar = changes(tx).first { $0.kind == .avatar }!
    expect(name.previousName == "Alice" && name.updatedName == "Bob", "both names are captured")
    expect(avatar.previousImage?.imageId.id == 1 && avatar.updatedImage?.imageId.id == 2, "both photos are captured")
    expect(avatar.mediaForStorage.count == 2 && name.mediaForStorage.isEmpty, "only avatar snapshots enter media accounting")
    expect(avatar.associatedPeerIds == [userId], "subject is associated with record")
    expect(name.text(languageCode: "zh-Hans").contains("Alice") && name.text(languageCode: "en").contains("Bob"), "localized prompts retain both names")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Bob", photo: photo(2)), updated: TelegramUser(userId, name: "Bob", photo: photo(2)))
    expect(tx.messages.count == 2, "unchanged refresh adds no duplicate")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Bob", photo: photo(2)), updated: TelegramUser(userId, name: "Bob"))
    let removal = changes(tx).first { $0.kind == .avatar && $0.updatedImage == nil }!
    expect(removal.previousImage != nil && removal.mediaForStorage.count == 1, "photo removal retains previous photo")
    declareEncodable(TelegramMediaImage.self, f: { TelegramMediaImage(decoder: $0) })
    declareEncodable(PeerReference.self, f: { PeerReference(decoder: $0) })
    declareEncodable(ArielgramPeerProfileChangeAttribute.self, f: { ArielgramPeerProfileChangeAttribute(decoder: $0) })
    let encoder = PostboxEncoder(); encoder.encodeRootObject(avatar)
    let decoded = PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as! ArielgramPeerProfileChangeAttribute
    expect(decoded.kind == .avatar && decoded.peerId == userId, "kind and peer survive real Postbox codec")
    expect(decoded.previousName == "Alice" && decoded.updatedName == "Bob", "names survive codec")
    expect(decoded.previousImage?.imageId.id == 1 && decoded.updatedImage?.imageId.id == 2, "photo ids survive codec")
    expect(decoded.previousImage?.immediateThumbnailData == Data([1, 2]), "embedded thumbnail survives codec")
    expect(decoded.peerReference?.value == userId.toInt64(), "avatar reference survives codec")
}
// Basic-group rosters and normally loaded supergroup member lists also identify
// members who have never sent a message. Broadcast subscribers are excluded.
do {
    let tx = makeTransaction()
    tx.chats.formUnion([groupId, channelId, broadcastId])
    tx.peers[groupId] = TelegramGroup(groupId, title: "Group")
    tx.peers[channelId] = TelegramChannel(channelId, title: "Supergroup")
    tx.peers[broadcastId] = TelegramChannel(broadcastId, title: "Broadcast", info: .broadcast)
    tx.cachedGroups[groupId] = CachedGroupData(participants: CachedGroupParticipants(participants: [GroupParticipant(peerId: userId)]))
    arielgramObserveGroupParticipants(transaction: tx, groupId: channelId, participants: [.member(userId, 123, nil, nil, nil, nil)])
    arielgramObserveGroupParticipants(transaction: tx, groupId: broadcastId, participants: [.creator(userId)])
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice"), updated: TelegramUser(userId, name: "Bob"))
    expect(Set(tx.messages.keys.map { $0.peerId }) == [userId, groupId, channelId], "member change goes to private chat and both groups")
    expect(tx.messages.keys.allSatisfy { $0.peerId != broadcastId }, "subscriber profile is not posted in broadcast")
    arielgramObserveGroupParticipants(transaction: tx, groupId: channelId, participants: [.member(userId, 123, nil, BanInfo(isMember: false), nil, nil)])
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Bob"), updated: TelegramUser(userId, name: "Carol"))
    expect(tx.messages.values.filter { $0.id.peerId == channelId }.count == 1, "explicit former member is excluded")
}
// Previously cached authors supply membership without a network request, while
// normal removal service messages override that historical inference.
do {
    let tx = makeTransaction(); tx.chats.insert(channelId); tx.peers[channelId] = TelegramChannel(channelId, title: "Supergroup")
    let authored = native(channelId, action: .customText(text: "message", entities: [], additionalAttributes: nil), timestamp: 1)
    let _ = tx.addMessages([authored], location: .Random)
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice"), updated: TelegramUser(userId, name: "Bob"))
    expect(changes(tx).filter { $0.updatedName == "Bob" }.count == 2, "existing group author is recognized")
    let _ = arielgramProcessProfileServiceMessage(transaction: tx, message: native(channelId, action: .removedMembers(peerIds: [userId])))
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Bob"), updated: TelegramUser(userId, name: "Carol"))
    expect(tx.messages.values.filter { $0.id.peerId == channelId && $0.attributes.contains { ($0 as? ArielgramPeerProfileChangeAttribute)?.updatedName == "Carol" } }.isEmpty, "leave update overrides prior author")
}
// Official service messages arriving after a peer update consume the local
// observation. Existing official messages receive the same snapshot in place.
do {
    let tx = Transaction(); tx.chats.insert(groupId); tx.peers[groupId] = TelegramGroup(groupId, title: "Old")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramGroup(groupId, title: "Old"), updated: TelegramGroup(groupId, title: "New"))
    expect(tx.messages.count == 1, "group change creates observation")
    let official = native(groupId, action: .titleUpdated(title: "New"))
    let merged = arielgramProcessProfileServiceMessage(transaction: tx, message: official)
    expect(tx.messages.isEmpty, "matching local observation is consumed")
    expect((merged.attributes.first as? ArielgramPeerProfileChangeAttribute)?.previousName == "Old", "official message receives previous name")
    expect(merged.flags == official.flags && merged.authorId == official.authorId && merged.timestamp == official.timestamp && merged.customStableId == 42, "official metadata is preserved")
    let _ = tx.addMessages([merged], location: .Random)
    expect(tx.messages.count == 1, "only one service message remains")
}
do {
    let tx = Transaction(); tx.chats.insert(channelId); tx.peers[channelId] = TelegramChannel(channelId, title: "Old")
    let _ = tx.addMessages([native(channelId, action: .titleUpdated(title: "New"))], location: .Random)
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramChannel(channelId, title: "Old"), updated: TelegramChannel(channelId, title: "New"))
    expect(tx.messages.count == 1 && tx.messages.keys.first?.namespace == 0, "existing official message updated without local duplicate")
    expect(changes(tx).first?.previousName == "Old", "existing native message retains baseline")
}
do {
    let tx = Transaction(); tx.chats.insert(groupId); tx.peers[groupId] = TelegramGroup(groupId, title: "Group")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramGroup(groupId, title: "Group", photo: photo(1)), updated: TelegramGroup(groupId, title: "Group", photo: photo(2)))
    let image = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 2), representations: photo(2), immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    let merged = arielgramProcessProfileServiceMessage(transaction: tx, message: native(groupId, action: .photoUpdated(image: image)))
    expect(tx.messages.isEmpty && (merged.attributes.first as? ArielgramPeerProfileChangeAttribute)?.kind == .avatar, "official photo event merges by photo id")
    expect((merged.attributes.first as? ArielgramPeerProfileChangeAttribute)?.previousImage?.imageId.id == 1, "old image remains in merged event")
}
do {
    let tx = Transaction(); tx.chats.insert(groupId); tx.peers[groupId] = TelegramGroup(groupId, title: "Old")
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramGroup(groupId, title: "Old"), updated: TelegramGroup(groupId, title: "New"))
    let historical = arielgramProcessProfileServiceMessage(transaction: tx, message: native(groupId, action: .titleUpdated(title: "New"), timestamp: 1))
    expect(tx.messages.count == 1 && historical.attributes.isEmpty, "old history does not consume new observation")
}
// Loading archived join/leave messages must not overturn a freshly received
// member list, and newer authored messages can supersede an older departure.
// Exercise empty/nonempty roster entries using the actual CodableEntry storage
// adapter, including user ids larger than Int32 and persisted departure times.
do {
    let tx = Transaction(); tx.chats.insert(channelId); tx.peers[channelId] = TelegramChannel(channelId, title: "Supergroup")
    arielgramObserveGroupParticipants(transaction: tx, groupId: channelId, participants: [])
    struct LegacyEmptyRoster: Codable {
        let members: Set<Int64> = []
        let nonmembers: Set<Int64> = []
        let observedAt: [Int64: Int32]? = nil
    }
    let cacheId = tx.cache.keys.first!
    tx.cache[cacheId] = CodableEntry(LegacyEmptyRoster())
    let largeUserId = PeerId(value: 5_000_000_000)
    arielgramObserveGroupParticipants(transaction: tx, groupId: channelId, participants: [.creator(largeUserId), .member(userId, 123, nil, nil, nil, nil)])
    let restored = Transaction(); restored.chats = tx.chats; restored.peers = tx.peers
    restored.cache = tx.cache.mapValues { CodableEntry(data: Data($0.data)) }
    arielgramRecordPeerProfileChange(transaction: restored, previous: TelegramUser(largeUserId, name: "Before"), updated: TelegramUser(largeUserId, name: "After"))
    expect(changes(restored).count == 1, "legacy empty cache upgrades and large member id survives real codec/reload")
    let _ = arielgramProcessProfileServiceMessage(transaction: restored, message: native(channelId, action: .removedMembers(peerIds: [largeUserId])))
    arielgramRecordPeerProfileChange(transaction: restored, previous: TelegramUser(largeUserId, name: "After"), updated: TelegramUser(largeUserId, name: "Later"))
    expect(changes(restored).count == 1, "departure timestamp survives real cache codec")
    arielgramObserveGroupParticipants(transaction: restored, groupId: channelId, participants: [.creator(largeUserId)])
    arielgramRecordPeerProfileChange(transaction: restored, previous: TelegramUser(largeUserId, name: "Later"), updated: TelegramUser(largeUserId, name: "Returned"))
    expect(changes(restored).count == 2, "normal member refresh supersedes persisted departure")
}
do {
    let tx = makeTransaction(); tx.chats.insert(channelId); tx.peers[channelId] = TelegramChannel(channelId, title: "Supergroup")
    arielgramObserveGroupParticipants(transaction: tx, groupId: channelId, participants: [.member(userId, 123, nil, nil, nil, nil)])
    let _ = arielgramProcessProfileServiceMessage(transaction: tx, message: native(channelId, action: .removedMembers(peerIds: [userId]), timestamp: 1))
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice"), updated: TelegramUser(userId, name: "Bob"))
    expect(changes(tx).count == 2, "archived leave cannot override fresh member list")
}
do {
    let tx = makeTransaction(); tx.chats.insert(channelId); tx.peers[channelId] = TelegramChannel(channelId, title: "Supergroup")
    let _ = arielgramProcessProfileServiceMessage(transaction: tx, message: native(channelId, action: .removedMembers(peerIds: [userId]), timestamp: 1))
    let _ = tx.addMessages([native(channelId, action: .customText(text: "newer message", entities: [], additionalAttributes: nil), timestamp: 2)], location: .Random)
    arielgramRecordPeerProfileChange(transaction: tx, previous: TelegramUser(userId, name: "Alice"), updated: TelegramUser(userId, name: "Bob"))
    expect(changes(tx).count == 2, "newer authored message supersedes historical departure")
}
print("Passed \(assertions) peer-profile observation, routing, merge and codec checks.")
