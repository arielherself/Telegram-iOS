import Foundation

let testDefaultsDomain = "ArielgramClientFeatures-\(UUID().uuidString)"
let testDefaults = UserDefaults(suiteName: testDefaultsDomain)!
final class SGSimpleSettings {
    static let shared = SGSimpleSettings()
    static let arielgramBackgroundMonitoringChanged = Notification.Name("ArielgramBackgroundMonitoringChanged")
    enum Keys: String { case arielgramBackgroundMonitoring }
    // Production settings go here.
}
struct GlobalSettings: Equatable {
    var forceReasons: [Int64] = [10]
    var unforceReasons: [Int64] = []
    var canViewMessages = true
}
struct WebSettings: Equatable { var global = GlobalSettings() }
struct AppConfiguration: Equatable {
    static let defaultValue = AppConfiguration()
    var sgWebSettings = WebSettings()
}
struct RestrictionRule { let platform: String; let reason: String; let text: String }
struct PeerAccessRestrictionInfo { let rules: [RestrictionRule] }
struct PeerId {
    struct Id { func _internalGetInt64Value() -> Int64 { return 10 } }
    let id = Id()
}
protocol Peer { var id: PeerId { get } }
final class TelegramUser: Peer { let id = PeerId(); var restrictionInfo: PeerAccessRestrictionInfo? }
final class TelegramChannel: Peer { let id = PeerId(); var restrictionInfo: PeerAccessRestrictionInfo? }
struct RestrictedContentMessageAttribute { let rules: [RestrictionRule] }
struct MessageFlags: OptionSet { let rawValue: Int; static let CopyProtected = Self(rawValue: 1) }
final class Message {
    var author: Peer?
    var restrictedContentAttribute: RestrictedContentMessageAttribute?
    var flags: MessageFlags = [.CopyProtected]
}
typealias EngineRawMessage = Message
struct StringCodingKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringLiteral value: String) { self.stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum NoError: Error {}
protocol Disposable { func dispose() }
final class ActionDisposable: Disposable {
    var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func dispose() { let action = self.action; self.action = nil; action?() }
}
final class EmptyDisposableImpl: Disposable { func dispose() {} }
let EmptyDisposable = EmptyDisposableImpl()
final class Subscriber<T> { func putNext(_ value: T) {}; func putCompletion() {} }
struct Signal<T, E: Error> {
    let generator: (Subscriber<T>) -> Disposable
    init(_ generator: @escaping (Subscriber<T>) -> Disposable) { self.generator = generator }
    func start() -> Disposable { generator(Subscriber<T>()) }
}
enum ManagedAudioSessionType: Equatable { case play(mixWithOthers: Bool) }
struct AudioSessionActivationState {}
final class ManagedAudioSessionControl {
    var setupCount = 0
    func setup() { setupCount += 1 }
    func activate(_ completion: @escaping (AudioSessionActivationState) -> Void) { completion(AudioSessionActivationState()) }
}
struct ManagedAudioSessionClientParams {
    let audioSessionType: ManagedAudioSessionType
    let manualActivate: (ManagedAudioSessionControl) -> Void
    let deactivate: (Bool) -> Signal<Void, NoError>
    let headsetConnectionStatusChanged: (Bool) -> Void
    let availableOutputsChanged: ([Int], Int?) -> Void
    let isBackground: Bool
}
protocol ManagedAudioSession { func push(params: ManagedAudioSessionClientParams) -> Disposable }
final class TestAudioSession: ManagedAudioSession {
    var requests: [ManagedAudioSessionClientParams] = []
    var disposalCount = 0
    let control = ManagedAudioSessionControl()
    func push(params: ManagedAudioSessionClientParams) -> Disposable {
        requests.append(params)
        return ActionDisposable { [weak self] in self?.disposalCount += 1 }
    }
    func activate() { requests.last!.manualActivate(control) }
    func yieldToMedia() { let _ = requests.last!.deactivate(false).start() }
}
final class AVAudioPlayer {
    var numberOfLoops = 0
    var isPlaying = false
    var playSucceeds = true
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    init() {}
    init(contentsOf: URL) throws {}
    func prepareToPlay() {}
    func play() -> Bool { playCount += 1; isPlaying = playSucceeds; return playSucceeds }
    func pause() { pauseCount += 1; isPlaying = false }
    func stop() { stopCount += 1; isPlaying = false }
}
enum AVAudioSession {
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    static let interruptionNotification = Notification.Name("TestAudioInterruption")
    static let mediaServicesWereResetNotification = Notification.Name("TestMediaReset")
    static let routeChangeNotification = Notification.Name("TestRouteChange")
}
let AVAudioSessionInterruptionTypeKey = "type"
enum UIApplication { static let didBecomeActiveNotification = Notification.Name("TestBecomeActive") }
final class Logger {
    static let shared = Logger()
    var messages: [String] = []
    func log(_ domain: String, _ message: String) { messages.append(message) }
}
