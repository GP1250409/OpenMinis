//
//  attachment-url-tests/main.swift
//  真实生产 helper 的回归：MinisURLEncoding.swift / AttachmentXMLCodec.swift /
//  MinisURLPathDecoding.swift 是直接编译进来的生产源文件（不是复制品）。
//
//  运行：python3 scripts/attachment_url_regression.py
//  标记：ATTACHMENT_URL_PASS checks=N / ATTACHMENT_XML_PASS checks=N
//
import Foundation

var checks = 0
var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures.append(label)
        print("ATTACHMENT_CHECK_FAIL \(label)")
    }
}

let fm = FileManager.default
let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("attachment-url-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmpRoot) }

// MARK: - 1. raw linux path -> minis:// URL（中文/空格/emoji/#/?/%/字面%E5/字面%2F/多级目录/ASCII）

struct URLCase {
    let path: String
    let subPath: String
    let namespace: String
}

let urlCases: [URLCase] = [
    URLCase(path: "/var/minis/attachments/uploads/photo.png",
            subPath: "uploads/photo.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/PNG图像.png",
            subPath: "uploads/PNG图像.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/我的 文件.pdf",
            subPath: "uploads/我的 文件.pdf", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/emoji😀.png",
            subPath: "uploads/emoji😀.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/a#b.png",
            subPath: "uploads/a#b.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/a?b.png",
            subPath: "uploads/a?b.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/100%.png",
            subPath: "uploads/100%.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/%E5%9B%BE.png",
            subPath: "uploads/%E5%9B%BE.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/a%2Fb.png",
            subPath: "uploads/a%2Fb.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/中文 目录/深/图 1.png",
            subPath: "uploads/中文 目录/深/图 1.png", namespace: "attachments"),
    URLCase(path: "/var/minis/shared/project/报告 v2.pdf",
            subPath: "project/报告 v2.pdf", namespace: "shared"),
    URLCase(path: "/var/minis/workspace/mini app/图表 数据 & 备注.csv",
            subPath: "mini app/图表 数据 & 备注.csv", namespace: "workspace"),
    URLCase(path: "/var/minis/attachments/uploads/a&b.png",
            subPath: "uploads/a&b.png", namespace: "attachments"),
    URLCase(path: "/var/minis/attachments/uploads/quote\"and'apos.png",
            subPath: "uploads/quote\"and'apos.png", namespace: "attachments"),
]

for c in urlCases {
    let urlString = MinisURLEncoding.minisURL(forLinuxPath: c.path)
    check(urlString.allSatisfy { $0.isASCII }, "URL is pure ASCII — \(c.path) -> \(urlString)")
    guard let url = URL(string: urlString) else {
        check(false, "URL(string:) parses — \(urlString)")
        continue
    }
    check(url.host == c.namespace, "host stays the ASCII namespace — \(c.path)")
    check(url.query == nil, "no query (a raw ? never becomes one) — \(c.path)")
    check(url.fragment == nil, "no fragment (a raw # never becomes one) — \(c.path)")
    check(url.path == "/" + c.subPath, "url.path decodes back to the raw subpath — \(c.path) got \(url.path)")
    check(urlString == "minis://\(c.namespace)/" + MinisURLEncoding.encodeRawSubPath(c.subPath),
          "URL is namespace + one-time encoded subpath — \(c.path)")
}

// 非 /var/minis/ 路径原样返回（历史契约），命名空间单独出现不加斜杠
check(MinisURLEncoding.minisURL(forLinuxPath: "/tmp/x y.png") == "/tmp/x y.png",
      "non-minis path returned unchanged")
check(MinisURLEncoding.minisURL(forLinuxPath: "/var/minis/attachments") == "minis://attachments",
      "namespace-only path stays namespace-only")
check(MinisURLEncoding.minisURL(forLinuxPath: "/var/minis/") == "minis://",
      "bare /var/minis/ degenerates exactly like before")

// 命名空间固定 ASCII（A&& 不改 raw path / 磁盘名）
for ns in MinisURLEncoding.namespaces {
    check(ns.allSatisfy { $0.isASCII }, "namespace is ASCII: \(ns)")
}
check(Set(MinisURLEncoding.namespaces).count == 6, "namespace list is the 6 known owners")

// MARK: - 2. 编码必须一次且只一次（原报告“已编码不得出现 %25E5”是错的，这里反向锁定）

let cjkPath = "/var/minis/attachments/uploads/图.png"
let cjkURL = MinisURLEncoding.minisURL(forLinuxPath: cjkPath)
check(cjkURL == "minis://attachments/uploads/%E5%9B%BE.png", "CJK encoded exactly once: \(cjkURL)")

let literalPath = "/var/minis/attachments/uploads/%E5%9B%BE.png"
let literalURL = MinisURLEncoding.minisURL(forLinuxPath: literalPath)
check(literalURL == "minis://attachments/uploads/%25E5%259B%25BE.png",
      "a literal %E5 disk name encodes the percent sign itself: \(literalURL)")
check(literalURL.contains("%25E5"), "literal %E5 MUST appear as %25E5 (report's idempotency test inverted)")
if let u = URL(string: literalURL) {
    check(u.path == "/uploads/%E5%9B%BE.png", "literal %E5 round-trips as the literal name, not 图: \(u.path)")
}
let literalSlashPath = "/var/minis/attachments/uploads/a%2Fb.png"
let literalSlashURL = MinisURLEncoding.minisURL(forLinuxPath: literalSlashPath)
check(literalSlashURL == "minis://attachments/uploads/a%252Fb.png",
      "a literal %2F filename is not turned into a directory: \(literalSlashURL)")
if let u = URL(string: literalSlashURL) {
    check(u.path == "/uploads/a%2Fb.png", "literal %2F round-trips as a name: \(u.path)")
}
check(!literalSlashURL.hasSuffix("/a/b.png"), "literal %2F never becomes a/b path")

// MARK: - 3. 磁盘上 图.png 与 %E5...png 同时存在：各打开自己的文件

let uploads = tmpRoot.appendingPathComponent("uploads", isDirectory: true)
try! fm.createDirectory(at: uploads, withIntermediateDirectories: true)
let cjkFile = uploads.appendingPathComponent("图.png")
let literalFile = uploads.appendingPathComponent("%E5%9B%BE.png")
let deepDir = uploads.appendingPathComponent("中文 目录/深", isDirectory: true)
try! fm.createDirectory(at: deepDir, withIntermediateDirectories: true)
let spaceFile = deepDir.appendingPathComponent("图 1.png")
try! Data("CJK-FILE".utf8).write(to: cjkFile)
try! Data("LITERAL-PERCENT-FILE".utf8).write(to: literalFile)
try! Data("DEEP-SPACE-FILE".utf8).write(to: spaceFile)
try! Data("AMP".utf8).write(to: uploads.appendingPathComponent("a&b.png"))

/// 与 MinisMediaViews.resolveMinisFileURL 同一规则：真实 subPathCandidates +
/// 第一个在磁盘上存在的候选（生产代码用的就是这个 helper 与这个顺序）。
func resolveUsingProductionHelper(minisURL: String, base: URL) -> (URL, Int)? {
    guard let url = URL(string: minisURL) else { return nil }
    let candidates = MinisURLPathDecoding.subPathCandidates(for: url)
    for sub in candidates {
        let candidate = base.appendingPathComponent(sub)
        if fm.fileExists(atPath: candidate.path) { return (candidate, candidates.count) }
    }
    return nil
}

let cjkResolved = resolveUsingProductionHelper(minisURL: cjkURL, base: tmpRoot)
check(cjkResolved?.0.lastPathComponent == "图.png", "图.png opens 图.png")
check(cjkResolved?.1 == 1, "图.png needs no double-decode fallback (single candidate)")
let literalResolved = resolveUsingProductionHelper(minisURL: literalURL, base: tmpRoot)
check(literalResolved?.0.lastPathComponent == "%E5%9B%BE.png", "%E5...png opens the literal %E5 file")
check(URL(string: literalURL).map { MinisURLPathDecoding.subPathCandidates(for: $0).first == "uploads/%E5%9B%BE.png" } == true,
      "literal %E5 resolves through the FIRST (single-decode) candidate, never the legacy fallback")
check(literalResolved?.0.lastPathComponent == "%E5%9B%BE.png", "first-candidate identity is preserved with both files present")
check(cjkResolved?.0.path != literalResolved?.0.path, "the two coexisting files resolve to different paths")
let deepURL = MinisURLEncoding.minisURL(forLinuxPath: "/var/minis/attachments/uploads/中文 目录/深/图 1.png")
let deepResolved = resolveUsingProductionHelper(minisURL: deepURL, base: tmpRoot)
check(deepResolved?.0.lastPathComponent == "图 1.png", "multi-level CJK dir + space resolves")
check(deepResolved?.1 == 1, "multi-level path needs no fallback")
let ampURL = MinisURLEncoding.minisURL(forLinuxPath: "/var/minis/attachments/uploads/a&b.png")
check(resolveUsingProductionHelper(minisURL: ampURL, base: tmpRoot)?.0.lastPathComponent == "a&b.png",
      "a raw & in the file name resolves")

// MARK: - 4. 旧历史恢复：旧消息里存的 raw path 仍能预览（且不被改名）

/// 旧格式（无 marker）的完整消息文本，模拟 DB 里已有的历史消息。
func oldFormatMessage(rawPath: String, url: String) -> String {
    "<user-attached-files>\n"
        + "  <file path=\"\(rawPath)\" url=\"\(url)\" size=\"12\" modified=\"2026-11-01T00:00:00Z\" />\n"
        + "</user-attached-files>\n看图"
}

for (raw, expectedName) in [
    ("/var/minis/attachments/uploads/图.png", "图.png"),
    (literalPath, "%E5%9B%BE.png"),
    ("/var/minis/attachments/uploads/PNG图像.png", "PNG图像.png"),
] {
    // 旧写手会把 raw path 原样写进 path 属性，也会把裸 minis:// 原样写进 url。
    let stored = oldFormatMessage(rawPath: raw, url: "minis://attachments" + raw.dropFirst("/var/minis/attachments".count))
    let tags = AttachmentXMLCodec.parseFileTags(in: stored)
    check(tags.count == 1, "old history: exactly one file tag for \(raw)")
    guard let tag = tags.first else { continue }
    check(tag.path == raw, "old history: path preserved byte-for-byte — \(tag.path)")
    check(tag.decodedAttributes == false, "old history: no marker -> no entity decoding")
    let url = MinisURLEncoding.minisURL(forLinuxPath: tag.path)
    guard let u = URL(string: url) else { check(false, "old history URL parses: \(url)"); continue }
    check(u.path.hasSuffix(expectedName), "old history URL keeps the real name — \(u.path)")
}

// 旧消息里裸 url 属性（未编码）本身仍应能被 Markdown 那侧的 idempotent helper 修复，
// 说明本轮没有破坏既有双解兼容：encodeRawMinisURL 语义在测试里以同样算法验证。
func idempotentRepairPath(_ raw: String) -> String {
    raw.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
        let s = String(seg)
        let decoded = s.removingPercentEncoding ?? s
        return decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }.joined(separator: "/")
}
check(idempotentRepairPath("attachments/uploads/PNG图像.png") == "attachments/uploads/PNG%E5%9B%BE%E5%83%8F.png",
      "markdown-side legacy repair still normalises a raw CJK link")
check(idempotentRepairPath("attachments/uploads/%E5%9B%BE.png") == "attachments/uploads/%E5%9B%BE.png",
      "markdown-side legacy repair is unchanged (idempotent, decode-first) — untouched by this fix")

// URL 侧的检查数（含旧历史恢复），XML 侧单独统计。
let urlChecks = checks

// MARK: - 5. XML 属性转义 / 单趟反转义

let nasty = "a&b<c>d\"e'f.png"
check(AttachmentXMLCodec.escapeAttribute(nasty) == "a&amp;b&lt;c&gt;d&quot;e&apos;f.png",
      "escape covers & < > \" ' in the documented order")
check(AttachmentXMLCodec.escapeAttribute("&amp;") == "&amp;amp;",
      "& is escaped first, so an existing entity is escaped again (not aliased)")
check(AttachmentXMLCodec.escapeAttribute("plain.png") == "plain.png", "plain ASCII is untouched")
check(AttachmentXMLCodec.escapeAttribute("图 1&2.png") == "图 1&amp;2.png", "CJK kept verbatim, & escaped")

for sample in [nasty, "&amp;", "&lt;x&gt;", "emoji😀 & 中文 \"q\"", "&#39;", "a&b", "100%.png"] {
    check(AttachmentXMLCodec.unescapeAttribute(AttachmentXMLCodec.escapeAttribute(sample)) == sample,
          "escape -> unescape round-trip: \(sample)")
}
check(AttachmentXMLCodec.unescapeAttribute("&amp;lt;") == "&lt;", "single pass: &amp;lt; -> &lt; (never <)")
check(AttachmentXMLCodec.unescapeAttribute("&amp;amp;") == "&amp;", "single pass: &amp;amp; -> &amp;")
check(AttachmentXMLCodec.unescapeAttribute("&unknown;") == "&unknown;", "unknown entity kept verbatim")
check(AttachmentXMLCodec.unescapeAttribute("&#x4F60;&#22909;") == "你好", "numeric entities decode")
check(AttachmentXMLCodec.unescapeAttribute("bare & no semicolon") == "bare & no semicolon",
      "a bare & without a terminating ; is not eaten")
check(AttachmentXMLCodec.unescapeAttribute("&;") == "&;", "empty entity kept verbatim")

// MARK: - 6. <file> 写入与回读

let rawAmpPath = "/var/minis/attachments/uploads/a&b.png"
let rawQuotePath = "/var/minis/attachments/uploads/quote\"and'apos.png"
let tagLine = AttachmentXMLCodec.fileTagXML(path: rawAmpPath,
                                            url: MinisURLEncoding.minisURL(forLinuxPath: rawAmpPath),
                                            size: 3,
                                            modified: "2026-11-18T00:00:00Z")
check(tagLine.contains("encoding=\"xml-attributes-v1\""), "new tag carries the version marker")
check(tagLine.hasSuffix("/>"), "new tag closes with />")
check(tagLine.contains("path=\"\(AttachmentXMLCodec.escapeAttribute(rawAmpPath))\""),
      "path attribute is the escaped RAW disk path (never the URL form)")
check(!tagLine.contains("path=\"\(MinisURLEncoding.minisURL(forLinuxPath: rawAmpPath))\""),
      "the path attribute is not the minis:// URL")
let bodyAmp = "<user-attached-files>\n\(tagLine)\n</user-attached-files>"
check(bodyAmp.contains("<file "), "outer block detection (<file ) still matches after adding an attribute")
check(bodyAmp.contains("<user-attached-files>"), "outer block tags unchanged")
let parsedAmp = AttachmentXMLCodec.parseFileTags(in: bodyAmp)
check(parsedAmp.count == 1, "new tag parses back")
check(parsedAmp.first?.path == rawAmpPath, "new tag path round-trips through escaping — \(parsedAmp.first?.path ?? "nil")")
check(parsedAmp.first?.size == 3, "new tag size round-trips")
check(parsedAmp.first?.modified == "2026-11-18T00:00:00Z", "new tag modified round-trips")
check(parsedAmp.first?.decodedAttributes == true, "new tag is marked as decoded")
check(parsedAmp.first?.url == MinisURLEncoding.minisURL(forLinuxPath: rawAmpPath), "new tag url round-trips")

let quoteTag = AttachmentXMLCodec.fileTagXML(path: rawQuotePath, url: "minis://attachments/uploads/x.png",
                                             size: 1, modified: "2026-11-18T00:00:00Z")
let quoteParsed = AttachmentXMLCodec.parseFileTags(in: "<user-attached-files>\n\(quoteTag)\n</user-attached-files>")
check(quoteParsed.first?.path == rawQuotePath,
      "a quote in the file name no longer breaks reload (old regex lost this attachment)")

// 旧消息（无 marker）：字面实体与裸 & 都必须原样保留
let literalEntityPath = "/var/minis/attachments/uploads/a&amp;b.png"
for raw in [literalEntityPath, "/var/minis/attachments/uploads/a&b.png"] {
    let stored = "<user-attached-files>\n  <file path=\"\(raw)\" url=\"minis://attachments/uploads/x.png\" size=\"1\" modified=\"2026-11-01T00:00:00Z\" />\n</user-attached-files>"
    let parsed = AttachmentXMLCodec.parseFileTags(in: stored)
    check(parsed.first?.path == raw, "old message path NOT entity-decoded — \(raw) -> \(parsed.first?.path ?? "nil")")
    check(parsed.first?.decodedAttributes == false, "old message stays unmarked")
}
check(AttachmentXMLCodec.parseFileTags(in: "<user-attached-files>\n  <file path=\"\(literalEntityPath)\" />\n</user-attached-files>").first?.path == literalEntityPath,
      "literal &amp; file name is not silently re-pointed at a&b.png")

// 属性顺序无关 + 未知属性忽略 + 缺省可选字段
let reordered = "<user-attached-files>\n  <file size=\"7\" encoding=\"xml-attributes-v1\" path=\"a&amp;b.png\" url=\"minis://attachments/x.png\" future=\"y\" />\n</user-attached-files>"
let reorderedTags = AttachmentXMLCodec.parseFileTags(in: reordered)
check(reorderedTags.first?.path == "a&b.png", "attribute order is irrelevant for a marked tag")
check(reorderedTags.first?.size == 7, "size parsed regardless of position")
check(reorderedTags.first?.modified == nil, "missing modified is tolerated")
let minimal = "<user-attached-files>\n  <file path=\"/var/minis/attachments/uploads/x.png\" />\n</user-attached-files>"
check(AttachmentXMLCodec.parseFileTags(in: minimal).first?.path == "/var/minis/attachments/uploads/x.png",
      "path-only legacy tag still parses (old regex allowed it)")

// 多文件、跳过无 path、跳过畸形（未转义引号，与旧正则同样无法恢复）
let multi = "<user-attached-files>\n"
    + AttachmentXMLCodec.fileTagXML(path: "/var/minis/attachments/uploads/图 1.png", url: "minis://attachments/u1", size: 1, modified: "t")
    + "\n"
    + AttachmentXMLCodec.fileTagXML(path: "/var/minis/attachments/uploads/a&b.png", url: "minis://attachments/u2", size: 2, modified: "t")
    + "\n  <file size=\"9\" />\n"
    + "\n  <file path=\"broken\".png\" size=\"3\" />\n"
    + "\n</user-attached-files>"
let multiTags = AttachmentXMLCodec.parseFileTags(in: multi)
check(multiTags.count == 2, "multiple marked files parse, no-path and malformed tags are skipped (got \(multiTags.count))")
check(multiTags.map(\.path) == ["/var/minis/attachments/uploads/图 1.png", "/var/minis/attachments/uploads/a&b.png"],
      "both file paths survive escaping/decoding in order")
check(multiTags.map(\.size) == [1, 2], "sizes stay aligned with their tags")

// 转义后的 path 属性里不含裸引号/尖括号，保证 <file> 标签自身可解析
for raw in [rawAmpPath, rawQuotePath, "/var/minis/attachments/uploads/<x>.png"] {
    let line = AttachmentXMLCodec.fileTagXML(path: raw, url: "u", size: 0, modified: "m")
    check(line.filter { $0 == "\"" }.count == 10,
          "escaped tag has exactly 10 attribute quotes (5 attributes) — no stray quote: \(raw)")
    check(!line.contains("path=\"\(raw)\""), "a raw quote inside the path never reaches the tag: \(raw)")
}

// MARK: - 结果

let xmlChecks = checks - urlChecks
if failures.isEmpty {
    print("ATTACHMENT_URL_PASS checks=\(urlChecks)")
    print("ATTACHMENT_XML_PASS checks=\(xmlChecks)")
    print("ATTACHMENT_URL_XML_TESTS_OK checks=\(checks)")
} else {
    print("ATTACHMENT_URL_XML_TESTS_FAIL checks=\(checks) failures=\(failures.count)")
    for f in failures { print("  - \(f)") }
    exit(1)
}
