import Foundation
let cases = [("", ""), ("abc", ""), ("", "abc"), ("Hello world", "Hello Ariel"), ("aabb", "bbaa"), ("你好世界", "你好👩‍💻世界"), ("🇨🇳🇯🇵", "🇨🇳🇫🇷"), ("e\u{301}", "é"), ("e\u{301}x", "éy"), ("éx", "e\u{301}y"), ("line 1\nline 2", "line 1\nnew line\nline 2")]
func check(_ old: String, _ new: String) {
 let segments = arielgramTextDiff(previous: old, current: new)
 var oldProjection = "", newProjection = ""
 for s in segments {
  let source = (s.kind == .removed ? old : new) as NSString
  precondition(NSMaxRange(s.range) <= source.length)
  let text = source.substring(with: s.range)
  if s.kind != .added { oldProjection += text }
  if s.kind != .removed { newProjection += text }
 }
 precondition(oldProjection == old, "Old projection mismatch")
 precondition(newProjection == new, "New projection mismatch")
}
for (old, new) in cases { check(old, new) }
let alphabet = Array("aab中🙂é\n ")
var seed: UInt64 = 0x415249454c
func random(_ limit: Int) -> Int {
 seed = seed &* 6364136223846793005 &+ 1442695040888963407
 return Int((seed >> 32) % UInt64(limit))
}
for _ in 0..<500 {
 let old = String((0..<random(81)).map { _ in alphabet[random(alphabet.count)] })
 let new = String((0..<random(81)).map { _ in alphabet[random(alphabet.count)] })
 check(old, new)
}
check(String(repeating: "a", count: 4096), String(repeating: "b", count: 4096))
print("Diff projections passed: empty, replacements, Unicode, multiline, 500 randomized pairs and 4096-character replacement.")
