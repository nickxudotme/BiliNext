# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

BiliNext is a native macOS 26+ Bilibili client (SwiftUI + AppKit, Swift 6 toolchain in Swift 5 language mode, SwiftPM only — no Xcode project). Project docs and UI strings are in Chinese; keep new docs in Chinese to match.

## Commands

Prereqs: Xcode, `brew install mpv pkgconf` (the `CMPV` system-library target links libmpv via pkg-config).

```sh
swift build                                   # debug build
swift build -c release                        # required check when touching #if DEBUG / conditional compilation
swift test                                    # offline tests only; never touches a real account
swift test --filter <testFunctionName>        # single test (Swift Testing @Test functions)
bash scripts/check-format.sh                  # strict swift-format lint (Xcode's bundled xcrun swift-format)
xcrun swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests
bash scripts/build-app.sh && open build/BiliNext.app   # signed Debug .app bundle
BILINEXT_BUILD_CONFIGURATION=release bash scripts/build-app.sh   # signed Release bundle
```

- `build-app.sh` needs a persistent code-signing identity in `.signing-identity` (SHA-1 from `security find-identity -v -p codesigning`) or `BILINEXT_SIGNING_IDENTITY`; ad-hoc signing is refused. It copies libmpv + deps into the bundle via `scripts/bundle-mpv.py` (prefers IINA's `libmpv.2.dylib`, override with `BILINEXT_MPV_LIBRARY`; refuses Homebrew libs whose min OS > 26).
- Do not use `swift run` / unsigned builds to validate Keychain or login persistence — the signing identity differs.
- The full-repo strict format check passes; keep it green. Format-only changes go in separate commits.

### Opt-in integration tests
Network and hardware tests are gated by env vars and skipped by default. Examples:
- `BILINEXT_LIVE_TEST=1` public network / followed-live smoke; `BILINEXT_AUTH_TEST=1` authenticated read-only (Debug reuses the dev session file, no Keychain).
- `BILINEXT_MPV_TEST=1` real libmpv playback (`--filter mpvDirectDASHPlaysSeeksSwitchesAndRetainsTabs`, `playbackTabSwitchRetainsLoadedMedia`); add `BILINEXT_MPV_4K_TEST=1` for 4K AV1. With IINA's runtime set `DYLD_LIBRARY_PATH=/Applications/IINA.app/Contents/Frameworks`.
- `BILINEXT_RENDER_PREVIEW=1 swift test --filter VisualPreview` renders shared states, the scrubber and the action bar to PNGs (`BILINEXT_RENDER_DIR`, default /tmp). Glass and AppKit-backed views (ScrollView, HSplitView, video surfaces) render blank offscreen.
- Debug builds launched with `BILINEXT_DEBUG_OPEN_FIRST_TAB=1` open the first restored tab paused (no watch-history report), for screenshots without clicking; add `BILINEXT_DEBUG_PANEL=评论` (any playback panel name) to open that panel first. `BILINEXT_DEBUG_OPEN_SPACE=<mid>` opens that uploader's space page as a tab.
- Others: `BILINEXT_DASH_TEST`, `BILINEXT_LIVE_DANMAKU_TEST`, `BILINEXT_SUBTITLE_TEST`, `BILINEXT_HISTORY_TEST`, `BILINEXT_EXIT_HISTORY_TEST` — grep `Tests/` for `BILINEXT_` to find the gate and parameters.

## Architecture

Targets (Package.swift):
- `BiliNextCore` — UI-free library: `BilibiliAPI` (an `actor` owning an ephemeral URLSession + cookie jar, WBI signing in `WBISigner`, credential persistence), plus JSON parsers and models for videos, playback URLs, danmaku, comments, seasons, live rooms and the live danmaku WSS protocol. Parsers mostly work on `JSONSerialization` dictionaries. Tested by `BiliNextCoreTests` with fixtures.
- `BiliNext` — the executable app (SwiftUI/AppKit). `BiliNextTests` uses `@testable import BiliNext`.
- `CMPV` — modulemap/shim around libmpv.

**AppModel is both the workspace and each page.** `AppModel` (`@MainActor ObservableObject`) is split across `AppModel+Browsing/Tabs/Playback/Interaction/Subtitles/Login/Live/Termination.swift`. These files all implement one object — don't add new state sources or subscription layers. Members shared across extensions use internal access; everything else stays `private`. The root model (`managesPlaybackTabs`) owns `browseInstances` (one child `AppModel` per sidebar page, keyed by `browsePageID(for:)`) and `playbackInstances` (one child per open video/live tab). Sidebar pages are `BrowseDestination` cases; their Chinese raw values also prefix navigation routes and list cache keys (`"首页:推荐"`), so don't rename them. Children point back via `weak tabOwner` and forward tab/session operations to it. Switching pages keeps the same view identity and only changes visibility/input, so scroll position and loaded state survive. Background tabs are paused via `suspendPlaybackTabs`; closing a tab releases its player. High-frequency playback time lives in `PlaybackClock` and is deliberately *not* republished through the workspace (see docs/RENDERING-PERFORMANCE.md).

**Playback engines.** The main player is `MPVPlayer` (libmpv, separate DASH video/audio URLs loaded via mpv EDL with Referer/UA headers, VideoToolbox hwdec, rendered by `MPVVideoLayer`, a `CAOpenGLLayer` that draws libmpv render API frames on its own serial queue, off the main thread, hosted by `MPVSurface`). Hover previews use a muted AVPlayer. The older AVPlayer/DASH resource-loader classes (`DASH*.swift`, `MediaResourceLoader`) remain only for `DASHTests` and hover previews; `AppModel` no longer has an AVPlayer media-loading path, so playback changes go through MPV and `PlaybackRecovery` (which handles AV1/HEVC → H.264 and DASH → MP4 fallback). Optionally, "本机官方核心" (`OfficialClientPlayerView`) runs the nano player read from the locally installed official Bilibili app's `app.asar` inside a WKWebView — that code is never bundled. Live rooms (`LiveSession`, `LivePlaybackView`) reuse MPV and the tab lifecycle; live chat comes from `LiveDanmaku` (WSS with auth/heartbeat, zlib frames, strict size limits).

**Design system.** `GlassTheme` holds the tokens (type scale, radii, `accent`/`canvas`/`raisedFill`, hover/press opacity) and `Motion` the three animation speeds; use them instead of literals. Pink marks state only. The shell is Arc-like: wallpaper backdrop, sidebar drawn on it, content in an inset card, shared `BrowseToolbar`. See docs/design/redesign-2026-10.md.

**Overlays.** Danmaku (`DanmakuModel`/`DanmakuSurface`) uses cached text bitmaps and Core Animation layers, driven straight from mpv time. Subtitles support primary + secondary tracks on independent timelines. `SmartSubtitleModel` / `HardSubtitleRecognizer` use Vision OCR to detect burned-in subtitles and hide duplicate soft subs.

**Persistence.**
- Tabs/positions: `SessionStore` → `~/Library/Application Support/BiliNext/session.json`.
- Credentials: Release uses Keychain only. `DEBUG` builds use `DevelopmentSessionStore` (`…/BiliNext/Development/login-session.json`, 0600, unencrypted by the user's explicit choice). The Debug backend is behind `#if DEBUG`; never let Release fall back to it.
- Watch history: `WatchHistoryReporter` → `WatchHistoryOutbox` (per-account durable retry queue, flushed for up to ~2s at quit via `AppTerminationDelegate`). Live streams are never reported as watch history.

## Project rules (from CONTRIBUTING.md / README)
- 4-space indent, 100-column target, file names match their primary type.
- One purpose per commit. Before committing: format check + `swift test`; also `swift build -c release` when conditional compilation is involved.
- After changing windows, player or navigation, verify in the signed app from `build-app.sh`: tab switching, close/undo, restart restore, pause, subtitle jump. Record what was not verified.
- Account write operations (like, coin, favorite, history writes in tests) must only run from a user action or with explicit authorization. Default tests never hit real accounts.
- Don't bypass paywall/region/account restrictions. Reference projects (PiliPlus, BBHouse, bilibili-api, `../prototypes/SidebarStudy`) live outside this repo; don't copy their source, since license review is still pending.
- `docs/VALIDATION.md` is the current validation record (dated entries, split into offline / network / real-UI). Topic docs in `docs/` keep the historical evidence. Don't keep test counts in README. `docs/PILIPLUS-MIGRATION.md` tracks feature parity and the TODO list.
