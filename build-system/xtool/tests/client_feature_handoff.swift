import Foundation

enum ManagedAudioSessionType { case playback, voiceCall, videoCall }
final class Holder {
    let isBackground: Bool
    let audioSessionType: ManagedAudioSessionType
    let active: Bool
    var once = false
    var deactivatingDisposable: NSObject?
    init(background: Bool = false, type: ManagedAudioSessionType = .playback, active: Bool = false, deactivating: Bool = false) {
        self.isBackground = background
        self.audioSessionType = type
        self.active = active
        self.deactivatingDisposable = deactivating ? NSObject() : nil
    }
}
struct TestQueue { func async(_ action: () -> Void) { action() } }
final class Session {
    let queue = TestQueue()
    var holders: [Holder]
    var interruptions: [Bool] = []
    init(_ holders: [Holder]) { self.holders = holders }
    func updateHolders(interruption: Bool) { self.interruptions.append(interruption) }
    // Production dropAll goes here.
}

// Without monitoring, preserve the existing interruption path.
let ordinary = Holder(active: true)
let normal = Session([ordinary])
normal.dropAll()
precondition(normal.interruptions == [true] && !ordinary.once)

// A paused player must deactivate once, so its old holder cannot block resumption.
let background = Holder(background: true)
let paused = Holder(active: true)
let idle = Holder()
let monitoring = Session([background, idle, paused])
monitoring.dropAll()
precondition(monitoring.interruptions == [true] && paused.once)
precondition(monitoring.holders.count == 2 && monitoring.holders[0] === background)
precondition(!background.once)

// If the fallback is already active, dropping paused players must not interrupt it.
let playingBackground = Holder(background: true, active: true)
let fallback = Session([playingBackground, Holder()])
fallback.dropAll()
precondition(fallback.interruptions == [false] && fallback.holders.count == 1)

// In-flight deactivation must complete before removing a holder.
let pending = Holder(deactivating: true)
let handoff = Session([background, pending])
handoff.dropAll()
precondition(handoff.holders.count == 2 && pending.once)

for type in [ManagedAudioSessionType.voiceCall, .videoCall] {
    let call = Holder(type: type, active: true)
    let session = Session([background, call, Holder()])
    session.dropAll()
    precondition(session.interruptions == [false] && !call.once)
    precondition(session.holders.count == 2 && session.holders[1] === call)
}
print("Paused media handoff checks passed")
