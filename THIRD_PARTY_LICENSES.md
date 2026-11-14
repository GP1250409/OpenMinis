# Third-Party Licenses

OpenMinis bundles, links, or depends on the following third-party components. Versions reflect the current source tree; license types were verified against each project's repository (GitHub license metadata / LICENSE files).

## Native C/C++ dependencies (`deps/`)

| Component | Version / Source | License | Notes |
|---|---|---|---|
| [iSH](https://github.com/OpenMinis/ish-arm64) (ARM64 fork) | git submodule `deps/ish` | **GPL-3.0** (post-`0e3a414` contributions also under GPL-2.0), with an App Store distribution exception (`LICENSE.IOS`) | Linux usermode emulation on iOS (ARM64 fork, aarch64 guest); core reason the app is GPLv3 |
| [proot](https://github.com/OpenMinis/proot) (fork) | git submodule `deps/proot` | **GPL-2.0** | Linux sandbox on Android (`libproot.so`, `proot-aarch64`) |
| proot ELF loaders (Termux build) | Termux package `proot` 5.1.107-70, vendored as `src/android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so` and `libproot-loader32.so` (sha256-pinned in `deps/build_proot.sh`) | **GPL-2.0** | Corresponding source: [termux/proot@`4dba3afb`](https://github.com/termux/proot/tree/4dba3afbf3a63af89b4d9c1a59bf2bda10f4d10f), as pinned by [termux-packages@`0ff4d49d`](https://github.com/termux/termux-packages/blob/0ff4d49dad73ed7a62375504cf96326bb835e132/packages/proot/build.sh). Shipped as binaries because they carry Termux's Android loader patches |
| [rclone](https://github.com/rclone/rclone) | v1.75.0 (`deps/rclone-mobile/go.mod`), built by `deps/build_rclone_ios.sh` / `deps/build_rclone_android.sh` | **MIT**. Its Go module dependencies are mostly MIT / BSD / Apache-2.0 / ISC, plus **MPL-2.0** (`hashicorp/go-retryablehttp`, `go-cleanhttp`, `go-multierror`, `errwrap`, `go-uuid`, through the S3 backend) and **LGPL-3.0** (`cloudsoda/sddl`, through the SMB backend); versions pinned in `go.sum` | Backup remote destinations. Go links everything statically into one library: `Rclone.xcframework` (iOS), `rclone.aar` → `libgojni.so` (Android); the source of every module is fetched from `go.sum` when building |
| [Tailscale](https://github.com/tailscale/tailscale) | `tailscale.com` v1.94.2 (`deps/rclone-mobile/go.mod`), with [wireguard-go](https://github.com/tailscale/wireguard-go) and the [gVisor](https://github.com/google/gvisor) network stack | **BSD-3-Clause** (wireguard-go **MIT**, gVisor **Apache-2.0**) | Embedded Tailscale node (`deps/rclone-mobile/tsnet`) for Settings > Network, statically linked into the same Go library as rclone; built with `ts_omit_logtail,ts_omit_portmapper` (no log upload, no UPnP / NAT-PMP). Signs in to the user's own Tailscale account; no control server is bundled |
| [FFmpeg](https://ffmpeg.org) | 6.1.2, built by `deps/build_ffmpeg.sh` | **LGPL-2.1-or-later** (built without `--enable-gpl` / `--enable-nonfree`) | Dynamic frameworks on iOS; keep the LGPL configuration |
| [LAME](https://lame.sourceforge.io) | 3.100, vendored at `deps/lame-3.100` | **LGPL-2.0-or-later** | MP3 encoder, linked into FFmpeg via `--enable-libmp3lame` |
| [talloc](https://talloc.samba.org) (Samba) | vendored at `deps/talloc` | **LGPL-3.0-or-later** | Memory allocator required by proot |
| [cppjieba](https://github.com/yanyiwu/cppjieba) | vendored (iOS `Vendor/cppjieba`, Android `jieba_jni`) | **MIT** | Chinese word segmentation (header-only + dictionaries) |
| Alpine Linux minirootfs | downloaded at build time by `deps/prepare_alpine_rootfs.sh` | Aggregate of package licenses (musl **MIT**, BusyBox **GPL-2.0**, etc.) | Not stored in this repo; bundled into app builds as the default rootfs |
| Alpine packages for the AOJIT restore (`busybox`, `busybox-binsh`, `ssl_client` 1.37.0-r8; `musl`, `musl-utils` 1.2.5-r8) | Original signed Alpine 3.21 packages, vendored as binaries in `src/ios/AOJITRestore/` | **GPL-2.0-only** (BusyBox, ssl_client), **MIT** (musl) | Used by `restore.sh` to put a rootfs back on the exact builds the AOT images match; the Alpine mirror no longer carries these builds. Corresponding source: Alpine aports `main/busybox` and `main/musl` at the 3.21 release, and upstream [busybox.net](https://busybox.net) / [musl.libc.org](https://musl.libc.org) |

## iOS — Swift Package Manager dependencies

Direct packages declared in `src/ios/Minis.xcodeproj`:

| Package | Version | Repository | License |
|---|---|---|---|
| SwiftAnthropic | 2.2.0 (exact) | https://github.com/jamesrochabrun/SwiftAnthropic | **MIT** |
| swift-cmark (`cmark-gfm`, `cmark-gfm-extensions`) | 0.7.1 | https://github.com/swiftlang/swift-cmark | **BSD-2-Clause** (with some MIT-licensed vendored files, see its `COPYING`) |
| SwiftMath | 1.7.3 | https://github.com/mgriebling/SwiftMath | **MIT** |
| RealTimeCutVADLibrary | 1.0.14 | https://github.com/helloooideeeeea/RealTimeCutVADLibrary | **MIT** |

RealTimeCutVADLibrary (and its Android counterpart below) bundles [ONNX Runtime](https://github.com/microsoft/onnxruntime) (**MIT**), the [WebRTC audio processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) module (**BSD-3-Clause**) and the [Silero VAD](https://github.com/snakers4/silero-vad) model (**MIT**).

Transitive packages (pinned in `Package.resolved`), all **Apache-2.0**, maintained by Apple / the Swift Server Workgroup: `async-http-client`, `swift-algorithms`, `swift-asn1`, `swift-async-algorithms`, `swift-atomics`, `swift-certificates`, `swift-collections`, `swift-crypto`, `swift-distributed-tracing`, `swift-http-structured-headers`, `swift-http-types`, `swift-log`, `swift-nio` (+ `-extras`, `-http2`, `-ssl`, `-transport-services`), `swift-numerics`, `swift-service-context`, `swift-service-lifecycle`, `swift-system`.

## Android — Gradle dependencies

| Library | Version | License |
|---|---|---|
| AndroidX / Jetpack (Compose BOM 2025.09.00, core-ktx, lifecycle, activity, navigation, Room, DataStore, security-crypto, browser, webkit, exifinterface, profileinstaller, Material 3 adaptive) | see `app/build.gradle.kts` | **Apache-2.0** (Google / AOSP) |
| OkHttp + okhttp-sse | 4.12.0 | **Apache-2.0** |
| kotlinx-serialization-json | 1.7.3 | **Apache-2.0** |
| kotlinx-coroutines-android | 1.9.0 | **Apache-2.0** |
| Coil (coil-compose) | 2.7.0 | **Apache-2.0** |
| multiplatform-markdown-renderer (+ m3) — mikepenz | 0.33.0 | **Apache-2.0** |
| Reorderable (sh.calvin.reorderable) | 2.4.0 | **Apache-2.0** |
| ACRA (acra-core) | 5.12.0 | **Apache-2.0** |
| Shizuku API + provider (dev.rikka.shizuku) | 13.1.5 | **MIT** |
| RealTimeCutVADLibraryForAndroid (helloooideeeeea) | 1.0.5 | **MIT** — bundles ONNX Runtime (**MIT**) and WebRTC audio processing (**BSD-3-Clause**) |

Test-only dependencies: JUnit 4.13.2 (**EPL-1.0**), MockWebServer 4.12.0 (**Apache-2.0**), kotlinx-coroutines-test 1.9.0 (**Apache-2.0**), org.json 20231013 (**Public Domain / JSON License**), sqlite-jdbc 3.41.2.2 (**Apache-2.0**), Robolectric 4.17 (**MIT**).

## Bundled web/UI assets

| Asset | Location | License |
|---|---|---|
| KaTeX | iOS `src/ios/Resources/KaTeX/`, Android `app/src/main/assets/katex/` | **MIT** |
| jieba dictionaries | iOS bundle / Android `assets/jieba/` | **MIT** (cppjieba distribution) |
| [models.dev](https://github.com/sst/models.dev) catalogue snapshot | iOS bundle / Android `assets/models-dev-api.json` (offline copy of `https://models.dev/api.json`, refreshed at run time) | **MIT** |
| [tiktoken](https://github.com/openai/tiktoken) `cl100k_base` BPE ranks | iOS `src/ios/Shared/cl100k_base.tiktoken`; the tokenizer in `BPETokenizer.swift` is ported from tiktoken | **MIT** |

## Offline show_ui map data (MOD Phase 2 & MapPack v1 Engine)

All bundled offline map resources under `src/ios/Resources/MapPacks/` are reproducible
from pinned upstream sources via `python3 scripts/generate_map_packs.py`.

- **Natural Earth** (`us-admin1`, `world-admin0`, `europe-admin0`, `de-admin1`,
  `jp-admin1`, `ca-admin1`, `au-admin1`, `br-admin1`, `kr-admin1`, and fallback
  `MinisUIMapData.swift`):
  - Upstream commit `ca96624a56bd078437bca8184e78163e5039ad19`
    (`ne_50m_admin_0_countries.geojson` SHA256 `3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb`,
    `ne_10m_admin_0_countries.geojson` SHA256 `239eec57ac17f100a11e2536cffc56752c318b50ae765b0918ff7aab4ce8f255`,
    `ne_50m_admin_1_states_provinces.geojson` SHA256 `69a0e06e640b2d505858ae1cb63034e4677f3000b35a98e16312932b98c426b9`,
    `ne_10m_admin_1_states_provinces.geojson` SHA256 `22d0e3ad85eb3e27f17cabf8ba2d50e554fbc27a87796ff891d958185da62fb5`).
  - `world-*0` and `europe-*0` are built from the **1:10m** countries file;
    `de/jp/ca/au/br/kr-*1` from the **1:10m** states/provinces file.
  - License: **Public Domain**. First-party terms:
    https://www.naturalearthdata.com/about/terms-of-use/
    (cartographic overview boundaries, not standard national boundaries or navigation data).
- **U.S. Census Bureau Cartographic Boundary Files (2020, 1:20m)** (`us-county`,
  3,143 counties/equivalents in 50 states + DC plus state boundary overlays):
  - `cb_2020_us_county_20m.zip` SHA256 `9394913edbd6f72791b06b84509e59ea2d275d10b73ae27ef87df3bdb061890c`
  - `cb_2020_us_state_20m.zip` SHA256 `1d872779cbfa2c2bf828850664aa9593a35844205e2e4bed5aeb78affb8da050`
  - License: **Public Domain** (U.S. Government work, 17 U.S.C. § 105).
- **geoBoundaries `gbOpen` (commit `9469f09`)**:
  - `gb-admin1` (4 nations): `geoBoundaries-GBR-ADM1_simplified.geojson` (SHA256 `85a05dc0e939aff5cca6d9b8bf0684efe6c098a54579b24531a3f5594a6e450e`) — Eurostat / ONS, **CC BY 4.0**.
  - `fr-admin1` (13 metropolitan regions): `geoBoundaries-FRA-ADM1_simplified.geojson` (SHA256 `7dc61e5c7e4c81f5fa10d339e6a5bc8428f1346f43f4426d9d165d2e44fc3a7e`) — IGN-F, **Etalab Open License 2.0**.
  - `it-admin1` (20 regions): `geoBoundaries-ITA-ADM2_simplified.geojson` (SHA256 `a01b6408d7d9061318034f8f4f54b377b99b5f8dcf5a7f84c5fa1e8ee3c86549`) — ISTAT, **CC BY 3.0**.
  - `es-admin1` (19 communities/cities): `geoBoundaries-ESP-ADM1_simplified.geojson` (SHA256 `b61a1bf661b90883763f633f5e9dbc27e7356309e42cbe56b60d2ceab5112f63`) — IGN-ES, **CC BY 4.0**.
- **China Boundaries**:
  - `BlockMap("cn", ...)` uses original project topology (34 provincial-level tiles including Taiwan, Hong Kong, and Macao; explicitly NOT a geographic boundary map or standard map).
  - `GeoMap("cn")` -> `cn-admin1` (34 province-level units including Taiwan, Hong Kong and
    Macao, plus the nine-dash line as an overlay and a South China Sea inset):
    - Source: `https://geo.datav.aliyun.com/areas_v3/bound/{adcode}_full.json`, fetched
      2026-11-15; per-province city polygons merged to one polygon per province and
      checked in as the reproducible bundle `scripts/data/cn_source.json.gz`
      (SHA256 `b683eef7c21cac7967e680c7f4126e499231a83ff68d5439cc61a9b8d0697983`).
    - Upstream: DataV.GeoAtlas (Alibaba Cloud), derived from AutoNavi/高德. Upstream
      terms are "for learning and exchange only" and do **not** grant commercial
      redistribution.
    - **Compliance status: NOT map-review approved.** Enabled for personal,
      non-published use only. Publishing or distributing any build that renders this
      pack inside China requires review by the competent natural-resources authority and
      a printed map approval number (审图号), e.g. through 自然资源部标准地图服务
      (`bzdt.ch.mnr.gov.cn`). Including the South China Sea inset and the nine-dash line
      does not by itself constitute approval.
- Economist maps styleguide (5 May 2017, pp.3–6, 8–9,12): layout/colour references
  only, documented in `docs/minismod/CHARTS.md` and `docs/minismod/MAPS.md`; original
  PDF/artwork/fonts are NOT bundled or redistributed. Named screen palettes are sampled
  from the retained PDF, not a claim of official published hex values. The two ten-stop
  diverging palettes and China topology are explicitly project adaptations.

## Removed / historical

- **swift-markdown-ui** (MIT) — formerly vendored under `deps/swift-markdown-ui`; no longer referenced by the Xcode project or imported by any source file, and is not part of the open-source tree.
