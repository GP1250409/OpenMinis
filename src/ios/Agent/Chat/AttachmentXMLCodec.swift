//
//  AttachmentXMLCodec.swift
//  Minis - Agent/Chat (Foundation only)
//
//  Writing and reading the `<user-attached-files>` metadata block.
//
//  Before this file the writer interpolated `meta.path` / `meta.minisURL`
//  straight into `<file path="…" url="…">` and the reader matched it with a
//  regex and used the captured text verbatim. Two consequences:
//   * A filename containing `&` produced invalid XML for the model
//     (`a&b.png`), and `"` made the tag unparseable on reload (the message
//     lost that attachment card).
//   * Escaping only the writer would CORRUPT history: messages already in the
//     DB contain raw `&amp;` as the literal file name, and a naive reader that
//     decodes every old path would look for `&` instead of `&amp;`.
//
//  Format (T-attachment-xml-attr-escape 2026-11-18):
//   * NEW messages carry an explicit marker on every file tag:
//         <file path="a&amp;b.png" url="minis://attachments/uploads/a%26b.png"
//               size="12" modified="…" encoding="xml-attributes-v1" />
//     Only a tag carrying `encoding="xml-attributes-v1"` is entity-decoded on
//     read. The value is validated: attribute order is irrelevant and unknown
//     attributes are ignored, so the marker can move and the tag can grow.
//   * OLD messages (no marker) keep the byte-for-byte path they were written
//     with: a literal `&amp;` file name stays `&amp;`, a raw `a&b.png` stays
//     `a&b.png`. No migration, no rewriting, no guessing.
//   * The outer `<user-attached-files>` block detection is unchanged (the
//     marker lives on `<file>`, never on the block element).
//
//  Decoding is a single left-to-right pass, so `&amp;lt;` → `&lt;` (one layer,
//  never `<`).
//
//  Writing escapes each character INDEPENDENTLY (a per-scalar map, not a
//  sequential string replacement), so `escape("&amp;") == "&amp;amp;"` and
//  escape→unescape round-trips exactly; there is no "escape & last" ordering
//  step to get wrong. The attribute order on the wire is path, url, size,
//  modified, encoding.
//

import Foundation

/// One `<file …/>` entry read back from a `<user-attached-files>` block.
struct AttachmentFileTag: Equatable {
    /// The raw on-disk path (decoded only when the tag carried the marker).
    var path: String
    var url: String?
    var size: Int
    var modified: String?
    /// True when the tag carried `encoding="xml-attributes-v1"`.
    var decodedAttributes: Bool
}

enum AttachmentXMLCodec {
    /// Marker value written on every file tag. Bump to a new string if the
    /// attribute encoding ever changes; old messages keep their own marker.
    static let attributeEncodingV1 = "xml-attributes-v1"
    /// Attribute that carries the marker.
    static let encodingAttribute = "encoding"

    // MARK: - Escaping (writer)

    /// Escape a value for a double-quoted XML attribute.
    /// Order matters: `&` FIRST, otherwise the `&` of the entities we just
    /// wrote would be escaped again.
    static func escapeAttribute(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) else { return raw }
        var out = ""
        out.reserveCapacity(raw.count + 8)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Unescaping (reader, new-format tags only)

    /// Entity-decode an attribute value in ONE left-to-right pass.
    /// `&amp;lt;` becomes `&lt;`, never `<`; an unknown/ill-formed entity is
    /// kept verbatim so nothing is invented.
    static func unescapeAttribute(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "&" {
                let afterAmp = raw.index(after: i)
                if afterAmp < raw.endIndex,
                   let semi = raw[afterAmp...].firstIndex(of: ";"),
                   raw.distance(from: afterAmp, to: semi) <= 10,
                   let decoded = decodeEntity(String(raw[afterAmp..<semi])) {
                    out += decoded
                    i = raw.index(after: semi)
                    continue
                }
            }
            out.append(raw[i])
            i = raw.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            guard let value = UInt32(name.dropFirst(2), radix: 16),
                  let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        if name.hasPrefix("#") {
            guard let value = UInt32(name.dropFirst(), radix: 10),
                  let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        return nil
    }

    // MARK: - Writing

    /// The `<file … />` line for a new message (caller adds the newline).
    /// `path` is the RAW disk path; it is escaped here, never pre-encoded.
    static func fileTagXML(path: String, url: String, size: Int, modified: String) -> String {
        "  <file path=\"\(escapeAttribute(path))\""
            + " url=\"\(escapeAttribute(url))\""
            + " size=\"\(size)\""
            + " modified=\"\(escapeAttribute(modified))\""
            + " \(encodingAttribute)=\"\(attributeEncodingV1)\" />"
    }

    // MARK: - Reading

    /// Parse every `<file …/>` tag in a `<user-attached-files>` body.
    /// Attribute order is irrelevant. A tag without `path` is skipped, as is a
    /// malformed tag (that is what the old regex did with an unescaped `"`, and
    /// there is no safe way to recover a value that quotes its own delimiter).
    static func parseFileTags(in body: String) -> [AttachmentFileTag] {
        var tags: [AttachmentFileTag] = []
        var cursor = body.startIndex
        while let open = body.range(of: "<file ", range: cursor..<body.endIndex) {
            guard let close = tagTerminator(in: body, from: open.upperBound) else {
                // Unterminated / pathological tag: never let it swallow the rest
                // of the block — resume at the next <file tag, if any.
                guard let next = body.range(of: "<file ", range: open.upperBound..<body.endIndex) else { break }
                cursor = next.lowerBound
                continue
            }
            let attributeText = String(body[open.upperBound..<close.lowerBound])
            if attributes(in: attributeText) == nil {
                // Malformed tag (e.g. an unescaped quote inside a value): resume at
                // the next tag rather than trusting the terminator we landed on.
                cursor = body.range(of: "<file ", range: open.upperBound..<body.endIndex)?.lowerBound ?? close.upperBound
                continue
            }
            if let attributes = attributes(in: attributeText),
               let rawPath = attributes["path"],
               !rawPath.isEmpty {
                let marked = attributes[encodingAttribute] == attributeEncodingV1
                tags.append(AttachmentFileTag(
                    path: marked ? unescapeAttribute(rawPath) : rawPath,
                    url: attributes["url"].map { marked ? unescapeAttribute($0) : $0 },
                    size: Int(attributes["size"] ?? "") ?? 0,
                    modified: attributes["modified"],
                    decodedAttributes: marked
                ))
            }
            cursor = close.upperBound
        }
        return tags
    }

    /// Find the `/>` that closes this `<file …>` tag, ignoring any `/>` that sits
    /// INSIDE a double-quoted attribute value.
    ///
    /// The old regex used `[^"]*` and therefore matched tags whose unescaped path
    /// literally starts with `>`, e.g.
    ///     <file path="/var/minis/attachments/uploads/>.png" url="…" … />
    /// A plain `range(of: "/>")` search cuts that tag at `uploads/`, the tokenizer
    /// sees an unterminated quote and the whole attachment disappears on reload.
    /// This scan tracks quote state, so only a `/>` outside quotes terminates.
    /// The scan covers the whole remainder (capped at 8192 chars) and only a `/>`
    /// OUTSIDE quotes terminates; a `<file ` seen outside quotes means this tag never
    /// closed, and the caller then resumes at that tag. A legal disk name that itself
    /// contains `<file ` or `/>` sits INSIDE quotes and is never mistaken for a
    /// boundary. Unpaired quotes therefore cost exactly one tag, never a run.
    private static func tagTerminator(in text: String, from start: String.Index) -> Range<String.Index>? {
        var i = start
        var inQuotes = false
        var length = 0
        while i < text.endIndex {
            length += 1
            if length > 8192 { return nil }
            let c = text[i]
            if inQuotes {
                if c == "\"" { inQuotes = false }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "/" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == ">" {
                    return i..<text.index(after: next)
                }
            } else if c == "<", text[i...].hasPrefix("<file ") {
                // Another tag started OUTSIDE any quoted value: this tag is
                // unterminated, so let the caller resynchronise there.
                return nil
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Tokenize `name="value"` pairs. Returns nil for a malformed tag so the
    /// caller can skip it instead of trusting a partial parse.
    static func attributes(in tagText: String) -> [String: String]? {
        var attributes: [String: String] = [:]
        var i = tagText.startIndex
        while i < tagText.endIndex {
            while i < tagText.endIndex, tagText[i] == " " || tagText[i] == "\n" || tagText[i] == "\t" || tagText[i] == "\r" {
                i = tagText.index(after: i)
            }
            if i == tagText.endIndex { break }
            let nameStart = i
            while i < tagText.endIndex, tagText[i] != "=", tagText[i] != " ", tagText[i] != "\n" {
                i = tagText.index(after: i)
            }
            let name = String(tagText[nameStart..<i])
            guard !name.isEmpty,
                  i < tagText.endIndex, tagText[i] == "=" else { return nil }
            i = tagText.index(after: i)
            guard i < tagText.endIndex, tagText[i] == "\"" else { return nil }
            let valueStart = tagText.index(after: i)
            guard let valueEnd = tagText[valueStart...].firstIndex(of: "\"") else { return nil }
            attributes[name] = String(tagText[valueStart..<valueEnd])
            i = tagText.index(after: valueEnd)
        }
        return attributes.isEmpty ? nil : attributes
    }
}
