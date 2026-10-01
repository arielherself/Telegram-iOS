import Foundation

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    precondition(value(), label)
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
let settings = ContentSettings(ignoreContentRestrictionReasons: [], addContentRestrictionReasons: ["android", "all"], appConfiguration: .defaultValue)
let rules = [RestrictionRule(platform: "ios", reason: "porn-ios", text: "hidden"), RestrictionRule(platform: "all", reason: "unknown-new-reason", text: "hidden"), RestrictionRule(platform: "android", reason: "other", text: "hidden")]
let user = TelegramUser(); user.restrictionInfo = PeerAccessRestrictionInfo(rules: rules)
let channel = TelegramChannel(); channel.restrictionInfo = user.restrictionInfo
let message = Message(); message.author = user; message.restrictedContentAttribute = RestrictedContentMessageAttribute(rules: rules)
expect(settings.ignoresAllContentRestrictions && settings.ignoreContentRestrictionReasons.contains("sensitive"), "all restrictions and sensitive media enabled by default")
expect(settings.addContentRestrictionReasons.isEmpty, "server platform additions do not add client restrictions")
expect(user.restrictionText(platform: "ios", contentSettings: settings) == nil, "user restrictions and forced client reasons ignored")
expect(channel.restrictionText(platform: "ios", contentSettings: settings) == nil, "channel restrictions and forced client reasons ignored")
expect(!message.isRestricted(platform: "ios", contentSettings: settings), "message remains visible regardless of reasons")
expect(message.restrictedContentAttribute?.platformText(platform: "ios", contentSettings: settings, chatId: 10) == nil, "bubble restriction placeholder suppressed")
expect(!message.canRevealContent(contentSettings: settings), "unrestricted message does not gain a reveal-warning caption")
var status = SGStatus(status: 0)
expect(status.status == 2 && SGStatus.default.status == 2, "Pro active for fresh and explicit non-Pro status")
status.status = 1
expect(status.status == 2, "server update cannot downgrade local Pro features")
status = try JSONDecoder().decode(SGStatus.self, from: Data("{\"status\":1}".utf8))
expect(status.status == 2, "existing non-Pro shared setting loads as enabled")
let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Int]
expect(encoded["status"] == 2, "encoded status remains enabled")
SGSimpleSettings.shared.status = 0; SGSimpleSettings.shared.ephemeralStatus = 1
expect(SGSimpleSettings.shared.status == 2 && SGSimpleSettings.shared.ephemeralStatus == 2, "badge and message-filter status entry points enabled")

let audioSession = TestAudioSession()
var players: [AVAudioPlayer] = []
var enabledEvents: [Bool] = []
var controller: ArielgramBackgroundMonitoringController? = ArielgramBackgroundMonitoringController(audioSession: audioSession, updated: { enabledEvents.append($0) }, makePlayer: {
    let player = AVAudioPlayer(); players.append(player); return player
})
weak var weakController = controller
expect(enabledEvents == [false] && audioSession.requests.isEmpty, "background monitoring disabled by default")
SGSimpleSettings.shared.arielgramBackgroundMonitoring = true
expect(enabledEvents.last == true && testDefaults.bool(forKey: "arielgramBackgroundMonitoring"), "switch persists and updates connection policy")
expect(audioSession.requests.count == 1 && audioSession.requests[0].isBackground, "silent audio requests fallback priority")
expect(audioSession.requests[0].audioSessionType == .play(mixWithOthers: true), "silent playback mixes with other applications")
audioSession.activate(); drain()
expect(players.count == 1 && players[0].isPlaying && players[0].numberOfLoops == -1, "activation starts endless silent playback")
SGSimpleSettings.shared.arielgramBackgroundMonitoring = true
expect(audioSession.requests.count == 1, "repeated enabled setting does not create duplicate audio holders")
audioSession.yieldToMedia(); drain()
expect(!players[0].isPlaying && players[0].pauseCount == 1, "silent audio pauses before foreground media takes the session")
NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil); drain()
expect(players[0].playCount == 1, "foreground resume does not steal session from other media")
audioSession.activate(); drain()
expect(players[0].isPlaying && players[0].playCount == 2, "fallback playback resumes after ordinary media releases session")
NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: UInt(1)])
expect(players[0].stopCount == 1 && audioSession.disposalCount == 1, "system interruption releases player and session")
audioSession.requests[0].manualActivate(audioSession.control); drain()
expect(players.count == 1, "late activation from old generation cannot restart playback")
NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: UInt(0)])
audioSession.activate(); drain()
expect(players.count == 2 && players[1].isPlaying, "silent player recovers after system interruption")
NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
audioSession.activate(); drain()
expect(players.count == 3 && players[2].isPlaying, "media-services reset recreates the player")
SGSimpleSettings.shared.arielgramBackgroundMonitoring = false
expect(enabledEvents.last == false && !players[2].isPlaying && !testDefaults.bool(forKey: "arielgramBackgroundMonitoring"), "disabling stops audio and connection keepalive")
controller = nil
expect(weakController == nil, "monitoring controller and observers release cleanly")

let failedSession = TestAudioSession()
controller = ArielgramBackgroundMonitoringController(audioSession: failedSession, updated: { _ in }, makePlayer: {
    let player = AVAudioPlayer(); player.playSucceeds = false; return player
})
SGSimpleSettings.shared.arielgramBackgroundMonitoring = true
failedSession.activate(); drain()
expect(!SGSimpleSettings.shared.arielgramBackgroundMonitoring && !Logger.shared.messages.isEmpty, "playback failure resets the switch rather than claiming background monitoring")
controller = nil
try arielgramSilentAudioData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
testDefaults.removePersistentDomain(forName: testDefaultsDomain)
print("Passed \(checks) content, Pro status and background audio lifecycle checks.")
