# BiliNext macOS glass design

Profile: standard. Keep the compact browser sidebar and artwork-led video grid.

> 2026-10-14 起外壳与设计系统由 [2026-10 体验重设计](redesign-2026-10.md) 取代：壁纸底层 + 嵌入内容卡片、系统红绿灯、共享工具栏和 GlassTheme v2。下文为此前方案的历史记录。

Considered directions: editorial discovery with a large hero; cinematic artwork-driven atmosphere; restrained native glass. The third fits the approved 220pt sidebar and main-window playback and avoids adding decorative content or extra motion.

## Design system

`GlassTheme.swift` defines canvas, pink selection accent, 8pt rows, 12pt artwork, 16pt floating panels and 28pt content insets. Glass is reserved for actionable chrome. Sidebar uses thin material so its glass controls do not sit on another glass effect. Video artwork has a quiet hairline edge, with no glass content-card background. Selected navigation has weight and an outline as well as color.

ChromeSurface, SidebarSurface and DetailSurface provide opaque system-color alternatives for Reduce Transparency. Chrome outlines strengthen under Increase Contrast. Sidebar transitions honor Reduce Motion. Main-window playback, fixed sidebar width, menu order, bindings, callbacks and services remain unchanged.

The 2026-10-13 readability pass adds shared 16/15/14/13/12pt typography and explicit control sizing, wider video cards, labelled playback actions and comments with a separate header and body. See [UI scale comparison and verification](ui-scale.md) for the official-client comparison and current evidence; the earlier verification below remains historical.

## Skills

- ehmo/platform-design-skills: macos-design-guidelines
- Wholiver/swiftui-design-skill: existing installation reused
- ZHUOLIN0928/swiftui-interface-design-skill: installed as swiftui-interface-design
- AkiKawasaki21/swiftui-glass-ui-codex-skill: swiftui-glass-ui-designer
- twostraws/swiftui-agent-skill: swiftui-pro

The installed SDK and project target take precedence over version assumptions in community skills. Keep macOS 26 deployment and existing Swift language mode.

## Verification, 2026-10-11

- swift build: passed on Xcode 27.0 / Swift 6.4.
- swift test: 19 app tests and 20 core tests passed.
- scripts/build-app.sh: passed including persistent code signing verification.
- Skill audit: zero high findings; existing medium findings include fixed dimensions, font sizes, gestures and cancellable UI delays. This is a heuristic scan, not a clean accessibility audit.
- Real app: dark dynamic feed, video metadata, hover preview, empty search, sidebar hide/reveal and floating panel reviewed through CUA.
- Diff scope: SwiftUI presentation files and design documentation only.

Not yet visually verified: light appearance, increased contrast, Reduce Transparency and Reduce Motion, smallest window, VoiceOver, full playback details and login sheet. No Instruments performance measurement was collected. The reduced-effects paths are implemented but not claimed as runtime verified.

Provisional Apple Fidelity: platform 13/15, layout 13/15, visual system 13/15, interaction 16/20, materials 12/15, accessibility 5/10, quality 7/10 = 79/100. Evidence cap applies because the complete visual and accessibility matrix has not run. Five-dimension provisional visual review: philosophy 8, hierarchy 8, craft 7, functionality 7, originality 7. These scores describe this pass, not an Apple-quality certification.

Existing build warnings: deprecated OpenGL APIs in MPVPlayer and Homebrew libmpv built for macOS 27 while this package targets macOS 26. Neither was introduced or changed by the visual pass.
