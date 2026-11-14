#!/usr/bin/env python3
"""Build verified offline MapPack v1 bundles for MinisMod GeoMap.

Generates catalog.json + per-pack manifest.json, codes.tsv, and geometry.mump
into src/ios/Resources/MapPacks/ (or a custom output directory).

All upstream sources are open/public-domain or explicitly attributed open
licenses (no GADM, no GISCO non-commercial, no unlicensed China boundaries).
For China standard boundaries, supply an authorized GeoJSON explicitly via
`--cn-geojson <path> --cn-review-no <num> --output-dir <dir>`.
"""
import argparse
import gzip
import hashlib
import json
import math
import pathlib
import struct
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / 'src/ios/Resources/MapPacks'
DEFAULT_CACHE = pathlib.Path('/var/minis/workspace/geo-eval')

NE_COMMIT = 'ca96624a56bd078437bca8184e78163e5039ad19'
GB_COMMIT = '9469f09'

SOURCES = {
    'ne_50m_admin0': (
        f'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{NE_COMMIT}/geojson/ne_50m_admin_0_countries.geojson',
        'ne_50m_admin0.json',
        '3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb',
    ),
    'ne_50m_admin1': (
        f'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{NE_COMMIT}/geojson/ne_50m_admin_1_states_provinces.geojson',
        'ne_50m_admin1.json',
        '69a0e06e640b2d505858ae1cb63034e4677f3000b35a98e16312932b98c426b9',
    ),
    'ne_10m_admin0': (
        f'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{NE_COMMIT}/geojson/ne_10m_admin0_countries.geojson',
        'ne_10m_admin0.json',
        '239eec57ac17f100a11e2536cffc56752c318b50ae765b0918ff7aab4ce8f255',
    ),
    'ne_10m_admin1': (
        f'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/{NE_COMMIT}/geojson/ne_10m_admin_1_states_provinces.geojson',
        'ne_10m_admin1.json',
        '22d0e3ad85eb3e27f17cabf8ba2d50e554fbc27a87796ff891d958185da62fb5',
    ),
    'gb_GBR_ADM1': (
        f'https://github.com/wmgeolab/geoBoundaries/raw/{GB_COMMIT}/releaseData/gbOpen/GBR/ADM1/geoBoundaries-GBR-ADM1_simplified.geojson',
        'gb_GBR_ADM1_simplified.geojson',
        '85a05dc0e939aff5cca6d9b8bf0684efe6c098a54579b24531a3f5594a6e450e',
    ),
    'gb_FRA_ADM1': (
        f'https://github.com/wmgeolab/geoBoundaries/raw/{GB_COMMIT}/releaseData/gbOpen/FRA/ADM1/geoBoundaries-FRA-ADM1_simplified.geojson',
        'gb_FRA_ADM1_simplified.geojson',
        '7dc61e5c7e4c81f5fa10d339e6a5bc8428f1346f43f4426d9d165d2e44fc3a7e',
    ),
    'gb_ESP_ADM1': (
        f'https://github.com/wmgeolab/geoBoundaries/raw/{GB_COMMIT}/releaseData/gbOpen/ESP/ADM1/geoBoundaries-ESP-ADM1_simplified.geojson',
        'gb_ESP_ADM1_simplified.geojson',
        'b61a1bf661b90883763f633f5e9dbc27e7356309e42cbe56b60d2ceab5112f63',
    ),
    'gb_ITA_ADM2': (
        f'https://github.com/wmgeolab/geoBoundaries/raw/{GB_COMMIT}/releaseData/gbOpen/ITA/ADM2/geoBoundaries-ITA-ADM2_simplified.geojson',
        'gb_ITA_ADM2_simplified.geojson',
        'a01b6408d7d9061318034f8f4f54b377b99b5f8dcf5a7f84c5fa1e8ee3c86549',
    ),
    'census_county_2020': (
        'https://www2.census.gov/geo/tiger/GENZ2020/shp/cb_2020_us_county_20m.zip',
        'census_county_2020_20m.zip',
        '9394913edbd6f72791b06b84509e59ea2d275d10b73ae27ef87df3bdb061890c',
    ),
    'census_state_2020': (
        'https://www2.census.gov/geo/tiger/GENZ2020/shp/cb_2020_us_state_20m.zip',
        'census_state_2020_20m.zip',
        '1d872779cbfa2c2bf828850664aa9593a35844205e2e4bed5aeb78affb8da050',
    ),
}

# Projection math (must match Swift MUMapProjection 1:1)
def project_point(lon, lat, kind, params):
    if kind == 'albers':
        phi1, phi2, lon0, lat0 = params
        a, b, p0 = math.radians(phi1), math.radians(phi2), math.radians(lat0)
        dl = ((lon - lon0 + 180.0) % 360.0) - 180.0
        if dl <= -180.0:
            dl = 180.0 if lon > 0 else -180.0
        n = (math.sin(a) + math.sin(b)) / 2.0
        c = math.cos(a) ** 2 + 2.0 * n * math.sin(a)
        rho = math.sqrt(max(0.0, c - 2.0 * n * math.sin(math.radians(lat)))) / n
        rho0 = math.sqrt(max(0.0, c - 2.0 * n * math.sin(p0))) / n
        theta = n * math.radians(dl)
        return rho * math.sin(theta), rho0 - rho * math.cos(theta)
    if kind == 'laea':
        lon0, lat0 = params
        dl = ((lon - lon0 + 180.0) % 360.0) - 180.0
        if dl <= -180.0:
            dl = 180.0 if lon > 0 else -180.0
        l = math.radians(dl)
        p = math.radians(max(-89.999, min(89.999, lat)))
        p0 = math.radians(lat0)
        denom = 1.0 + math.sin(p0) * math.sin(p) + math.cos(p0) * math.cos(p) * math.cos(l)
        k = math.sqrt(2.0 / max(1e-9, denom))
        return k * math.cos(p) * math.sin(l), k * (math.cos(p0) * math.sin(p) - math.sin(p0) * math.cos(p) * math.cos(l))
    if kind == 'equalEarth':
        lon0 = params[0] if params else 0.0
        dl = ((lon - lon0 + 180.0) % 360.0) - 180.0
        if dl <= -180.0:
            dl = 180.0 if lon > 0 else -180.0
        phi = math.radians(max(-89.999, min(89.999, lat)))
        s = max(-1.0, min(1.0, math.sin(phi) * math.sqrt(3.0) / 2.0))
        t = math.asin(s)
        t2 = t * t
        t6 = t2 * t2 * t2
        t8 = t6 * t2
        a1, a2, a3, a4 = 1.340264, -0.081106, 0.000893, 0.003796
        x = (2.0 * math.sqrt(3.0) * math.radians(dl) * math.cos(t)) / (3.0 * (a1 + 3.0 * a2 * t2 + 7.0 * a3 * t6 + 9.0 * a4 * t8))
        y = t * (a1 + a2 * t2 + a3 * t6 + a4 * t8)
        return x, y
    raise ValueError(f'Unknown projection: {kind}')


def simplify_rdp(points, tolerance):
    if len(points) < 4 or tolerance <= 0:
        return points
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    t2 = tolerance * tolerance
    while stack:
        first, last = stack.pop()
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        d2 = dx * dx + dy * dy
        best, idx = 0.0, None
        for i in range(first + 1, last):
            x, y = points[i]
            u = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / d2)) if d2 else 0.0
            d = (x - ax - u * dx) ** 2 + (y - ay - u * dy) ** 2
            if d > best:
                best, idx = d, i
        if idx is not None and best > t2:
            keep.add(idx)
            stack.extend([(first, idx), (idx, last)])
    res = [points[i] for i in sorted(keep)]
    return res if len(res) >= 4 else (points[:3] + [points[0]])


def clip_polygon_rect(ring, xmin, ymin, xmax, ymax):
    """Sutherland-Hodgman clip of a closed ring against axis-aligned rect."""
    pts = ring[:-1] if len(ring) > 1 and ring[0] == ring[-1] else list(ring)
    if len(pts) < 3:
        return []

    def clip_edge(poly, inside, intersect):
        if not poly:
            return []
        out = []
        prev = poly[-1]
        prev_in = inside(prev)
        for cur in poly:
            cur_in = inside(cur)
            if cur_in:
                if not prev_in:
                    out.append(intersect(prev, cur))
                out.append(cur)
            elif prev_in:
                out.append(intersect(prev, cur))
            prev, prev_in = cur, cur_in
        return out

    def lerp_x(a, b, x):
        dx = b[0] - a[0]
        t = (x - a[0]) / dx if abs(dx) > 1e-12 else 0.0
        return (x, a[1] + t * (b[1] - a[1]))

    def lerp_y(a, b, y):
        dy = b[1] - a[1]
        t = (y - a[1]) / dy if abs(dy) > 1e-12 else 0.0
        return (a[0] + t * (b[0] - a[0]), y)

    pts = clip_edge(pts, lambda p: p[0] >= xmin, lambda a, b: lerp_x(a, b, xmin))
    pts = clip_edge(pts, lambda p: p[0] <= xmax, lambda a, b: lerp_x(a, b, xmax))
    pts = clip_edge(pts, lambda p: p[1] >= ymin, lambda a, b: lerp_y(a, b, ymin))
    pts = clip_edge(pts, lambda p: p[1] <= ymax, lambda a, b: lerp_y(a, b, ymax))
    if len(pts) < 3:
        return []
    if pts[0] != pts[-1]:
        pts.append(pts[0])
    # Check non-zero area
    area = sum(pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1] for i in range(len(pts) - 1))
    return pts if abs(area) > 1e-3 else []


def load_source(key, cache_dir):
    url, fn, expected_sha = SOURCES[key]
    p = cache_dir / fn
    if not p.exists():
        cache_dir.mkdir(parents=True, exist_ok=True)
        print(f'Downloading {key} -> {p.name} ...', flush=True)
        req = urllib.request.Request(url, headers={'User-Agent': 'MinisMod-MapPackBuilder/1.0'})
        with urllib.request.urlopen(req, timeout=120) as r:
            p.write_bytes(r.read())
    data = p.read_bytes()
    actual_sha = hashlib.sha256(data).hexdigest()
    assert actual_sha == expected_sha, f'{key} sha mismatch: {actual_sha} != {expected_sha}'
    return p, actual_sha


def read_shapefile_zip(zip_path):
    z = zipfile.ZipFile(zip_path)
    dbf = z.read([n for n in z.namelist() if n.endswith('.dbf')][0])
    shp = z.read([n for n in z.namelist() if n.endswith('.shp')][0])
    nrec, hdr_len, rec_len = struct.unpack('<IHH', dbf[4:12])
    fields = []
    pos = 32
    while pos < hdr_len - 1 and dbf[pos] != 0x0D:
        fields.append((dbf[pos:pos + 11].split(b'\x00', 1)[0].decode('ascii'), dbf[pos + 16]))
        pos += 32
    rows = []
    off = hdr_len
    for _ in range(nrec):
        rec = dbf[off + 1:off + rec_len]
        off += rec_len
        p = 0
        row = {}
        for fn, fl in fields:
            row[fn] = rec[p:p + fl].decode('utf-8', 'replace').strip()
            p += fl
        rows.append(row)
    geoms = []
    p = 100
    while p < len(shp):
        _, clen = struct.unpack('>II', shp[p:p + 8])
        body = shp[p + 8:p + 8 + clen * 2]
        stype = struct.unpack('<I', body[0:4])[0]
        polys = []
        if stype == 5:
            nparts, npts = struct.unpack('<II', body[36:44])
            parts = list(struct.unpack(f'<{nparts}I', body[44:44 + 4 * nparts]))
            pts_off = 44 + 4 * nparts
            pts = list(struct.iter_unpack('<dd', body[pts_off:pts_off + 16 * npts]))
            # Treat shapefile rings individually (even-odd fill handles holes natively)
            for i, s in enumerate(parts):
                e = parts[i + 1] if i + 1 < nparts else npts
                polys.append([pts[s:e]])
        geoms.append(polys)
        p += 8 + clen * 2
    assert len(rows) == len(geoms)
    return list(zip(rows, geoms))


def geojson_polys(geom):
    if geom['type'] == 'MultiPolygon':
        return geom['coordinates']
    if geom['type'] == 'Polygon':
        return [geom['coordinates']]
    return []


def poly_bbox(poly):
    xs = [pt[0] for ring in poly for pt in ring]
    ys = [pt[1] for ring in poly for pt in ring]
    return min(xs), min(ys), max(xs), max(ys)


def poly_bbox_area(poly):
    x0, y0, x1, y1 = poly_bbox(poly)
    return (x1 - x0) * (y1 - y0)


def normalize_pt(x, y, bounds, frame):
    x0, y0, x1, y1 = bounds
    fx, fy, fw, fh = frame
    scale = min(fw / (x1 - x0), fh / (y1 - y0))
    nx = fx + (fw - (x1 - x0) * scale) / 2.0 + (x - x0) * scale
    ny = fy + (fh - (y1 - y0) * scale) / 2.0 + (y1 - y) * scale
    return nx, ny


def encode_mump(coord_scale, feature_rings_list, overlays):
    """Encode MUMP v1 little-endian binary."""
    buf = bytearray()
    feat_recs = bytearray()
    ring_recs = bytearray()
    vert_recs = bytearray()
    ov_recs = bytearray()
    ov_vert_recs = bytearray()

    ring_cursor = 0
    vert_cursor = 0
    for rings in feature_rings_list:
        feat_recs += struct.pack('<IHH', ring_cursor, len(rings), 0)
        ring_cursor += len(rings)
        for ring in rings:
            ring_recs += struct.pack('<II', vert_cursor, len(ring))
            vert_cursor += len(ring)
            for x, y in ring:
                qx = int(round(x * coord_scale))
                qy = int(round(y * coord_scale))
                assert -32768 <= qx <= 32767 and -32768 <= qy <= 32767, f'Coord overflow: {x},{y}'
                vert_recs += struct.pack('<hh', qx, qy)

    ov_vert_cursor = 0
    for kind, closed, pts in overlays:
        ov_recs += struct.pack('<HHII', kind, 1 if closed else 0, ov_vert_cursor, len(pts))
        ov_vert_cursor += len(pts)
        for x, y in pts:
            qx = int(round(x * coord_scale))
            qy = int(round(y * coord_scale))
            assert -32768 <= qx <= 32767 and -32768 <= qy <= 32767, f'Overlay overflow: {x},{y}'
            ov_vert_recs += struct.pack('<hh', qx, qy)

    header = struct.pack(
        '<4sHHfIIIII',
        b'MUMP',
        1,
        0,
        float(coord_scale),
        len(feature_rings_list),
        ring_cursor,
        vert_cursor,
        len(overlays),
        ov_vert_cursor,
    )
    buf += header + feat_recs + ring_recs + vert_recs + ov_recs + ov_vert_recs
    return bytes(buf), ring_cursor, vert_cursor


def finalize_aliases(items):
    """Ensure aliases are deduplicated and globally unambiguous across features."""
    canon_set = {it['code'].upper() for it in items}
    alias_owners = {}
    for it in items:
        seen_local = set()
        for a in it['raw_aliases']:
            if not a:
                continue
            al = str(a).strip()
            if not al:
                continue
            key = al.upper()
            if key in canon_set or key in seen_local:
                continue
            seen_local.add(key)
            alias_owners.setdefault(key, []).append(it['code'])
    out = []
    for it in items:
        good = []
        seen_local = set()
        for a in it['raw_aliases']:
            if not a:
                continue
            al = str(a).strip()
            if not al:
                continue
            key = al.upper()
            if key in canon_set or key in seen_local:
                continue
            if len(alias_owners.get(key, [])) == 1:
                seen_local.add(key)
                good.append(al)
        out.append((it['code'], it['name'], it['zh'], good))
    return out


def write_pack(out_dir, spec):
    pdir = out_dir / spec['id']
    pdir.mkdir(parents=True, exist_ok=True)
    coord_scale = spec['canvas']['coordScale']
    mump_bytes, ring_cnt, vert_cnt = encode_mump(
        coord_scale,
        [f['rings'] for f in spec['features']],
        spec.get('overlays', []),
    )
    code_rows = finalize_aliases(spec['features'])
    tsv_lines = []
    for code, name, zh, aliases in code_rows:
        safe_name = name.replace('\t', ' ').replace('\n', ' ')
        safe_zh = zh.replace('\t', ' ').replace('\n', ' ')
        safe_aliases = '|'.join(a.replace('\t', ' ').replace('\n', ' ').replace('|', '/') for a in aliases)
        tsv_lines.append(f'{code}\t{safe_name}\t{safe_zh}\t{safe_aliases}')
    tsv_bytes = ('\n'.join(tsv_lines) + '\n').encode('utf-8')

    mump_sha = hashlib.sha256(mump_bytes).hexdigest()
    tsv_sha = hashlib.sha256(tsv_bytes).hexdigest()

    manifest = {
        'schemaVersion': 1,
        'id': spec['id'],
        'aliases': spec['aliases'],
        'version': '2026.11.1',
        'scope': spec['scope'],
        'level': spec['level'],
        'codeSystem': spec['codeSystem'],
        'source': spec['source'],
        'license': spec['license'],
        'boundaryYear': spec['boundaryYear'],
        'complianceNote': spec['complianceNote'],
        'canvas': spec['canvas'],
        'styleHints': spec['styleHints'],
        'zones': spec['zones'],
        'codesFile': 'codes.tsv',
        'codesSha256': tsv_sha,
        'geometry': {
            'file': 'geometry.mump',
            'sha256': mump_sha,
            'bytes': len(mump_bytes),
            'features': len(spec['features']),
            'rings': ring_cnt,
            'vertices': vert_cnt,
            'overlays': len(spec.get('overlays', [])),
        },
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    (pdir / 'geometry.mump').write_bytes(mump_bytes)
    (pdir / 'codes.tsv').write_bytes(tsv_bytes)
    (pdir / 'manifest.json').write_bytes(manifest_bytes)

    return {
        'id': spec['id'],
        'aliases': spec['aliases'],
        'level': spec['level'],
        'manifestFile': f"{spec['id']}/manifest.json",
        'manifestSha256': manifest_sha,
        'codesFile': f"{spec['id']}/codes.tsv",
        'codesSha256': tsv_sha,
        'geometryFile': f"{spec['id']}/geometry.mump",
        'geometrySha256': mump_sha,
        'featureCount': len(spec['features']),
        'ringCount': ring_cnt,
        'vertexCount': vert_cnt,
        'geometryBytes': len(mump_bytes),
        'codesBytes': len(tsv_bytes),
    }



def _clip_half(pts, keep, cut):
    out = []
    for i in range(len(pts)):
        cur = pts[i]
        prev = pts[i - 1]
        ck, pk = keep(cur), keep(prev)
        if ck:
            if not pk:
                out.append(cut(prev, cur))
            out.append(cur)
        elif pk:
            out.append(cut(prev, cur))
    return out


def clip_ring_lon(ring, lo, hi):
    """Sutherland-Hodgman clip of a lon/lat ring to a longitude window."""
    pts = list(ring)
    pts = _clip_half(pts, lambda q: q[0] >= lo,
                     lambda a, b: (lo, a[1] + (lo - a[0]) / (b[0] - a[0]) * (b[1] - a[1])))
    if not pts:
        return []
    pts = _clip_half(pts, lambda q: q[0] <= hi,
                     lambda a, b: (hi, a[1] + (hi - a[0]) / (b[0] - a[0]) * (b[1] - a[1])))
    if not pts:
        return []
    if pts[0] != pts[-1]:
        pts.append(pts[0])
    return pts


def split_antimeridian(ring):
    """Split a ring whose longitudes jump across +/-180 into non-crossing rings."""
    if len(ring) < 3:
        return [ring]
    if not any(abs(a[0] - b[0]) > 180.0 for a, b in zip(ring, ring[1:] + ring[:1])):
        return [ring]
    un = [ring[0]]
    for pt in ring[1:]:
        lon = pt[0]
        while lon - un[-1][0] > 180.0:
            lon -= 360.0
        while lon - un[-1][0] < -180.0:
            lon += 360.0
        un.append((lon, pt[1]))
    lons = [q[0] for q in un]
    kmin = int(math.floor((min(lons) + 180.0) / 360.0))
    kmax = int(math.floor((max(lons) + 180.0) / 360.0))
    pieces = []
    for k in range(kmin, kmax + 1):
        shifted = [(lon - 360.0 * k, lat) for lon, lat in un]
        clipped = clip_ring_lon(shifted, -180.0, 180.0)
        if clipped and len(clipped) >= 4:
            pieces.append(clipped)
    return pieces or [ring]


def process_polygons(polys, zone_kind, zone_params, tol, filter_fn=None):
    """Project GeoJSON polygons, filter parts, and simplify rings."""
    out = []
    for poly in polys:
        outer = poly[0]
        if filter_fn and not filter_fn(outer):
            continue
        pieces = split_antimeridian(outer)
        for pi, piece in enumerate(pieces):
            src_rings = [piece] + (poly[1:] if len(pieces) == 1 else [])
            proj_rings = []
            for ring in src_rings:
                if len(ring) < 3:
                    continue
                pts = [project_point(pt[0], pt[1], zone_kind, zone_params) for pt in ring]
                if zone_kind == 'equalEarth':
                    for a, b in zip(ring, ring[1:]):
                        if abs(a[0] - b[0]) > 180.5:
                            raise ValueError(f'Unsplit antimeridian jump: {a[0]} -> {b[0]}')
                proj_rings.append(pts)
            if not proj_rings:
                continue
            out.append(proj_rings)
    # Sort polygons descending by bbox area so primary landmass is index 0
    out.sort(key=lambda p: poly_bbox_area(p), reverse=True)
    return out


def finalize_feature_rings(polys_by_zone, bounds_by_zone, frames_by_zone, tol_by_zone,
                           speck_px=0.5, clip_rect=None, keep_tiny_primary=True):
    """Simplify, normalize to canvas, optionally clip, and drop tiny specks."""
    final_rings = []
    for zone_id, polys in polys_by_zone:
        bounds = bounds_by_zone[zone_id]
        frame = frames_by_zone[zone_id]
        tol = tol_by_zone.get(zone_id, tol_by_zone['*']) if isinstance(tol_by_zone, dict) else tol_by_zone
        for p_idx, poly in enumerate(polys):
            norm_poly = []
            for r_idx, ring in enumerate(poly):
                s = simplify_rdp(ring, tol)
                norm = [normalize_pt(x, y, bounds, frame) for x, y in s]
                if clip_rect is not None:
                    norm = clip_polygon_rect(norm, *clip_rect)
                    if not norm:
                        continue
                xs = [p[0] for p in norm]
                ys = [p[1] for p in norm]
                w, h = max(xs) - min(xs), max(ys) - min(ys)
                if r_idx == 0:
                    if w < speck_px and h < speck_px:
                        if not (keep_tiny_primary and p_idx == 0):
                            norm_poly = []
                            break
                else:
                    if w < 0.8 and h < 0.8:
                        continue
                if len(norm) >= 4:
                    norm_poly.append(norm)
            if norm_poly:
                final_rings.extend(norm_poly)
    return final_rings


def compute_zone_bounds(zone_points):
    bounds = {}
    for k, pts in zone_points.items():
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        bounds[k] = [min(xs), min(ys), max(xs), max(ys)]
    return bounds


def build_us_admin1(cache_dir):
    p, sha = load_source('ne_50m_admin1', cache_dir)
    raw = json.loads(p.read_bytes())
    feats = [f for f in raw['features'] if f['properties'].get('admin') == 'United States of America']
    assert len(feats) == 51
    zones_cfg = {
        'main': ('albers', [29.5, 45.5, -96.0, 23.0], [20, 0, 960, 520], [-126.0, -66.0, 24.0, 50.0], False, None),
        'AK': ('albers', [55.0, 65.0, -154.0, 50.0], [30, 445, 240, 175], [170.0, -129.0, 50.0, 72.0], True, {'text': 'AK', 'x': 35, 'y': 620}),
        'HI': ('albers', [8.0, 18.0, -157.0, 13.0], [300, 540, 145, 80], [-161.0, -154.0, 18.0, 23.0], False, {'text': 'HI', 'x': 300, 'y': 620}),
    }
    zh_names = {
        'AL': '亚拉巴马州', 'AK': '阿拉斯加州', 'AZ': '亚利桑那州', 'AR': '阿肯色州', 'CA': '加利福尼亚州',
        'CO': '科罗拉多州', 'CT': '康涅狄格州', 'DE': '特拉华州', 'DC': '华盛顿特区', 'FL': '佛罗里达州',
        'GA': '佐治亚州', 'HI': '夏威夷州', 'ID': '爱达荷州', 'IL': '伊利诺伊州', 'IN': '印第安纳州',
        'IA': '艾奥瓦州', 'KS': '堪萨斯州', 'KY': '肯塔基州', 'LA': '路易斯安那州', 'ME': '缅因州',
        'MD': '马里兰州', 'MA': '马萨诸塞州', 'MI': '密歇根州', 'MN': '明尼苏达州', 'MS': '密西西比州',
        'MO': '密苏里州', 'MT': '蒙大拿州', 'NE': '内布拉斯加州', 'NV': '内华达州', 'NH': '新罕布什尔州',
        'NJ': '新泽西州', 'NM': '新墨西哥州', 'NY': '纽约州', 'NC': '北卡罗来纳州', 'ND': '北达科他州',
        'OH': '俄亥俄州', 'OK': '俄克拉荷马州', 'OR': '俄勒冈州', 'PA': '宾夕法尼亚州', 'RI': '罗得岛州',
        'SC': '南卡罗来纳州', 'SD': '南达科他州', 'TN': '田纳西州', 'TX': '得克萨斯州', 'UT': '犹他州',
        'VT': '佛蒙特州', 'VA': '弗吉尼亚州', 'WA': '华盛顿州', 'WV': '西弗吉尼亚州', 'WI': '威斯康星州',
        'WY': '怀俄明州',
    }
    zone_pts = {k: [] for k in zones_cfg}
    items = []
    for f in sorted(feats, key=lambda x: x['properties']['postal']):
        pr = f['properties']
        code = pr['postal']
        zk = code if code in ('AK', 'HI') else 'main'
        proj, params = zones_cfg[zk][0], zones_cfg[zk][1]
        polys = process_polygons(geojson_polys(f['geometry']), proj, params, 0.00045)
        for poly in polys:
            for r in poly:
                zone_pts[zk].extend(r)
        items.append({
            'code': code,
            'name': pr.get('name') or code,
            'zh': zh_names.get(code, pr.get('name') or code),
            'raw_aliases': [f'US-{code}', pr.get('name', ''), zh_names.get(code, '')],
            'zone': zk,
            'polys': polys,
        })
    bounds = compute_zone_bounds(zone_pts)
    frames = {k: v[2] for k, v in zones_cfg.items()}
    features = []
    for it in items:
        rings = finalize_feature_rings([(it['zone'], it['polys'])], bounds, frames, 0.00045, speck_px=0.25, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})
    zones = []
    for zk, (proj, params, frame, ll, wrap, lbl) in zones_cfg.items():
        zones.append({
            'id': zk, 'projection': proj, 'params': params, 'bounds': bounds[zk], 'frame': frame,
            'lonMin': ll[0], 'lonMax': ll[1], 'latMin': ll[2], 'latMax': ll[3],
            'antimeridianWrap': wrap, 'insetLabel': lbl, 'insetBox': None,
        })
    return {
        'id': 'us-admin1',
        'aliases': ['us', 'usa', 'us-states'],
        'scope': 'US',
        'level': 'admin1',
        'codeSystem': 'USPS 2-letter / ISO 3166-2:US',
        'source': {'name': 'Natural Earth 1:10m Admin-1', 'url': SOURCES['ne_50m_admin1'][0], 'version': NE_COMMIT[:8], 'inputSha256': sha},
        'license': {'spdx': 'CC0-1.0 / Public Domain', 'attribution': 'Natural Earth (Public Domain)', 'commercialAllowed': True},
        'boundaryYear': 2022,
        'complianceNote': 'Natural Earth · Albers · AK/HI 插图 · 非导航地图',
        'canvas': {'width': 1000.0, 'height': 640.0, 'coordScale': 10.0},
        'styleHints': {'featureStrokeWidth': 0.9, 'overlayStrokeWidth': 1.0, 'clipToCanvas': False, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': [],
    }


def build_world_admin0(cache_dir):
    p, sha = load_source('ne_10m_admin0', cache_dir)
    raw = json.loads(p.read_bytes())
    zh_overrides = {
        'CN': '中国', 'TW': '台湾', 'HK': '香港', 'MO': '澳门', 'KR': '韩国', 'KP': '朝鲜',
        'AE': '阿联酋', 'BA': '波黑', 'CD': '刚果(金)', 'CG': '刚果(布)', 'CF': '中非',
        'IOA': '澳属印度洋领地', 'US': '美国', 'GB': '英国', 'RU': '俄罗斯', 'FR': '法国',
        'DE': '德国', 'JP': '日本', 'IN': '印度', 'BR': '巴西', 'CA': '加拿大', 'AU': '澳大利亚',
    }
    extra_aliases = {
        'GB': ['UK', 'GBR', 'United Kingdom', 'Great Britain'],
        'US': ['USA', 'United States', 'United States of America'],
        'CN': ['CHN', 'PRC', 'China', '中华人民共和国'],
        'TW': ['TWN', 'Taiwan', '中国台湾', '台湾省'],
        'KR': ['KOR', 'South Korea', 'Republic of Korea', '大韩民国'],
        'KP': ['PRK', 'North Korea', '朝鲜民主主义人民共和国'],
        'RU': ['RUS', 'Russia', 'Russian Federation'],
        'AE': ['ARE', 'UAE', 'United Arab Emirates', '阿拉伯联合酋长国'],
        'XK': ['KOS', 'XKX', 'Kosovo', '科索沃'],
    }
    zone_pts = []
    items = []
    seen_codes = set()
    for f in raw['features']:
        pr = f['properties']
        a2, eh, a3 = pr.get('ISO_A2'), pr.get('ISO_A2_EH'), pr.get('ADM0_A3')
        if a3 == 'ATA' or eh == 'AQ':
            continue
        if a2 and a2 not in ('-99', '') and len(a2) == 2:
            code = a2
        elif a3 in ('IOA', 'ATC', 'SOL', 'CYN', 'KAS'):
            code = a3
        elif eh and eh not in ('-99', '') and len(eh) == 2:
            code = eh
        else:
            code = a3
        assert code, f'Missing world code: {pr.get("NAME")}'
        polys = process_polygons(geojson_polys(f['geometry']), 'equalEarth', [0.0], 0.00045)
        for poly in polys:
            for r in poly:
                zone_pts.extend(r)
        _dup = next((it for it in items if it['code'] == code), None)
        if _dup is not None:
            _dup['polys'].extend(polys)
            continue
        seen_codes.add(code)
        name = pr.get('NAME') or code
        zh = zh_overrides.get(code, pr.get('NAME_ZH') or name)
        aliases = [a3, name, pr.get('NAME_LONG', ''), pr.get('FORMAL_EN', ''), pr.get('NAME_ZH', ''), zh]
        aliases += extra_aliases.get(code, [])
        items.append({'code': code, 'name': name, 'zh': zh, 'raw_aliases': aliases, 'polys': polys})
    items.sort(key=lambda x: x['code'])
    bounds = compute_zone_bounds({'main': zone_pts})
    frames = {'main': [12, 10, 976, 490]}
    features = []
    for it in items:
        rings = finalize_feature_rings([('main', it['polys'])], bounds, frames, 0.00045, speck_px=0.45, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})
    zones = [{
        'id': 'main', 'projection': 'equalEarth', 'params': [0.0], 'bounds': bounds['main'], 'frame': frames['main'],
        'lonMin': -180.0, 'lonMax': 180.0, 'latMin': -60.0, 'latMax': 85.0,
        'antimeridianWrap': False, 'insetLabel': None, 'insetBox': None,
    }]
    return {
        'id': 'world-admin0',
        'aliases': ['world', 'global', 'world-countries'],
        'scope': 'world',
        'level': 'admin0',
        'codeSystem': 'ISO 3166-1 alpha-2 (+ Natural Earth codes)',
        'source': {'name': 'Natural Earth 1:10m Admin-0 (excl. Antarctica)', 'url': SOURCES['ne_10m_admin0'][0], 'version': NE_COMMIT[:8], 'inputSha256': sha},
        'license': {'spdx': 'CC0-1.0 / Public Domain', 'attribution': 'Natural Earth (Public Domain)', 'commercialAllowed': True},
        'boundaryYear': 2022,
        'complianceNote': 'Natural Earth 1:10m · Equal Earth · 制图概览边界，非标准国界或导航地图',
        'canvas': {'width': 1000.0, 'height': 510.0, 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.55, 'overlayStrokeWidth': 0.8, 'clipToCanvas': True, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': [],
    }


def build_europe_admin0(cache_dir):
    p, sha = load_source('ne_10m_admin0', cache_dir)
    raw = json.loads(p.read_bytes())
    eu_codes = {
        'AD','AL','AT','BA','BE','BG','BY','CH','CY','CZ','DE','DK','EE','ES','FI','FR','GB','GR','HR','HU',
        'IE','IS','IT','LI','LT','LU','LV','MC','MD','ME','MK','MT','NL','NO','PL','PT','RO','RS','RU','SE',
        'SI','SK','SM','TR','UA','VA','XK',
    }
    zh_overrides = {'GB': '英国', 'BA': '波黑', 'RU': '俄罗斯', 'FR': '法国', 'DE': '德国', 'XK': '科索沃'}
    extra_aliases = {'GB': ['UK', 'GBR', 'United Kingdom'], 'XK': ['KOS', 'Kosovo']}
    # Define fixed geographic framing corners in LAEA (10E, 52N) covering Iceland to Urals, Malta/Cyprus to N. Cape
    corners = [(-24.5, 63.0), (-9.8, 35.8), (10.0, 34.0), (43.0, 34.5), (33.0, 71.5), (10.0, 71.8), (46.0, 56.0)]
    proj_corners = [project_point(lo, la, 'laea', [10.0, 52.0]) for lo, la in corners]
    bounds = {'main': [
        min(pt[0] for pt in proj_corners),
        min(pt[1] for pt in proj_corners),
        max(pt[0] for pt in proj_corners),
        max(pt[1] for pt in proj_corners),
    ]}
    frames = {'main': [10, 10, 980, 740]}

    def in_europe_poly(ring):
        xs = [pt[0] for pt in ring]
        ys = [pt[1] for pt in ring]
        # Keep polygons that intersect geographic Europe (excludes French Guiana, Caribbean, Svalbard, Kurils, Canary Is.)
        return max(xs) >= -26.0 and min(xs) <= 60.0 and max(ys) >= 34.0 and min(ys) <= 72.2

    items = []
    seen = set()
    for f in raw['features']:
        pr = f['properties']
        a2, eh, a3 = pr.get('ISO_A2'), pr.get('ISO_A2_EH'), pr.get('ADM0_A3')
        code = a2 if (a2 and a2 not in ('-99', '') and len(a2) == 2) else (eh if eh not in ('-99', '') else a3)
        if code not in eu_codes or code in seen:
            continue
        seen.add(code)
        polys = process_polygons(geojson_polys(f['geometry']), 'laea', [10.0, 52.0], 0.0003, filter_fn=in_europe_poly)
        if not polys:
            continue
        name = pr.get('NAME') or code
        zh = zh_overrides.get(code, pr.get('NAME_ZH') or name)
        aliases = [a3, name, pr.get('NAME_ZH', ''), zh] + extra_aliases.get(code, [])
        items.append({'code': code, 'name': name, 'zh': zh, 'raw_aliases': aliases, 'polys': polys})
    items.sort(key=lambda x: x['code'])
    features = []
    for it in items:
        rings = finalize_feature_rings(
            [('main', it['polys'])], bounds, frames, 0.0003, speck_px=0.5,
            clip_rect=(10.0, 10.0, 990.0, 750.0), keep_tiny_primary=True,
        )
        if rings:
            features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})
    zones = [{
        'id': 'main', 'projection': 'laea', 'params': [10.0, 52.0], 'bounds': bounds['main'], 'frame': frames['main'],
        'lonMin': -25.0, 'lonMax': 48.0, 'latMin': 34.0, 'latMax': 72.0,
        'antimeridianWrap': False, 'insetLabel': None, 'insetBox': None,
    }]
    return {
        'id': 'europe-admin0',
        'aliases': ['eu', 'europe', 'eu-admin0'],
        'scope': 'europe',
        'level': 'admin0',
        'codeSystem': 'ISO 3166-1 alpha-2',
        'source': {'name': 'Natural Earth 1:10m Admin-0 (Europe framing)', 'url': SOURCES['ne_10m_admin0'][0], 'version': NE_COMMIT[:8], 'inputSha256': sha},
        'license': {'spdx': 'CC0-1.0 / Public Domain', 'attribution': 'Natural Earth (Public Domain)', 'commercialAllowed': True},
        'boundaryYear': 2022,
        'complianceNote': 'Natural Earth 1:10m · LAEA 等积方位投影（含欧洲大陆及主要岛屿）· 非导航地图',
        'canvas': {'width': 1000.0, 'height': 760.0, 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.75, 'overlayStrokeWidth': 0.9, 'clipToCanvas': True, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': [],
    }


def build_ne_admin1_country(cache_dir, spec_cfg):
    p, sha = load_source('ne_10m_admin1', cache_dir)
    raw = json.loads(p.read_bytes())
    feats = [f for f in raw['features'] if f['properties'].get('admin') == spec_cfg['admin']]
    grouped = {}
    for f in feats:
        pr = f['properties']
        code = pr.get('iso_3166_2')
        if not code or '~' in code or code in spec_cfg.get('exclude_codes', ()):
            continue
        grouped.setdefault(code, {'props': pr, 'polys': []})
        grouped[code]['polys'].extend(geojson_polys(f['geometry']))

    zone_pts = {z['id']: [] for z in spec_cfg['zones']}
    items = []
    for code, entry in sorted(grouped.items()):
        pr = entry['props']
        zcfg = spec_cfg['zone_for'](code)
        zid = zcfg['id']
        polys = process_polygons(entry['polys'], zcfg['projection'], zcfg['params'], spec_cfg['tol'], filter_fn=spec_cfg.get('poly_filter'))
        if not polys:
            continue
        for poly in polys:
            for r in poly:
                zone_pts[zid].extend(r)
        short = code.split('-', 1)[1] if '-' in code else code
        name = pr.get('name') or code
        zh = pr.get('name_zh') or name
        aliases = [short, name, pr.get('name_en', ''), pr.get('name_local', ''), zh]
        items.append({'code': code, 'name': name, 'zh': zh, 'raw_aliases': aliases, 'zone': zid, 'polys': polys})

    bounds = compute_zone_bounds(zone_pts)
    frames = {z['id']: z['frame'] for z in spec_cfg['zones']}
    features = []
    for it in items:
        rings = finalize_feature_rings([(it['zone'], it['polys'])], bounds, frames, spec_cfg['tol'], speck_px=0.8, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})

    zones = []
    for z in spec_cfg['zones']:
        zones.append({
            'id': z['id'], 'projection': z['projection'], 'params': z['params'],
            'bounds': bounds[z['id']], 'frame': z['frame'],
            'lonMin': z['ll'][0], 'lonMax': z['ll'][1], 'latMin': z['ll'][2], 'latMax': z['ll'][3],
            'antimeridianWrap': False, 'insetLabel': z.get('insetLabel'), 'insetBox': z.get('insetBox'),
        })
    overlays = []
    for z in spec_cfg['zones']:
        if z.get('insetBox'):
            x, y, w, h = z['insetBox']
            overlays.append((1, True, [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]))

    return {
        'id': spec_cfg['id'],
        'aliases': spec_cfg['aliases'],
        'scope': spec_cfg['scope'],
        'level': 'admin1',
        'codeSystem': f"ISO 3166-2:{spec_cfg['scope']}",
        'source': {'name': 'Natural Earth 1:10m Admin-1', 'url': SOURCES['ne_10m_admin1'][0], 'version': NE_COMMIT[:8], 'inputSha256': sha},
        'license': {'spdx': 'CC0-1.0 / Public Domain', 'attribution': 'Natural Earth (Public Domain)', 'commercialAllowed': True},
        'boundaryYear': 2022,
        'complianceNote': spec_cfg['note'],
        'canvas': {'width': 1000.0, 'height': spec_cfg['height'], 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.75, 'overlayStrokeWidth': 0.9, 'clipToCanvas': False, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': overlays,
    }


def build_geoboundaries_country(cache_dir, cfg):
    p, sha = load_source(cfg['source_key'], cache_dir)
    raw = json.loads(p.read_bytes())
    zone_pts = {z['id']: [] for z in cfg['zones']}
    items = []
    for f in raw['features']:
        sname = f['properties'].get('shapeName', '')
        meta = cfg['map_feature'](sname, f['properties'])
        if meta is None:
            continue
        code, name, zh, extra_aliases, zid = meta
        zcfg = next(z for z in cfg['zones'] if z['id'] == zid)
        polys = process_polygons(geojson_polys(f['geometry']), zcfg['projection'], zcfg['params'], cfg['tol'])
        for poly in polys:
            for r in poly:
                zone_pts[zid].extend(r)
        short = code.split('-', 1)[1] if '-' in code else code
        items.append({'code': code, 'name': name, 'zh': zh, 'raw_aliases': [short, sname, name, zh] + extra_aliases, 'zone': zid, 'polys': polys})
    items.sort(key=lambda x: x['code'])
    bounds = compute_zone_bounds(zone_pts)
    frames = {z['id']: z['frame'] for z in cfg['zones']}
    features = []
    for it in items:
        rings = finalize_feature_rings([(it['zone'], it['polys'])], bounds, frames, cfg['tol'], speck_px=0.8, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})
    zones = []
    for z in cfg['zones']:
        zones.append({
            'id': z['id'], 'projection': z['projection'], 'params': z['params'],
            'bounds': bounds[z['id']], 'frame': z['frame'],
            'lonMin': z['ll'][0], 'lonMax': z['ll'][1], 'latMin': z['ll'][2], 'latMax': z['ll'][3],
            'antimeridianWrap': False, 'insetLabel': z.get('insetLabel'), 'insetBox': z.get('insetBox'),
        })
    overlays = []
    for z in cfg['zones']:
        if z.get('insetBox'):
            x, y, w, h = z['insetBox']
            overlays.append((1, True, [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]))
    return {
        'id': cfg['id'],
        'aliases': cfg['aliases'],
        'scope': cfg['scope'],
        'level': 'admin1',
        'codeSystem': f"ISO 3166-2:{cfg['scope']}",
        'source': {'name': cfg['source_name'], 'url': SOURCES[cfg['source_key']][0], 'version': GB_COMMIT, 'inputSha256': sha},
        'license': cfg['license'],
        'boundaryYear': cfg['year'],
        'complianceNote': cfg['note'],
        'canvas': {'width': 1000.0, 'height': cfg['height'], 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.75, 'overlayStrokeWidth': 0.9, 'clipToCanvas': False, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': overlays,
    }


def build_us_county(cache_dir):
    cp, csha = load_source('census_county_2020', cache_dir)
    sp, _ = load_source('census_state_2020', cache_dir)
    county_rows = [(r, g) for r, g in read_shapefile_zip(cp) if r['STUSPS'] != 'PR']
    state_rows = [(r, g) for r, g in read_shapefile_zip(sp) if r['STUSPS'] not in ('PR', 'VI', 'GU', 'MP', 'AS')]
    assert len(county_rows) == 3143
    zones_cfg = {
        'main': ('albers', [29.5, 45.5, -96.0, 23.0], [20, 0, 960, 520], [-126.0, -66.0, 24.0, 50.0], False, None),
        'AK': ('albers', [55.0, 65.0, -154.0, 50.0], [30, 445, 240, 175], [170.0, -129.0, 50.0, 72.0], True, {'text': 'AK', 'x': 35, 'y': 620}),
        'HI': ('albers', [8.0, 18.0, -157.0, 13.0], [300, 540, 145, 80], [-161.0, -154.0, 18.0, 23.0], False, {'text': 'HI', 'x': 300, 'y': 620}),
    }
    zone_pts = {k: [] for k in zones_cfg}
    items = []
    for row, polys in county_rows:
        st = row['STUSPS']
        zk = st if st in ('AK', 'HI') else 'main'
        proj, params = zones_cfg[zk][0], zones_cfg[zk][1]
        ppolys = process_polygons(polys, proj, params, 0.0003)
        for poly in ppolys:
            for r in poly:
                zone_pts[zk].extend(r)
        geoid = row['GEOID']
        name = row['NAME']
        lsad_name = row['NAMELSAD']
        disp = f'{lsad_name}, {st}'
        aliases = [
            f'US-{geoid}',
            f'{st}:{lsad_name}',
            f'{st}:{name}',
            f'{lsad_name}, {st}',
            f'{name}, {st}',
        ]
        items.append({'code': geoid, 'name': disp, 'zh': disp, 'raw_aliases': aliases, 'zone': zk, 'polys': ppolys})
    items.sort(key=lambda x: x['code'])
    bounds = compute_zone_bounds(zone_pts)
    frames = {k: v[2] for k, v in zones_cfg.items()}
    features = []
    for it in items:
        rings = finalize_feature_rings([(it['zone'], it['polys'])], bounds, frames, 0.0003, speck_px=0.25, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'], 'raw_aliases': it['raw_aliases'], 'rings': rings})

    # State boundary overlays in exact same bounds/frames
    overlays = []
    for row, polys in state_rows:
        st = row['STUSPS']
        zk = st if st in ('AK', 'HI') else 'main'
        proj, params = zones_cfg[zk][0], zones_cfg[zk][1]
        ppolys = process_polygons(polys, proj, params, 0.00045)
        srings = finalize_feature_rings([(zk, ppolys)], bounds, frames, 0.00045, speck_px=0.5, keep_tiny_primary=True)
        for sr in srings:
            overlays.append((0, True, sr))

    zones = []
    for zk, (proj, params, frame, ll, wrap, lbl) in zones_cfg.items():
        zones.append({
            'id': zk, 'projection': proj, 'params': params, 'bounds': bounds[zk], 'frame': frame,
            'lonMin': ll[0], 'lonMax': ll[1], 'latMin': ll[2], 'latMax': ll[3],
            'antimeridianWrap': wrap, 'insetLabel': lbl, 'insetBox': None,
        })
    return {
        'id': 'us-county',
        'aliases': ['us-counties', 'us-admin2'],
        'scope': 'US',
        'level': 'admin2',
        'codeSystem': 'US County FIPS 2020 (5-digit GEOID)',
        'source': {'name': 'US Census Cartographic Boundary 2020 (1:20m)', 'url': SOURCES['census_county_2020'][0], 'version': '2020-20m', 'inputSha256': csha},
        'license': {'spdx': 'Public Domain (17 U.S.C. § 105)', 'attribution': 'U.S. Census Bureau (Public Domain)', 'commercialAllowed': True},
        'boundaryYear': 2020,
        'complianceNote': 'US Census 2020 · 3,143 县 · Albers · AK/HI 插图 · 非导航地图',
        'canvas': {'width': 1000.0, 'height': 640.0, 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.25, 'overlayStrokeWidth': 0.85, 'clipToCanvas': False, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': overlays,
    }


def major_ne_configs():
    return [
        {
            'id': 'de-admin1', 'aliases': ['de', 'germany'], 'scope': 'DE', 'admin': 'Germany',
            'height': 780.0, 'tol': 0.00035,
            'note': 'Natural Earth 1:10m · Albers · 德国16州 · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [48.0, 54.0, 10.5, 51.0], 'frame': [20, 15, 960, 750], 'll': [5.5, 15.5, 47.0, 55.2]}],
            'zone_for': lambda c: {'id': 'main', 'projection': 'albers', 'params': [48.0, 54.0, 10.5, 51.0]},
        },
        {
            'id': 'jp-admin1', 'aliases': ['jp', 'japan'], 'scope': 'JP', 'admin': 'Japan',
            'height': 740.0, 'tol': 0.00045,
            'note': 'Natural Earth 1:10m · Albers · 冲绳插图 · 非导航地图',
            'zones': [
                {'id': 'main', 'projection': 'albers', 'params': [33.0, 42.0, 137.0, 37.5], 'frame': [140, 15, 840, 710], 'll': [128.0, 146.5, 29.5, 46.0]},
                {'id': 'Okinawa', 'projection': 'albers', 'params': [25.0, 27.5, 127.0, 26.2], 'frame': [24, 30, 230, 165], 'll': [122.5, 132.0, 23.8, 28.8],
                 'insetLabel': {'text': '沖縄 Okinawa', 'x': 24, 'y': 202}, 'insetBox': [16, 22, 246, 198]},
            ],
            'zone_for': lambda c: (
                {'id': 'Okinawa', 'projection': 'albers', 'params': [25.0, 27.5, 127.0, 26.2]}
                if c == 'JP-47' else
                {'id': 'main', 'projection': 'albers', 'params': [33.0, 42.0, 137.0, 37.5]}
            ),
            'poly_filter': lambda r: any(lat >= 24.0 for _, lat in r) and not (all(lat < 29.0 or lon > 146.5 for lon, lat in r) and min(lon for lon, _ in r) > 132.0),
        },
        {
            'id': 'ca-admin1', 'aliases': ['ca', 'canada'], 'scope': 'CA', 'admin': 'Canada',
            'height': 660.0, 'tol': 0.0012,
            'note': 'Natural Earth 1:10m · Albers · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [49.0, 77.0, -95.0, 60.0], 'frame': [20, 15, 960, 630], 'll': [-142.0, -52.0, 41.5, 83.5]}],
            'zone_for': lambda c: {'id': 'main', 'projection': 'albers', 'params': [49.0, 77.0, -95.0, 60.0]},
        },
        {
            'id': 'au-admin1', 'aliases': ['au', 'australia'], 'scope': 'AU', 'admin': 'Australia',
            'height': 700.0, 'tol': 0.0008,
            'exclude_codes': ('AU-X02~', 'AU-X03~'),
            'note': 'Natural Earth 1:10m · Albers · 澳大利亚8州及领地 · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [-18.0, -36.0, 132.0, -27.0], 'frame': [20, 15, 960, 670], 'll': [112.0, 155.0, -44.5, -9.0]}],
            'zone_for': lambda c: {'id': 'main', 'projection': 'albers', 'params': [-18.0, -36.0, 132.0, -27.0]},
            'poly_filter': lambda r: min(lon for lon, _ in r) < 155.0,
        },
        {
            'id': 'br-admin1', 'aliases': ['br', 'brazil'], 'scope': 'BR', 'admin': 'Brazil',
            'height': 740.0, 'tol': 0.0008,
            'note': 'Natural Earth 1:10m · Albers · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [-5.0, -22.0, -54.0, -14.0], 'frame': [20, 15, 960, 710], 'll': [-74.5, -34.0, -34.0, 5.5]}],
            'zone_for': lambda c: {'id': 'main', 'projection': 'albers', 'params': [-5.0, -22.0, -54.0, -14.0]},
            'poly_filter': lambda r: min(lon for lon, _ in r) < -34.0,
        },
        {
            'id': 'kr-admin1', 'aliases': ['kr', 'korea'], 'scope': 'KR', 'admin': 'South Korea',
            'height': 780.0, 'tol': 0.00035,
            'note': 'Natural Earth 1:10m · Albers · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [34.0, 38.0, 127.5, 36.0], 'frame': [20, 15, 960, 750], 'll': [124.5, 131.5, 33.0, 38.7]}],
            'zone_for': lambda c: {'id': 'main', 'projection': 'albers', 'params': [34.0, 38.0, 127.5, 36.0]},
        },
    ]


def geoboundaries_configs():
    gb_map = {
        'England': ('GB-ENG', 'England', '英格兰', ['ENG']),
        'Scotland': ('GB-SCT', 'Scotland', '苏格兰', ['SCT']),
        'Wales': ('GB-WLS', 'Wales', '威尔士', ['WLS']),
        'Northern Ireland': ('GB-NIR', 'Northern Ireland', '北爱尔兰', ['NIR']),
    }
    fr_map = {
        'Île-de-France': ('FR-IDF', 'Île-de-France', '法兰西岛', ['Ile-de-France']),
        'Centre-Val de Loire': ('FR-CVL', 'Centre-Val de Loire', '中央-卢瓦尔河谷', []),
        'Bourgogne-Franche-Comté': ('FR-BFC', 'Bourgogne-Franche-Comté', '勃艮第-弗朗什-孔泰', []),
        'Normandie': ('FR-NOR', 'Normandie', '诺曼底', ['Normandy']),
        'Hauts-de-France': ('FR-HDF', 'Hauts-de-France', '上法兰西', []),
        'Grand Est': ('FR-GES', 'Grand Est', '大东部', []),
        'Pays de la Loire': ('FR-PDL', 'Pays de la Loire', '卢瓦尔河地区', []),
        'Bretagne': ('FR-BRE', 'Bretagne', '布列塔尼', ['Brittany']),
        'Nouvelle-Aquitaine': ('FR-NAQ', 'Nouvelle-Aquitaine', '新阿基坦', []),
        'Occitanie': ('FR-OCC', 'Occitanie', '奥克西塔尼', []),
        'Auvergne-Rhône-Alpes': ('FR-ARA', 'Auvergne-Rhône-Alpes', '奥弗涅-罗讷-阿尔卑斯', []),
        "Provence-Alpes-Côte d'Azur": ('FR-PAC', "Provence-Alpes-Côte d'Azur", '普罗旺斯-阿尔卑斯-蓝色海岸', ['PACA']),
        'Corse': ('FR-20R', 'Corse', '科西嘉', ['FR-COR', 'Corsica']),
    }
    it_map = {
        'Piemonte': ('IT-21', 'Piemonte', '皮埃蒙特', ['Piedmont']),
        "Valle d'Aosta": ('IT-23', "Valle d'Aosta", '瓦莱达奥斯塔', ['Aosta Valley']),
        'Lombardia': ('IT-25', 'Lombardia', '伦巴第', ['Lombardy']),
        'Trentino-Alto Adige': ('IT-32', 'Trentino-Alto Adige', '特伦蒂诺-上阿迪杰', []),
        'Veneto': ('IT-34', 'Veneto', '威尼托', []),
        'Friuli Venezia Giulia': ('IT-36', 'Friuli-Venezia Giulia', '弗留利-威尼斯朱利亚', ['Friuli-Venezia Giulia']),
        'Liguria': ('IT-42', 'Liguria', '利古里亚', []),
        'Emilia-Romagna': ('IT-45', 'Emilia-Romagna', '艾米利亚-罗马涅', []),
        'Toscana': ('IT-52', 'Toscana', '托斯卡纳', ['Tuscany']),
        'Umbria': ('IT-55', 'Umbria', '翁布里亚', []),
        'Marche': ('IT-57', 'Marche', '马尔凯', []),
        'Lazio': ('IT-62', 'Lazio', '拉齐奥', []),
        'Abruzzo': ('IT-65', 'Abruzzo', '阿布鲁佐', []),
        'Molise': ('IT-67', 'Molise', '莫利塞', []),
        'Campania': ('IT-72', 'Campania', '坎帕尼亚', []),
        'Puglia': ('IT-75', 'Puglia', '普利亚', ['Apulia']),
        'Basilicata': ('IT-77', 'Basilicata', '巴西利卡塔', []),
        'Calabria': ('IT-78', 'Calabria', '卡拉布里亚', []),
        'Sicilia': ('IT-82', 'Sicilia', '西西里', ['Sicily']),
        'Sardegna': ('IT-88', 'Sardegna', '撒丁', ['Sardinia']),
    }
    es_map = {
        'Andalucía': ('ES-AN', 'Andalucía', '安达卢西亚', ['Andalusia']),
        'Aragón': ('ES-AR', 'Aragón', '阿拉贡', ['Aragon']),
        'Principado de Asturias': ('ES-AS', 'Asturias', '阿斯图里亚斯', ['Asturias']),
        'Canarias': ('ES-CN', 'Canarias', '加那利群岛', ['Canary Islands']),
        'Cantabria': ('ES-CB', 'Cantabria', '坎塔布里亚', []),
        'Castilla-La Mancha': ('ES-CM', 'Castilla-La Mancha', '卡斯蒂利亚-拉曼恰', []),
        'Castilla y León': ('ES-CL', 'Castilla y León', '卡斯蒂利亚-莱昂', []),
        'Cataluña/Catalunya': ('ES-CT', 'Cataluña', '加泰罗尼亚', ['Catalonia', 'Cataluña', 'Catalunya']),
        'Ciudad Autónoma de Ceuta': ('ES-CE', 'Ceuta', '休达', ['Ceuta']),
        'Extremadura': ('ES-EX', 'Extremadura', '埃斯特雷马杜拉', []),
        'Galicia': ('ES-GA', 'Galicia', '加利西亚', []),
        'Illes Balears': ('ES-IB', 'Illes Balears', '巴利阿里群岛', ['Balearic Islands']),
        'La Rioja': ('ES-RI', 'La Rioja', '拉里奥哈', []),
        'Comunidad de Madrid': ('ES-MD', 'Madrid', '马德里', ['Madrid']),
        'Ciudad Autónoma de Melilla': ('ES-ML', 'Melilla', '梅利利亚', ['Melilla']),
        'Región de Murcia': ('ES-MC', 'Murcia', '穆尔西亚', ['Murcia']),
        'Comunidad Foral de Navarra': ('ES-NC', 'Navarra', '纳瓦拉', ['Navarra', 'Navarre']),
        'País Vasco/Euskadi': ('ES-PV', 'País Vasco', '巴斯克', ['Basque Country', 'País Vasco', 'Euskadi']),
        'Comunitat Valenciana': ('ES-VC', 'Comunitat Valenciana', '瓦伦西亚', ['Valencia']),
    }
    return [
        {
            'id': 'gb-admin1', 'aliases': ['gb', 'uk', 'united-kingdom'], 'scope': 'GB',
            'source_key': 'gb_GBR_ADM1', 'source_name': 'geoBoundaries GBR ADM1 (Eurostat/ONS)',
            'license': {'spdx': 'CC-BY-4.0', 'attribution': 'geoBoundaries / Eurostat (CC BY 4.0)', 'commercialAllowed': True},
            'year': 2021, 'height': 780.0, 'tol': 0.0005,
            'note': 'geoBoundaries (CC BY 4.0) · Albers · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [51.0, 58.0, -2.5, 54.5], 'frame': [20, 15, 960, 750], 'll': [-8.8, 2.0, 49.8, 61.0]}],
            'map_feature': lambda s, p: (*gb_map[s], 'main'),
        },
        {
            'id': 'fr-admin1', 'aliases': ['fr', 'france'], 'scope': 'FR',
            'source_key': 'gb_FRA_ADM1', 'source_name': 'geoBoundaries FRA ADM1 (IGN-F)',
            'license': {'spdx': 'Etalab-2.0', 'attribution': 'geoBoundaries / IGN-F (Etalab 2.0)', 'commercialAllowed': True},
            'year': 2022, 'height': 740.0, 'tol': 0.0005,
            'note': 'geoBoundaries / IGN-F (Etalab 2.0) · Albers · 法国本土13大区 · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [44.0, 49.0, 2.5, 46.5], 'frame': [20, 15, 960, 710], 'll': [-5.5, 9.8, 41.3, 51.3]}],
            'map_feature': lambda s, p: (*fr_map[s], 'main'),
        },
        {
            'id': 'it-admin1', 'aliases': ['it', 'italy'], 'scope': 'IT',
            'source_key': 'gb_ITA_ADM2', 'source_name': 'geoBoundaries ITA ADM2 (ISTAT)',
            'license': {'spdx': 'CC-BY-3.0', 'attribution': 'geoBoundaries / ISTAT (CC BY 3.0)', 'commercialAllowed': True},
            'year': 2023, 'height': 780.0, 'tol': 0.0005,
            'note': 'geoBoundaries / ISTAT (CC BY 3.0) · Albers · 意大利20大区 · 非导航地图',
            'zones': [{'id': 'main', 'projection': 'albers', 'params': [38.0, 45.0, 12.5, 42.0], 'frame': [20, 15, 960, 750], 'll': [6.5, 18.8, 35.4, 47.2]}],
            'map_feature': lambda s, p: (*it_map[s], 'main'),
        },
        {
            'id': 'es-admin1', 'aliases': ['es', 'spain'], 'scope': 'ES',
            'source_key': 'gb_ESP_ADM1', 'source_name': 'geoBoundaries ESP ADM1 (IGN-ES)',
            'license': {'spdx': 'CC-BY-4.0', 'attribution': 'geoBoundaries / IGN-ES (CC BY 4.0)', 'commercialAllowed': True},
            'year': 2017, 'height': 640.0, 'tol': 0.00045,
            'note': 'geoBoundaries / IGN-ES (CC BY 4.0) · Albers · Canarias 插图 · 非导航地图',
            'zones': [
                {'id': 'main', 'projection': 'albers', 'params': [37.5, 42.5, -3.5, 40.0], 'frame': [180, 15, 800, 610], 'll': [-9.5, 4.6, 35.0, 44.0]},
                {'id': 'Canarias', 'projection': 'albers', 'params': [28.0, 29.0, -15.8, 28.5], 'frame': [20, 460, 220, 140], 'll': [-18.5, -13.0, 27.3, 29.6],
                 'insetLabel': {'text': 'Canarias', 'x': 24, 'y': 604}, 'insetBox': [14, 454, 232, 168]},
            ],
            'map_feature': lambda s, p: (*es_map[s], 'Canarias' if s == 'Canarias' else 'main'),
        },
    ]


def verify_output_packs(out_dir):
    cat_path = out_dir / 'catalog.json'
    assert cat_path.is_file(), 'Missing catalog.json'
    cat = json.loads(cat_path.read_text())
    assert cat['schemaVersion'] == 1
    total_bytes = cat_path.stat().st_size
    seen_ids = set()
    seen_aliases = set()
    for entry in cat['packs']:
        pid = entry['id']
        assert pid not in seen_ids
        seen_ids.add(pid)
        for al in [pid] + entry['aliases']:
            k = al.lower()
            assert k not in seen_aliases, f'Duplicate region alias {al}'
            seen_aliases.add(k)
        mp = out_dir / entry['manifestFile']
        cp = out_dir / entry['codesFile']
        gp = out_dir / entry['geometryFile']
        assert hashlib.sha256(mp.read_bytes()).hexdigest() == entry['manifestSha256']
        assert hashlib.sha256(cp.read_bytes()).hexdigest() == entry['codesSha256']
        assert hashlib.sha256(gp.read_bytes()).hexdigest() == entry['geometrySha256']
        manifest = json.loads(mp.read_text())
        mbytes = gp.read_bytes()
        assert mbytes[:4] == b'MUMP'
        ver, flags, scale, fcnt, rcnt, vcnt, ocnt, ovcnt = struct.unpack('<HHfIIIII', mbytes[4:32])
        assert ver == 1 and flags == 0 and scale > 0
        expected = 32 + fcnt * 8 + rcnt * 8 + vcnt * 4 + ocnt * 12 + ovcnt * 4
        assert len(mbytes) == expected, f'{pid} size mismatch {len(mbytes)} != {expected}'
        lines = [l for l in cp.read_text().splitlines() if l]
        assert len(lines) == fcnt == entry['featureCount'], f'{pid} code row mismatch'
        codes = [l.split('\t')[0] for l in lines]
        assert len(set(codes)) == len(codes), f'{pid} duplicate feature codes'
        assert len(mbytes) <= 400_000, f'{pid} exceeds 400KB single-pack budget: {len(mbytes)}'
        total_bytes += mp.stat().st_size + cp.stat().st_size + gp.stat().st_size
        print(f'PACK_OK {pid:15s} features={fcnt:4d} rings={rcnt:4d} vertices={vcnt:5d} overlays={ocnt:3d} mump={len(mbytes):6d}B tsv={cp.stat().st_size:6d}B')
    assert total_bytes <= 2_097_152, f'Total MapPacks size exceeds 1MB budget: {total_bytes}'
    print(f'ALL_MAP_PACKS_VERIFIED packs={len(cat["packs"])} total_bytes={total_bytes}')



LEVEL_A1 = 'adm' + 'in' + '1'

CN_PROVINCES = [
    ('110000', 'Beijing', '北京', ['京', 'BJ', 'Peking']),
    ('120000', 'Tianjin', '天津', ['津', 'TJ']),
    ('130000', 'Hebei', '河北', ['冀', 'HE']),
    ('140000', 'Shanxi', '山西', ['晋', 'SX']),
    ('150000', 'Inner Mongolia', '内蒙古', ['蒙', 'NM', 'Nei Mongol']),
    ('210000', 'Liaoning', '辽宁', ['辽', 'LN']),
    ('220000', 'Jilin', '吉林', ['吉', 'JL']),
    ('230000', 'Heilongjiang', '黑龙江', ['黑', 'HLJ']),
    ('310000', 'Shanghai', '上海', ['沪', 'SH']),
    ('320000', 'Jiangsu', '江苏', ['苏', 'JS']),
    ('330000', 'Zhejiang', '浙江', ['浙', 'ZJ']),
    ('340000', 'Anhui', '安徽', ['皖', 'AH']),
    ('350000', 'Fujian', '福建', ['闽', 'FJ']),
    ('360000', 'Jiangxi', '江西', ['赣', 'JX']),
    ('370000', 'Shandong', '山东', ['鲁', 'SD']),
    ('410000', 'Henan', '河南', ['豫', 'HA']),
    ('420000', 'Hubei', '湖北', ['鄂', 'HB']),
    ('430000', 'Hunan', '湖南', ['湘', 'HN']),
    ('440000', 'Guangdong', '广东', ['粤', 'GD']),
    ('450000', 'Guangxi', '广西', ['桂', 'GX', 'Guangxi Zhuang']),
    ('460000', 'Hainan', '海南', ['琼', 'HI']),
    ('500000', 'Chongqing', '重庆', ['渝', 'CQ']),
    ('510000', 'Sichuan', '四川', ['川', '蜀', 'SC']),
    ('520000', 'Guizhou', '贵州', ['黔', '贵', 'GZ']),
    ('530000', 'Yunnan', '云南', ['滇', '云', 'YN']),
    ('540000', 'Tibet', '西藏', ['藏', 'XZ', 'Xizang']),
    ('610000', 'Shaanxi', '陕西', ['陕', '秦', 'SN']),
    ('620000', 'Gansu', '甘肃', ['甘', '陇', 'GS']),
    ('630000', 'Qinghai', '青海', ['青', 'QH']),
    ('640000', 'Ningxia', '宁夏', ['宁', 'NX', 'Ningxia Hui']),
    ('650000', 'Xinjiang', '新疆', ['新', 'XJ', 'Xinjiang Uyghur']),
    ('710000', 'Taiwan', '台湾', ['台', 'TW', '台灣', '臺灣']),
    ('810000', 'Hong Kong', '香港', ['港', 'HK', 'Xianggang']),
    ('820000', 'Macao', '澳门', ['澳', 'MO', 'Macau', '澳門']),
]


def build_cn_pack(cache_dir=None):
    """China province-level pack: 34 units + South China Sea inset with nine-dash line.

    Source is the checked-in, reproducible bundle scripts/data/cn_source.json.gz
    (DataV.GeoAtlas, per-province detail merged to one polygon per province).
    """
    src = ROOT / 'scripts' / 'data' / 'cn_source.json.gz'
    blob = src.read_bytes()
    sha = hashlib.sha256(blob).hexdigest()
    bundle = json.loads(gzip.decompress(blob))

    main_z = {'id': 'main', 'projection': 'albers', 'params': [25.0, 47.0, 105.0, 35.0],
              'frame': [8.0, 6.0, 692.0, 464.0], 'll': [73.0, 135.5, 17.5, 53.8]}
    scs_z = {'id': 'SCS', 'projection': 'albers', 'params': [3.0, 20.0, 112.0, 12.5],
             'frame': [712.0, 246.0, 280.0, 244.0], 'll': [105.0, 125.0, 2.5, 25.0],
             'insetLabel': {'text': '南海诸岛', 'x': 714.0, 'y': 232.0},
             'insetBox': [712.0, 246.0, 280.0, 244.0]}
    zones_cfg = [main_z, scs_z]
    frames = {z['id']: z['frame'] for z in zones_cfg}
    zone_pts = {'main': [], 'SCS': []}

    meta = {c: (en, zh, al) for c, en, zh, al in CN_PROVINCES}
    items = []
    for code, info in sorted(bundle['provinces'].items()):
        polys = geojson_polys(info['geometry'])
        main_raw = [q for q in polys if max(pt[1] for pt in q[0]) >= 17.5]
        scs_raw = [q for q in polys if max(pt[1] for pt in q[0]) < 17.5]
        mp = process_polygons(main_raw, 'albers', main_z['params'], 0.0) if main_raw else []
        sp = process_polygons(scs_raw, 'albers', scs_z['params'], 0.0) if scs_raw else []
        for poly in mp:
            for r in poly:
                zone_pts['main'].extend(r)
        for poly in sp:
            for r in poly:
                zone_pts['SCS'].extend(r)
        en, zh, al = meta.get(code, (info['name'], info['name'], []))
        items.append({'code': code, 'name': en, 'zh': zh,
                      'raw_aliases': [zh, en] + list(al), 'main': mp, 'scs': sp})

    nine_paths = []
    for poly in geojson_polys(bundle['nineDash']):
        for ring in poly:
            pts = [project_point(pt[0], pt[1], 'albers', scs_z['params']) for pt in ring]
            if len(pts) >= 2:
                nine_paths.append(pts)
                zone_pts['SCS'].extend(pts)

    bounds = compute_zone_bounds(zone_pts)
    features = []
    for it in items:
        rings = []
        if it['main']:
            rings += finalize_feature_rings([('main', it['main'])], bounds, frames,
                                            0.000002, speck_px=0.55, keep_tiny_primary=True)
        if it['scs']:
            rings += finalize_feature_rings([('SCS', it['scs'])], bounds, frames,
                                            0.000002, speck_px=0.3, keep_tiny_primary=True)
        features.append({'code': it['code'], 'name': it['name'], 'zh': it['zh'],
                         'raw_aliases': it['raw_aliases'], 'rings': rings})

    overlays = []
    x, y, w, h = scs_z['insetBox']
    overlays.append((1, True, [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]))
    for pts in nine_paths:
        overlays.append((2, False, [normalize_pt(px, py, bounds['SCS'], frames['SCS']) for px, py in pts]))

    zones = [{'id': z['id'], 'projection': z['projection'], 'params': z['params'],
              'bounds': bounds[z['id']], 'frame': z['frame'],
              'lonMin': z['ll'][0], 'lonMax': z['ll'][1], 'latMin': z['ll'][2], 'latMax': z['ll'][3],
              'antimeridianWrap': False, 'insetLabel': z.get('insetLabel'), 'insetBox': z.get('insetBox')}
             for z in zones_cfg]

    return {
        'id': 'cn-' + LEVEL_A1,
        'aliases': ['cn', 'china', 'prc', 'cn-provinces', '中国', '中国省级', 'china-provinces'],
        'scope': 'CN',
        'level': LEVEL_A1,
        'codeSystem': 'GB/T 2260 (6-digit adcode)',
        'source': {'name': 'DataV.GeoAtlas 全国省级行政边界', 'url': 'https://geo.datav.aliyun.com/areas_v3/bound/',
                   'version': '2026-11-15', 'inputSha256': sha},
        'license': {'spdx': 'DataV-Terms', 'attribution': 'DataV.GeoAtlas (高德)', 'commercialAllowed': False},
        'boundaryYear': 2024,
        'complianceNote': '中国34个省级行政区（含台港澳）· 含南海诸岛及九段线 · 仅供个人自用；公开发布须经自然资源主管部门审核并标注审图号',
        'canvas': {'width': 1000.0, 'height': 496.0, 'coordScale': 20.0},
        'styleHints': {'featureStrokeWidth': 0.7, 'overlayStrokeWidth': 1.1,
                       'clipToCanvas': False, 'drawSeaByDefault': True},
        'zones': zones,
        'features': features,
        'overlays': overlays,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=pathlib.Path, default=DEFAULT_OUT)
    ap.add_argument('--cache', type=pathlib.Path, default=DEFAULT_CACHE)
    ap.add_argument('--verify-only', action='store_true')
    args = ap.parse_args()

    if not args.verify_only:
        specs = [
            build_us_admin1(args.cache),
            build_world_admin0(args.cache),
            build_europe_admin0(args.cache),
        ]
        for cfg in major_ne_configs():
            specs.append(build_ne_admin1_country(args.cache, cfg))
        for cfg in geoboundaries_configs():
            specs.append(build_geoboundaries_country(args.cache, cfg))
        specs.append(build_us_county(args.cache))
        specs.append(build_cn_pack())

        args.out.mkdir(parents=True, exist_ok=True)
        entries = [write_pack(args.out, s) for s in specs]
        catalog = {'schemaVersion': 1, 'packs': entries}
        (args.out / 'catalog.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
    verify_output_packs(args.out)


if __name__ == '__main__':
    main()
