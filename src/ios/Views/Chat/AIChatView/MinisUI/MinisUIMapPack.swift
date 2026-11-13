// Generic offline map pack protocol, decoder, and bounded LRU geometry cache.
// Pure Foundation (+ optional CoreGraphics path caching); shared by iOS and Linux tests.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Pure Swift SHA-256 (Linux & Darwin Foundation compatible)

enum MUMapSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitLen = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLen >> shift) & 0xff))
        }
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = (UInt32(bytes[j]) << 24) | (UInt32(bytes[j + 1]) << 16)
                    | (UInt32(bytes[j + 2]) << 8) | UInt32(bytes[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

// MARK: - MapPack v1 Protocol Types

struct MUMapCatalog: Codable {
    let schemaVersion: Int
    let packs: [MUMapCatalogEntry]
}

struct MUMapCatalogEntry: Codable {
    let id: String
    let aliases: [String]
    let level: String
    let manifestFile: String
    let manifestSha256: String
    let codesFile: String
    let codesSha256: String
    let geometryFile: String
    let geometrySha256: String
    let featureCount: Int
    let ringCount: Int
    let vertexCount: Int
    let geometryBytes: Int
    let codesBytes: Int?
}

struct MUMapPackCanvas: Codable {
    let width: Double
    let height: Double
    let coordScale: Double
}

struct MUMapPackStyleHints: Codable {
    let featureStrokeWidth: Double
    let overlayStrokeWidth: Double
    let clipToCanvas: Bool
    let drawSeaByDefault: Bool
}

struct MUMapInsetLabel: Codable {
    let text: String
    let x: Double
    let y: Double
}

struct MUMapZone: Codable {
    let id: String
    let projection: String
    let params: [Double]
    let bounds: [Double]
    let frame: [Double]
    let lonMin: Double
    let lonMax: Double
    let latMin: Double
    let latMax: Double
    let antimeridianWrap: Bool
    let insetLabel: MUMapInsetLabel?
    let insetBox: [Double]?

    func contains(lon: Double, lat: Double) -> Bool {
        guard lat >= latMin && lat <= latMax else { return false }
        if antimeridianWrap || lonMin > lonMax {
            return (lon >= lonMin && lon <= 180) || (lon >= -180 && lon <= lonMax)
        }
        return lon >= lonMin && lon <= lonMax
    }

    func project(lon: Double, lat: Double) -> CGPoint? {
        guard bounds.count == 4, frame.count == 4 else { return nil }
        let dxSpan = bounds[2] - bounds[0], dySpan = bounds[3] - bounds[1]
        guard dxSpan > 0, dySpan > 0 else { return nil }
        let x: Double, y: Double
        switch projection {
        case "albers":
            guard params.count >= 4 else { return nil }
            let r = Double.pi / 180.0
            let a = params[0] * r, b = params[1] * r, p0 = params[3] * r
            let n = (sin(a) + sin(b)) / 2.0
            guard abs(n) > 1e-12 else { return nil }
            let c = pow(cos(a), 2) + 2.0 * n * sin(a)
            let rho = sqrt(max(0.0, c - 2.0 * n * sin(lat * r))) / n
            let rho0 = sqrt(max(0.0, c - 2.0 * n * sin(p0))) / n
            var dl = (lon - params[2]).truncatingRemainder(dividingBy: 360.0)
            if dl > 180.0 { dl -= 360.0 }
            if dl < -180.0 { dl += 360.0 }
            let theta = n * dl * r
            x = rho * sin(theta)
            y = rho0 - rho * cos(theta)
        case "laea":
            guard params.count >= 2 else { return nil }
            let r = Double.pi / 180.0
            var dl = (lon - params[0]).truncatingRemainder(dividingBy: 360.0)
            if dl > 180.0 { dl -= 360.0 }
            if dl < -180.0 { dl += 360.0 }
            let l = dl * r
            let p = max(-89.999, min(89.999, lat)) * r
            let p0 = params[1] * r
            let denom = 1.0 + sin(p0) * sin(p) + cos(p0) * cos(p) * cos(l)
            let k = sqrt(2.0 / max(1e-9, denom))
            x = k * cos(p) * sin(l)
            y = k * (cos(p0) * sin(p) - sin(p0) * cos(p) * cos(l))
        case "equalEarth":
            let lon0 = params.first ?? 0.0
            let r = Double.pi / 180.0
            var dl = (lon - lon0).truncatingRemainder(dividingBy: 360.0)
            if dl > 180.0 { dl -= 360.0 }
            if dl < -180.0 { dl += 360.0 }
            let phi = max(-89.999, min(89.999, lat)) * r
            let s = max(-1.0, min(1.0, sin(phi) * sqrt(3.0) / 2.0))
            let t = asin(s)
            let t2 = t * t, t6 = t2 * t2 * t2, t8 = t6 * t2
            let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796
            x = (2.0 * sqrt(3.0) * (dl * r) * cos(t)) / (3.0 * (a1 + 3.0 * a2 * t2 + 7.0 * a3 * t6 + 9.0 * a4 * t8))
            y = t * (a1 + a2 * t2 + a3 * t6 + a4 * t8)
        default:
            return nil
        }
        let scale = min(frame[2] / dxSpan, frame[3] / dySpan)
        let cx = frame[0] + (frame[2] - dxSpan * scale) / 2.0 + (x - bounds[0]) * scale
        let cy = frame[1] + (frame[3] - dySpan * scale) / 2.0 + (bounds[3] - y) * scale
        guard cx.isFinite, cy.isFinite else { return nil }
        return CGPoint(x: cx, y: cy)
    }
}

struct MUMapPackSource: Codable {
    let name: String
    let url: String
    let version: String
    let inputSha256: String
}

struct MUMapPackLicense: Codable {
    let spdx: String
    let attribution: String
    let commercialAllowed: Bool
}

struct MUMapPackGeometryMeta: Codable {
    let file: String
    let sha256: String
    let bytes: Int
    let features: Int
    let rings: Int
    let vertices: Int
    let overlays: Int
}

struct MUMapPackManifest: Codable {
    let schemaVersion: Int
    let id: String
    let aliases: [String]
    let version: String
    let scope: String
    let level: String
    let codeSystem: String
    let source: MUMapPackSource
    let license: MUMapPackLicense
    let boundaryYear: Int
    let complianceNote: String
    let canvas: MUMapPackCanvas
    let styleHints: MUMapPackStyleHints
    let zones: [MUMapZone]
    let codesFile: String
    let codesSha256: String
    let geometry: MUMapPackGeometryMeta
}

struct MUMapFeatureMeta {
    let index: Int
    let code: String
    let name: String
    let zh: String
    let aliases: [String]
}

final class MUMapPackMetadata {
    let manifest: MUMapPackManifest
    let directoryURL: URL?
    let features: [MUMapFeatureMeta]
    let byCode: [String: MUMapFeatureMeta]
    let lookup: [String: String]

    init(manifest: MUMapPackManifest, directoryURL: URL?, features: [MUMapFeatureMeta]) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.features = features
        var map: [String: MUMapFeatureMeta] = [:]
        var canonicalCodes: Set<String> = []
        for f in features {
            map[f.code] = f
            canonicalCodes.insert(f.code.uppercased())
        }
        self.byCode = map
        var idx: [String: String] = [:]
        var ambiguous: Set<String> = []
        for f in features {
            idx[f.code.uppercased()] = f.code
            for raw in [f.name, f.zh] + f.aliases {
                let k = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if k.isEmpty || canonicalCodes.contains(k) { continue }
                if let prev = idx[k], prev != f.code {
                    ambiguous.insert(k)
                } else {
                    idx[k] = f.code
                }
            }
        }
        for k in ambiguous { idx.removeValue(forKey: k) }
        self.lookup = idx
    }

    func canonical(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty else { return nil }
        if let hit = lookup[s] { return hit }
        // Optional "<SCOPE>-" prefix tolerance (e.g., "US-CA" -> "CA", "US-06037" -> "06037")
        let pfx = manifest.scope.uppercased() + "-"
        if s.hasPrefix(pfx) {
            let trimmed = String(s.dropFirst(pfx.count))
            if let hit = lookup[trimmed] { return hit }
        }
        return nil
    }

    func displayName(for code: String) -> String {
        guard let f = byCode[code] else { return code }
        return f.zh.isEmpty ? (f.name.isEmpty ? f.code : f.name) : f.zh
    }
}

struct MUMapOverlay {
    let kind: UInt16
    let closed: Bool
    let points: [CGPoint]
}

final class MUMapDecodedGeometry {
    let features: [[[CGPoint]]]
    let overlays: [MUMapOverlay]
    let byteCost: Int
    #if canImport(CoreGraphics)
    let featurePaths: [CGPath]
    let overlayPaths: [(kind: UInt16, path: CGPath)]
    #endif

    init(features: [[[CGPoint]]], overlays: [MUMapOverlay], byteCost: Int) {
        self.features = features
        self.overlays = overlays
        self.byteCost = byteCost
        #if canImport(CoreGraphics)
        self.featurePaths = features.map { rings in
            let p = CGMutablePath()
            for ring in rings {
                guard let first = ring.first else { continue }
                p.move(to: first)
                for pt in ring.dropFirst() { p.addLine(to: pt) }
                p.closeSubpath()
            }
            return p
        }
        self.overlayPaths = overlays.map { ov in
            let p = CGMutablePath()
            if let first = ov.points.first {
                p.move(to: first)
                for pt in ov.points.dropFirst() { p.addLine(to: pt) }
                if ov.closed { p.closeSubpath() }
            }
            return (ov.kind, p)
        }
        #endif
    }
}

// MARK: - Strict Binary .mump Decoder

enum MUMapPackError: Error, Equatable {
    case invalidPackId
    case notFound
    case oversized
    case corruptHeader
    case corruptBounds
    case checksumMismatch
    case featureCountMismatch
}

enum MUMapPackDecoder {
    static let maxFileBytes = 4_000_000
    static let maxFeatures = 10_000
    static let maxRings = 25_000
    static let maxVertices = 200_000
    static let maxOverlays = 5_000
    static let maxOverlayVertices = 100_000

    static func isSafePackId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-"
        }
    }

    static func isSafeRelativePath(_ rel: String) -> Bool {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains(".."), !rel.contains("\\") else { return false }
        return true
    }

    static func decode(_ data: Data, expectedFeatures: Int? = nil, expectedSha256: String? = nil) throws -> MUMapDecodedGeometry {
        guard data.count >= 32 else { throw MUMapPackError.corruptHeader }
        guard data.count <= maxFileBytes else { throw MUMapPackError.oversized }
        if let expectedSha256, MUMapSHA256.hex(data) != expectedSha256.lowercased() {
            throw MUMapPackError.checksumMismatch
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x4D, bytes[1] == 0x55, bytes[2] == 0x4D, bytes[3] == 0x50 else {
            throw MUMapPackError.corruptHeader
        }
        @inline(__always) func u16(_ at: Int) -> UInt16 {
            UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
        }
        @inline(__always) func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }
        @inline(__always) func i16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
        let version = u16(4), flags = u16(6)
        guard version == 1, flags == 0 else { throw MUMapPackError.corruptHeader }
        let scaleBits = u32(8)
        let coordScale = Double(Float(bitPattern: scaleBits))
        guard coordScale.isFinite, coordScale > 0 else { throw MUMapPackError.corruptHeader }

        let featureCount = Int(u32(12))
        let totalRingCount = Int(u32(16))
        let totalVertexCount = Int(u32(20))
        let overlayCount = Int(u32(24))
        let overlayVertexCount = Int(u32(28))

        guard featureCount <= maxFeatures, totalRingCount <= maxRings, totalVertexCount <= maxVertices,
              overlayCount <= maxOverlays, overlayVertexCount <= maxOverlayVertices else {
            throw MUMapPackError.oversized
        }
        if let expectedFeatures, featureCount != expectedFeatures {
            throw MUMapPackError.featureCountMismatch
        }
        let expectedBytes = 32
            + featureCount * 8
            + totalRingCount * 8
            + totalVertexCount * 4
            + overlayCount * 12
            + overlayVertexCount * 4
        guard bytes.count == expectedBytes else { throw MUMapPackError.corruptBounds }

        let featBase = 32
        let ringBase = featBase + featureCount * 8
        let vertBase = ringBase + totalRingCount * 8
        let ovBase = vertBase + totalVertexCount * 4
        let ovVertBase = ovBase + overlayCount * 12

        var features: [[[CGPoint]]] = []
        features.reserveCapacity(featureCount)
        for fi in 0..<featureCount {
            let fo = featBase + fi * 8
            let rStart = Int(u32(fo))
            let rCount = Int(u16(fo + 4))
            guard rStart >= 0, rCount >= 1, rStart + rCount <= totalRingCount else {
                throw MUMapPackError.corruptBounds
            }
            var rings: [[CGPoint]] = []
            rings.reserveCapacity(rCount)
            for ri in rStart..<(rStart + rCount) {
                let ro = ringBase + ri * 8
                let vStart = Int(u32(ro))
                let vCount = Int(u32(ro + 4))
                guard vStart >= 0, vCount >= 3, vStart + vCount <= totalVertexCount else {
                    throw MUMapPackError.corruptBounds
                }
                var pts: [CGPoint] = []
                pts.reserveCapacity(vCount)
                for vi in vStart..<(vStart + vCount) {
                    let vo = vertBase + vi * 4
                    pts.append(CGPoint(x: Double(i16(vo)) / coordScale, y: Double(i16(vo + 2)) / coordScale))
                }
                rings.append(pts)
            }
            features.append(rings)
        }

        var overlays: [MUMapOverlay] = []
        overlays.reserveCapacity(overlayCount)
        for oi in 0..<overlayCount {
            let oo = ovBase + oi * 12
            let kind = u16(oo)
            let closed = u16(oo + 2) != 0
            let vStart = Int(u32(oo + 4))
            let vCount = Int(u32(oo + 8))
            guard vStart >= 0, vCount >= 2, vStart + vCount <= overlayVertexCount else {
                throw MUMapPackError.corruptBounds
            }
            var pts: [CGPoint] = []
            pts.reserveCapacity(vCount)
            for vi in vStart..<(vStart + vCount) {
                let vo = ovVertBase + vi * 4
                pts.append(CGPoint(x: Double(i16(vo)) / coordScale, y: Double(i16(vo + 2)) / coordScale))
            }
            overlays.append(MUMapOverlay(kind: kind, closed: closed, points: pts))
        }

        let cost = data.count + (totalVertexCount + overlayVertexCount) * 16 + featureCount * 64
        return MUMapDecodedGeometry(features: features, overlays: overlays, byteCost: cost)
    }
}

// MARK: - Pack Registry & Bounded LRU Cache

final class MUMapPackStore {
    static let shared = MUMapPackStore()

    static let maxCachedPacks = 4
    static let maxCachedBytes = 4 * 1024 * 1024

    private let lock = NSLock()
    private var customSearchPaths: [URL]?
    private var loaded = false
    private var packsById: [String: MUMapPackMetadata] = [:]
    private var aliasToId: [String: String] = [:]
    private var orderedIds: [String] = []

    private var geomCache: [String: MUMapDecodedGeometry] = [:]
    private var lruOrder: [String] = []
    private var totalCachedBytes = 0

    func configureSearchPaths(_ directories: [URL]) {
        lock.lock(); defer { lock.unlock() }
        customSearchPaths = directories
        resetStateLocked()
    }

    func resetToDefaultSearchPaths() {
        lock.lock(); defer { lock.unlock() }
        customSearchPaths = nil
        resetStateLocked()
    }

    func clearCache() {
        lock.lock(); defer { lock.unlock() }
        geomCache.removeAll()
        lruOrder.removeAll()
        totalCachedBytes = 0
    }

    func cacheStats() -> (packCount: Int, byteCount: Int, order: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (geomCache.count, totalCachedBytes, lruOrder)
    }

    func availablePackIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        ensureCatalogLoadedLocked()
        return orderedIds
    }

    func availableRegionKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        ensureCatalogLoadedLocked()
        var out: [String] = []
        for id in orderedIds {
            out.append(id)
            if let meta = packsById[id] {
                out.append(contentsOf: meta.manifest.aliases)
            }
        }
        return out
    }

    func resolvePackId(_ rawRegion: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        ensureCatalogLoadedLocked()
        return aliasToId[rawRegion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    func metadata(for rawRegion: String) -> MUMapPackMetadata? {
        lock.lock(); defer { lock.unlock() }
        ensureCatalogLoadedLocked()
        guard let pid = aliasToId[rawRegion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] else { return nil }
        return packsById[pid]
    }

    func canonical(_ rawCode: String, region: String) -> String? {
        metadata(for: region)?.canonical(rawCode)
    }

    func displayName(for canonicalCode: String, region: String) -> String {
        metadata(for: region)?.displayName(for: canonicalCode) ?? canonicalCode
    }

    func isUnshippedChinaRegion(_ rawRegion: String) -> Bool {
        let key = rawRegion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["cn", "cn-admin1", "china"].contains(key) else { return false }
        return resolvePackId(key) == nil
    }

    func geometry(for rawRegion: String) -> MUMapDecodedGeometry? {
        lock.lock(); defer { lock.unlock() }
        ensureCatalogLoadedLocked()
        guard let pid = aliasToId[rawRegion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
              let meta = packsById[pid] else { return nil }

        if let hit = geomCache[pid] {
            touchLRULocked(pid)
            return hit
        }

        let decoded: MUMapDecodedGeometry?
        if let dir = meta.directoryURL {
            decoded = loadGeometryFromDisk(dir: dir, manifest: meta.manifest)
        } else if pid == "us-admin1" {
            decoded = buildBuiltinUSGeometry()
        } else {
            decoded = nil
        }

        guard let geom = decoded else { return nil }
        insertCacheLocked(pid, geom: geom)
        return geom
    }

    // MARK: - Internal helpers

    private func resetStateLocked() {
        loaded = false
        packsById.removeAll()
        aliasToId.removeAll()
        orderedIds.removeAll()
        geomCache.removeAll()
        lruOrder.removeAll()
        totalCachedBytes = 0
    }

    private func candidateDirectories() -> [URL] {
        if let custom = customSearchPaths { return custom }
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MINIS_MAP_PACKS_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let bundled = Bundle.main.url(forResource: "MapPacks", withExtension: nil) {
            dirs.append(bundled)
        }
        let appFallback = Bundle.main.bundleURL.appendingPathComponent("MapPacks", isDirectory: true)
        if !dirs.contains(appFallback) { dirs.append(appFallback) }
        return dirs
    }

    private func ensureCatalogLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        var seenDirs: Set<String> = []
        for rawDir in candidateDirectories() {
            let dir = rawDir.standardizedFileURL
            if !seenDirs.insert(dir.path).inserted { continue }
            let catURL = dir.appendingPathComponent("catalog.json")
            guard fm.fileExists(atPath: catURL.path),
                  let catData = try? Data(contentsOf: catURL),
                  let catalog = try? JSONDecoder().decode(MUMapCatalog.self, from: catData),
                  catalog.schemaVersion == 1 else { continue }
            for entry in catalog.packs {
                guard MUMapPackDecoder.isSafePackId(entry.id),
                      MUMapPackDecoder.isSafeRelativePath(entry.manifestFile),
                      MUMapPackDecoder.isSafeRelativePath(entry.codesFile),
                      MUMapPackDecoder.isSafeRelativePath(entry.geometryFile),
                      packsById[entry.id] == nil else { continue }
                let mURL = dir.appendingPathComponent(entry.manifestFile)
                let cURL = dir.appendingPathComponent(entry.codesFile)
                guard let mData = try? Data(contentsOf: mURL),
                      MUMapSHA256.hex(mData) == entry.manifestSha256.lowercased(),
                      let manifest = try? JSONDecoder().decode(MUMapPackManifest.self, from: mData),
                      manifest.schemaVersion == 1,
                      manifest.id == entry.id,
                      let cData = try? Data(contentsOf: cURL),
                      MUMapSHA256.hex(cData) == entry.codesSha256.lowercased(),
                      let features = parseCodesTSV(cData),
                      features.count == entry.featureCount else { continue }
                let meta = MUMapPackMetadata(manifest: manifest, directoryURL: dir, features: features)
                registerPackLocked(meta)
            }
        }
        if packsById["us-admin1"] == nil {
            registerPackLocked(buildBuiltinUSMetadata())
        }
    }

    private func registerPackLocked(_ meta: MUMapPackMetadata) {
        let pid = meta.manifest.id
        packsById[pid] = meta
        orderedIds.append(pid)
        aliasToId[pid.lowercased()] = pid
        for al in meta.manifest.aliases {
            let k = al.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !k.isEmpty && aliasToId[k] == nil {
                aliasToId[k] = pid
            }
        }
    }

    private func parseCodesTSV(_ data: Data) -> [MUMapFeatureMeta]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out: [MUMapFeatureMeta] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, !cols[0].isEmpty else { return nil }
            let aliases = cols.count == 4
                ? cols[3].split(separator: "|", omittingEmptySubsequences: true).map(String.init)
                : []
            out.append(MUMapFeatureMeta(index: out.count, code: cols[0], name: cols[1], zh: cols[2], aliases: aliases))
        }
        return out
    }

    private func loadGeometryFromDisk(dir: URL, manifest: MUMapPackManifest) -> MUMapDecodedGeometry? {
        let rel = manifest.id + "/" + manifest.geometry.file
        guard MUMapPackDecoder.isSafeRelativePath(rel) else { return nil }
        let url = dir.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MUMapPackDecoder.decode(
            data,
            expectedFeatures: manifest.geometry.features,
            expectedSha256: manifest.geometry.sha256
        )
    }

    private func touchLRULocked(_ pid: String) {
        lruOrder.removeAll { $0 == pid }
        lruOrder.append(pid)
    }

    private func insertCacheLocked(_ pid: String, geom: MUMapDecodedGeometry) {
        guard geom.byteCost <= Self.maxCachedBytes else { return }
        if let old = geomCache.removeValue(forKey: pid) {
            totalCachedBytes -= old.byteCost
            lruOrder.removeAll { $0 == pid }
        }
        while !lruOrder.isEmpty && (geomCache.count >= Self.maxCachedPacks || totalCachedBytes + geom.byteCost > Self.maxCachedBytes) {
            let victim = lruOrder.removeFirst()
            if let old = geomCache.removeValue(forKey: victim) {
                totalCachedBytes -= old.byteCost
            }
        }
        geomCache[pid] = geom
        lruOrder.append(pid)
        totalCachedBytes += geom.byteCost
    }

    // Built-in US fallback metadata + geometry from MinisUIMapData.swift when no MapPacks folder is mounted.
    private func buildBuiltinUSMetadata() -> MUMapPackMetadata {
        let specs = MUMapGeometry.specs
        let zones: [MUMapZone] = [
            ("main", [-126.0, -66.0, 24.0, 50.0], false, nil),
            ("AK", [170.0, -129.0, 50.0, 72.0], true, MUMapInsetLabel(text: "AK", x: 35, y: 620)),
            ("HI", [-161.0, -154.0, 18.0, 23.0], false, MUMapInsetLabel(text: "HI", x: 300, y: 620)),
        ].compactMap { id, ll, wrap, lbl in
            guard let sp = specs[id] else { return nil }
            return MUMapZone(id: id, projection: "albers", params: sp.parallels, bounds: sp.bounds, frame: sp.frame,
                             lonMin: ll[0], lonMax: ll[1], latMin: ll[2], latMax: ll[3],
                             antimeridianWrap: wrap, insetLabel: lbl, insetBox: nil)
        }
        let manifest = MUMapPackManifest(
            schemaVersion: 1, id: "us-admin1", aliases: ["us", "usa", "us-states"], version: "builtin",
            scope: "US", level: "admin1", codeSystem: "USPS 2-letter / ISO 3166-2:US",
            source: MUMapPackSource(name: "Natural Earth 1:50m Admin-1", url: "", version: "builtin", inputSha256: ""),
            license: MUMapPackLicense(spdx: "CC0-1.0 / Public Domain", attribution: "Natural Earth (Public Domain)", commercialAllowed: true),
            boundaryYear: 2022,
            complianceNote: "Natural Earth · Albers · AK/HI 插图 · 非导航地图",
            canvas: MUMapPackCanvas(width: 1000, height: 640, coordScale: 10),
            styleHints: MUMapPackStyleHints(featureStrokeWidth: 0.9, overlayStrokeWidth: 1.0, clipToCanvas: false, drawSeaByDefault: true),
            zones: zones, codesFile: "", codesSha256: "",
            geometry: MUMapPackGeometryMeta(file: "", sha256: "", bytes: 0, features: MUMapGeometry.us.count, rings: 0, vertices: 0, overlays: 0)
        )
        let features = MUMapGeometry.us.enumerated().map { idx, item in
            MUMapFeatureMeta(index: idx, code: item.code, name: item.code, zh: item.code, aliases: ["US-" + item.code])
        }
        return MUMapPackMetadata(manifest: manifest, directoryURL: nil, features: features)
    }

    private func buildBuiltinUSGeometry() -> MUMapDecodedGeometry {
        let ringsList = MUMapGeometry.us.map(\.rings)
        let verts = ringsList.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        return MUMapDecodedGeometry(features: ringsList, overlays: [], byteCost: verts * 16 + 4096)
    }
}
