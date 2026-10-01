import Foundation
import Postbox

enum Namespaces {
    enum Message { static let Cloud: Int32 = 0 }
    enum Peer { static let SecretChat: Int32 = 3 }
}
final class EditedMessageAttribute: MessageAttribute {
    let date: Int32
    init(date: Int32) { self.date = date }
    init(decoder: PostboxDecoder) { self.date = decoder.decodeInt32ForKey("d", orElse: 0) }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeInt32(self.date, forKey: "d") }
}
public struct MessageTextEntity: Equatable {
    let value: Int32
}
final class TextEntitiesMessageAttribute: MessageAttribute {
    let entities: [MessageTextEntity]
    init(entities: [MessageTextEntity]) { self.entities = entities }
    init(decoder: PostboxDecoder) { self.entities = decoder.decodeInt32ArrayForKey("e").map { MessageTextEntity(value: $0) } }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeInt32Array(self.entities.map { $0.value }, forKey: "e") }
}
class TestMedia: Media {
    let id: MediaId?
    let payload: Int32
    init(id: Int32, payload: Int32 = 0) { self.id = MediaId(id: id); self.payload = payload }
    required init(decoder: PostboxDecoder) { self.id = MediaId(id: decoder.decodeInt32ForKey("i", orElse: 0)); self.payload = decoder.decodeInt32ForKey("p", orElse: 0) }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeInt32(self.id!.id, forKey: "i"); encoder.encodeInt32(self.payload, forKey: "p") }
    func isEqual(to other: Media) -> Bool { return self.id == other.id && self.payload == (other as? TestMedia)?.payload }
}
final class TelegramMediaAction: TestMedia {}

class AutoremoveTimeoutMessageAttribute: MessageAttribute {
    init() {}
    required init(decoder: PostboxDecoder) {}
    func encode(_ encoder: PostboxEncoder) {}
}
final class AutoclearTimeoutMessageAttribute: AutoremoveTimeoutMessageAttribute {}

struct TestInstantPage: Equatable {
    let revision: Int
    static func ==(lhs: TestInstantPage, rhs: TestInstantPage) -> Bool { lhs.revision == rhs.revision }
    func allMedia() -> [Media] { [TestMedia(id: Int32(revision))] }
}
final class RichTextMessageAttribute: MessageAttribute {
    let instantPage: TestInstantPage
    init(_ revision: Int) { self.instantPage = TestInstantPage(revision: revision) }
    init(decoder: PostboxDecoder) { self.instantPage = TestInstantPage(revision: Int(decoder.decodeInt32ForKey("r", orElse: 0))) }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeInt32(Int32(self.instantPage.revision), forKey: "r") }
}
final class TestReferencesAttribute: MessageAttribute {
    var associatedMediaIds: [MediaId] { [MediaId(id: 55)] }
    var associatedPeerIds: [PeerId] { [PeerId(namespace: 42)] }
    var associatedMessageIds: [MessageId] { [MessageId(peerId: PeerId(namespace: 42), namespace: 0, id: 77)] }
    var associatedStoryIds: [StoryId] { [StoryId()] }
    init() {}
    init(decoder: PostboxDecoder) {}
    func encode(_ encoder: PostboxEncoder) {}
}
