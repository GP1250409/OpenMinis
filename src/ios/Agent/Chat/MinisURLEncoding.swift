//
//  MinisURLEncoding.swift
//  Minis - Agent/Chat (Foundation only)
//
//  The ONE place that turns a raw Linux path into a `minis://` URL.
//
//  Contract (T-attachment-raw-url-encoding 2026-11-18):
//   * `AttachmentMeta.path` is ALWAYS the raw on-disk path. It is never
//     pre-encoded, never rewritten, never migrated — the resolver and the
//     shell tools both read the file by this exact name.
//   * The namespace (`attachments`, `workspace`, `shared`, `memory`, `skills`,
//     `mcp-servers`) is fixed ASCII and is copied through verbatim. It is NOT
//     part of the file path, so encoding it would change the URL host.
//   * Everything AFTER the namespace is ONE raw subpath and is
//     percent-encoded exactly ONCE with `.urlPathAllowed`. That character set
//     encodes CJK/space/emoji/`#`/`?`/`%` while keeping `/` as a separator, so
//     multi-level directories stay directories. This is the same semantics
//     `AIChatViewModel.linuxPathToMinisURL` already had for the whole
//     namespace-relative remainder (its `filename` variable), extracted so the
//     model entry points and `AttachmentMeta` share it.
//   * It NEVER calls `removingPercentEncoding` first. Decoding-then-encoding
//     ("idempotent") merging is wrong for disk paths: a real file named
//     `%E5%9B%BE.png` and a real file named `图.png` can coexist, and a real
//     file named `a%2Fb.png` is not the directory `a/b`. Raw in → encoded out,
//     one-way and reversible through `URL(string:).path`.
//
//  Why: on iOS 16.6 `URL(string: "minis://attachments/uploads/PNG图像.png")`
//  returns nil, and `#`/`?` silently truncate the path. `minisURL` used to
//  concatenate the raw path, so every CJK/space/emoji attachment thumbnail
//  bailed out at the `guard let url = URL(string:)` line with no log.
//
//  Not used for Markdown destinations: those arrive from the model and may
//  already be encoded, so they keep `encodeRawMinisURL` /
//  `percentEncodePathSegmentIdempotent` (Views/Chat/Markdown/Support) — see
//  that file for the idempotent, decode-first repair.
//

import Foundation

enum MinisURLEncoding {
    /// Prefix every minis-owned Linux path starts with.
    static let linuxPrefix = "/var/minis/"

    /// Namespaces under /var/minis/. Fixed ASCII by contract — never encoded,
    /// never renamed. A test asserts every entry is ASCII.
    static let namespaces: Set<String> = [
        "attachments", "workspace", "shared", "memory", "skills", "mcp-servers",
    ]

    /// Percent-encode a raw (unencoded) on-disk subpath exactly once.
    /// Idempotency is deliberately NOT attempted: see the file comment.
    static func encodeRawSubPath(_ rawSubPath: String) -> String {
        rawSubPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawSubPath
    }

    /// Raw Linux path → `minis://` URL string.
    /// Non-`/var/minis/` paths are returned unchanged (the historical contract:
    /// callers use the string as a plain filesystem path then).
    static func minisURL(forLinuxPath path: String) -> String {
        guard path.hasPrefix(linuxPrefix) else { return path }
        let rest = String(path.dropFirst(linuxPrefix.count))
        guard !rest.isEmpty else { return "minis://" }
        guard let slash = rest.firstIndex(of: "/") else { return "minis://\(rest)" }
        let namespace = String(rest[rest.startIndex..<slash])
        let subPath = String(rest[rest.index(after: slash)...])
        guard !subPath.isEmpty else { return "minis://\(namespace)" }
        return "minis://\(namespace)/\(encodeRawSubPath(subPath))"
    }
}
