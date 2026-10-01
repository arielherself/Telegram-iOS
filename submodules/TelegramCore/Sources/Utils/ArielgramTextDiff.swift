import Foundation

public struct ArielgramTextDiffSegment {
    public enum Kind {
        case unchanged
        case removed
        case added
    }
    public let kind: Kind
    /// UTF-16 range into the previous string for removals, current otherwise.
    public let range: NSRange
}

/// Diff grapheme clusters so emoji, combining accents and non-Latin text remain
/// intact. Unchanged text is included in full, with no context-line elision.
public func arielgramTextDiff(previous: String, current: String) -> [ArielgramTextDiffSegment] {
    let old = Array(previous)
    let new = Array(current)
    var removed = Set<Int>()
    var added = Set<Int>()
    for change in new.difference(from: old) {
        switch change {
        case let .remove(offset, _, _): removed.insert(offset)
        case let .insert(offset, _, _): added.insert(offset)
        }
    }
    var result: [ArielgramTextDiffSegment] = []
    var i = 0, j = 0, oldOffset = 0, newOffset = 0
    func append(_ kind: ArielgramTextDiffSegment.Kind, offset: Int, length: Int) {
        if let last = result.last, last.kind == kind, NSMaxRange(last.range) == offset {
            result[result.count - 1] = ArielgramTextDiffSegment(kind: kind, range: NSRange(location: last.range.location, length: last.range.length + length))
        } else {
            result.append(ArielgramTextDiffSegment(kind: kind, range: NSRange(location: offset, length: length)))
        }
    }
    while i < old.count || j < new.count {
        if i < old.count && removed.contains(i) {
            let length = String(old[i]).utf16.count
            append(.removed, offset: oldOffset, length: length)
            oldOffset += length
            i += 1
        } else if j < new.count && added.contains(j) {
            let length = String(new[j]).utf16.count
            append(.added, offset: newOffset, length: length)
            newOffset += length
            j += 1
        } else if i < old.count && j < new.count {
            let length = String(new[j]).utf16.count
            append(.unchanged, offset: newOffset, length: length)
            oldOffset += String(old[i]).utf16.count
            newOffset += length
            i += 1
            j += 1
        } else {
            break
        }
    }
    return result
}
