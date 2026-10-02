// The gate consumes foreground/disabled events but never alerts for them later.
var gate = ArielgramLocalNotificationGate()
gate.update(enabled: false, background: false, now: 0)
precondition(!gate.consume(identifiers: ["foreground"], timestamp: 1000, serverNow: 1000, now: 0))
gate.update(enabled: true, background: false, now: 1)
precondition(!gate.consume(identifiers: ["enabledForeground"], timestamp: 1001, serverNow: 1001, now: 1))
gate.update(enabled: true, background: true, now: 2)
let generation = gate.generation
precondition(gate.allows(generation: generation))
precondition(!gate.consume(identifiers: ["foreground", "enabledForeground"], timestamp: 1001, serverNow: 1002, now: 2))
// Old synchronization backlog is excluded; new messages from the active window
// still notify after a slow transaction/network update, without a fixed timeout.
precondition(!gate.consume(identifiers: ["old"], timestamp: 800, serverNow: 1002, now: 2))
precondition(gate.consume(identifiers: ["new"], timestamp: 1003, serverNow: 1003, now: 3))
precondition(!gate.consume(identifiers: ["new"], timestamp: 1003, serverNow: 1004, now: 4))
precondition(gate.consume(identifiers: ["delayed"], timestamp: 1020, serverNow: 1100, now: 100))
precondition(!gate.consume(identifiers: ["invalidFuture"], timestamp: 9999, serverNow: 1100, now: 100))
// Duplicate grouped events/album members produce one notification. New album
// members can update it; the same members cannot alert again.
precondition(gate.consume(identifiers: ["album1", "album2", "album1"], timestamp: 1101, serverNow: 1101, now: 101))
precondition(!gate.consume(identifiers: ["album2", "album1"], timestamp: 1101, serverNow: 1101, now: 101))
precondition(gate.consume(identifiers: ["album1", "album2", "album3"], timestamp: 1102, serverNow: 1102, now: 102))
// Already-started transactions must not deliver after returning to the foreground
// or toggling monitoring off and back on.
gate.update(enabled: true, background: false, now: 103)
precondition(!gate.allows(generation: generation))
gate.update(enabled: true, background: true, now: 104)
let backgroundGeneration = gate.generation
gate.update(enabled: false, background: true, now: 105)
gate.update(enabled: true, background: true, now: 106)
precondition(!gate.allows(generation: backgroundGeneration))
// IDs are account-local even when both accounts have the same chat/message IDs,
// and still use the standard message cleanup format.
let first = arielgramNotificationIdentifier(accountId: 1, peerId: -99999999999, namespace: 0, messageId: 42)
let second = arielgramNotificationIdentifier(accountId: 2, peerId: -99999999999, namespace: 0, messageId: 42)
precondition(first != second && first.hasPrefix("m-99999999999:0:42_"))
precondition(gate.consume(identifiers: [first, second], timestamp: 1107, serverNow: 1107, now: 107))
precondition(arielgramNotificationPreview("中👩🏽‍💻文 SECRET tail", spoilers: [("中👩🏽‍💻文 SECRET tail" as NSString).range(of: "SECRET")]) == "中👩🏽‍💻文 •••• tail")
precondition(arielgramNotificationPreview("abcdefg", spoilers: [NSRange(location: 0, length: 4), NSRange(location: 2, length: 4)]) == "••••g")
precondition(arielgramNotificationPreview("abcdefg", spoilers: [NSRange(location: 5, length: 99), NSRange(location: -1, length: 2)]) == "abcde••••")
precondition(arielgramNotificationPreview(String(repeating: "文", count: 1000), spoilers: []).count == 512)
print("Background gates, replay suppression, accounts, albums, and spoiler privacy passed")
