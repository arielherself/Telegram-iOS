import Foundation
import Postbox

declareEncodable(ArielgramMessageHistoryAttribute.self, f: { ArielgramMessageHistoryAttribute(decoder: $0) })
declareEncodable(ArielgramMessageVersion.self, f: { ArielgramMessageVersion(decoder: $0) })
declareEncodable(TextEntitiesMessageAttribute.self, f: { TextEntitiesMessageAttribute(decoder: $0) })
declareEncodable(EditedMessageAttribute.self, f: { EditedMessageAttribute(decoder: $0) })
declareEncodable(TestMedia.self, f: { TestMedia(decoder: $0) })

let id = MessageId(peerId: PeerId(namespace: 0), namespace: 0, id: 1)
let original = Message(id: id, text: "original", attributes: [TextEntitiesMessageAttribute(entities: [MessageTextEntity(value: 1)])], media: [TestMedia(id: 1)])
func edit(_ old: Message, _ text: String, _ media: [Media]? = nil, attributes: [MessageAttribute]? = nil) -> Message {
    return Message(arielgramPreserveMessageHistory(old, StoreMessage(Message(id: old.id, text: text, attributes: attributes ?? old.attributes, media: media ?? old.media))))
}
let first = edit(original, "first")
let second = edit(first, "second", [TestMedia(id: 2)])
let reverted = edit(second, "original")
precondition(reverted.arielgramHistory!.versions.map { $0.text } == ["original", "first", "second"])
let repeated = edit(reverted, "original")
precondition(repeated.arielgramHistory!.versions.count == 3, "Duplicate sync must not create a version")
let metadataOnly = edit(original, original.text, [TestMedia(id: 1, payload: 99)])
precondition(metadataOnly.arielgramHistory == nil, "Reference refresh must not look like a media edit")
let sameIdEdit = edit(original, original.text, [TestMedia(id: 1, payload: 99)], attributes: original.attributes + [EditedMessageAttribute(date: 11)])
precondition(sameIdEdit.arielgramHistory!.versions.count == 1)
let formatted = edit(original, original.text, attributes: [TextEntitiesMessageAttribute(entities: [MessageTextEntity(value: 2)])])
precondition(formatted.arielgramHistory!.versions.count == 1, "Formatting edits also need history")

let encoder = PostboxEncoder()
encoder.encodeRootObject(reverted.arielgramHistory!)
let data = encoder.makeData()
let decoded = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as! ArielgramMessageHistoryAttribute
precondition(decoded.versions.map { $0.text } == ["original", "first", "second"])
precondition(decoded.versions[0].media[0].id == MediaId(id: 1))
precondition((decoded.versions[0].attributes[0] as? TextEntitiesMessageAttribute)?.entities == [MessageTextEntity(value: 1)])
precondition(decoded.versions.allSatisfy { $0.attributes.allSatisfy { !($0 is ArielgramMessageHistoryAttribute) } }, "No recursive archives")

let transaction = Transaction([id: reverted])
precondition(arielgramMarkMessagesDeleted(transaction: transaction, ids: [id]).isEmpty)
let deleted = transaction.getMessage(id)!
precondition(deleted.text == "original" && deleted.arielgramHistory!.versions.count == 3)
let deletionTime = deleted.arielgramHistory!.deletedAt!
let deletedEncoder = PostboxEncoder()
deletedEncoder.encodeRootObject(deleted.arielgramHistory!)
let restoredDeletion = PostboxDecoder(buffer: MemoryBuffer(data: deletedEncoder.makeData())).decodeRootObject() as! ArielgramMessageHistoryAttribute
precondition(restoredDeletion.deletedAt == deletionTime && restoredDeletion.versions.count == 3)
precondition(arielgramMarkMessagesDeleted(transaction: transaction, ids: [id]).isEmpty)
precondition(transaction.getMessage(id)!.arielgramHistory!.deletedAt == deletionTime)
precondition(edit(deleted, "stale server copy").text == "original", "Deleted copies must not be resurrected")
let unseen = MessageId(peerId: id.peerId, namespace: 0, id: 99)
precondition(arielgramMarkMessagesDeleted(transaction: transaction, ids: [unseen]) == [unseen])
let secretId = MessageId(peerId: PeerId(namespace: 3), namespace: 0, id: 1)
let secret = Message(id: secretId, text: "secret")
precondition(edit(secret, "changed").arielgramHistory == nil)
let secretTransaction = Transaction([secretId: secret])
precondition(arielgramMarkMessagesDeleted(transaction: secretTransaction, ids: [secretId]) == [secretId])
precondition(Set(reverted.arielgramMediaForStorage.compactMap { $0.id }).count == 2, "Historical media remains visible to ordinary storage cleanup, without duplicates")
print("History policy and real Postbox codec round-trip passed.")

for timedAttribute in [AutoremoveTimeoutMessageAttribute(), AutoclearTimeoutMessageAttribute()] {
    let timed = Message(id: id, text: "expires", attributes: [timedAttribute])
    precondition(edit(timed, "edited expires").arielgramHistory == nil)
    precondition(edit(original, "now expires", attributes: [timedAttribute]).arielgramHistory == nil)
    let timedTransaction = Transaction([id: timed])
    precondition(arielgramMarkMessagesDeleted(transaction: timedTransaction, ids: [id]) == [id])
    precondition(timedTransaction.getMessage(id)!.arielgramHistory == nil)
}

let referenced = Message(id: id, text: "emoji", attributes: [TestReferencesAttribute()])
let changedReferences = edit(referenced, "changed", attributes: [])
precondition(changedReferences.arielgramHistory!.associatedMediaIds == [MediaId(id: 55)])
precondition(changedReferences.arielgramHistory!.associatedPeerIds == [PeerId(namespace: 42)])
precondition(changedReferences.arielgramHistory!.associatedMessageIds.count == 1)
precondition(changedReferences.arielgramHistory!.associatedStoryIds.count == 1)
let rich = Message(id: id, text: "", attributes: [RichTextMessageAttribute(80)])
let richEdited = edit(rich, "", attributes: [RichTextMessageAttribute(81)])
precondition(richEdited.arielgramHistory!.versions.count == 1)
precondition(richEdited.arielgramHistory!.mediaForStorage.first?.id == MediaId(id: 80))
