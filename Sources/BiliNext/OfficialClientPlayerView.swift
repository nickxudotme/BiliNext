import SwiftUI
import WebKit

/// Thin host for the installed official client's nano core, without a website page.
struct OfficialClientPlayerView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(context.coordinator, name: "playback")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        model.officialWebView = web
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        guard let video = model.detail?.video, let cid = model.pageID else { return }
        let key = "\(video.bvid):\(cid)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        context.coordinator.task?.cancel()
        let start = model.time
        let options: [String: Any] = [
            "bvid": video.bvid, "cid": cid, "aid": video.aid ?? 0,
            "episodeId": video.episodeID ?? 0, "kind": video.episodeID == nil ? "Ugc" : "Pgc",
            "start": start,
        ]
        let json =
            String(
                data: (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8),
                encoding: .utf8) ?? "{}"
        model.officialPlayerStatus = "正在加载本机官方播放器核心…"
        context.coordinator.task = Task { @MainActor in
            do {
                let core = try await Task.detached(priority: .userInitiated) {
                    try OfficialClientResources.playerCore()
                }.value
                guard !Task.isCancelled else { return }
                for cookie in await model.api.officialPlayerCookies() {
                    await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
                guard !Task.isCancelled else { return }
                let controller = web.configuration.userContentController
                controller.removeAllUserScripts()
                let bootstrap = """
                    const report=(state)=>window.webkit.messageHandlers.playback.postMessage(state);
                    window.addEventListener('error',()=>{ if(!window.biliPlayer) report({status:'核心运行错误'}); });
                    window.addEventListener('unhandledrejection',()=>{ if(!window.biliPlayer) report({status:'核心请求失败'}); });
                    window.appRequestLogin=()=>report({action:'login'});
                    window.appRequestFullScreen=(callback)=>{ document.getElementById('player').requestFullscreen?.(); callback?.(); };
                    """
                controller.addUserScript(
                    WKUserScript(
                        source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                controller.addUserScript(
                    WKUserScript(
                        source: core, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                let initialize = """
                    (async()=>{
                        try {
                            const options=\(json), nano=window.nano;
                            if(!nano) throw new Error('Missing nano');
                            window.biliPlayer=nano.createPlayer({
                                element:document.getElementById('player'), fullWrap:document.body,
                                channelKind:nano.ChannelKind.PC_APP, kind:nano.GroupKind[options.kind],
                                bvid:options.bvid, aid:options.aid, cid:options.cid, episodeId:options.episodeId,
                                autoplay:false, enableAV1:false, enableHEVC:false, hideBoxShadow:true,
                                appInfo:{platform:'mac',mobi_app:'pc_link',build:1190000},
                                featureList:new Set(['noVVReport','noVTReport']),
                            });
                            const player=window.biliPlayer;
                            report({status:'核心已创建，正在连接媒体…'});
                            await player.connect();
                            if(options.start>0) await player.seek(options.start);
                            report({status:''});
                            setInterval(()=>{
                                const time=player.getCurrentTime(),duration=player.getDuration();
                                if(Number.isFinite(time)) report({time,duration:Number.isFinite(duration)?duration:0,playing:!player.isPaused()});
                            },250);
                        } catch(error) { report({status:'官方核心连接失败：'+String(error?.name||'Error')}); }
                    })();
                    """
                controller.addUserScript(
                    WKUserScript(
                        source: initialize, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                web.loadHTMLString(
                    "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body,#player{margin:0;width:100%;height:100%;overflow:hidden;background:#000} .bpx-player-container{width:100%;height:100%}</style></head><body><div id='player'></div></body></html>",
                    baseURL: URL(string: "https://www.bilibili.com/"))
            } catch {
                guard !Task.isCancelled else { return }
                model.officialPlayerStatus = error.localizedDescription
            }
        }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        web.stopLoading()
        web.evaluateJavaScript("window.biliPlayer?.pause(); window.biliPlayer?.dispose?.();")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "playback")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var model: AppModel?
        var key = ""
        var task: Task<Void, Never>?
        var lastSave = Date()
        init(model: AppModel) { self.model = model }
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame, let model, model.officialCore,
                let state = message.body as? [String: Any]
            else { return }
            if let status = state["status"] as? String { model.officialPlayerStatus = status }
            if state["action"] as? String == "login" { model.loginPresented = true }
            guard let time = state["time"] as? Double, time.isFinite, time >= 0 else { return }
            model.time = time
            model.duration = state["duration"] as? Double ?? 0
            model.playing = state["playing"] as? Bool ?? false
            if Date().timeIntervalSince(lastSave) > 5 {
                model.saveSession()
                lastSave = Date()
            }
        }
        func webView(
            _ web: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            if action.navigationType == .linkActivated {
                if url.scheme == "https" { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            let host = url.host ?? ""
            decisionHandler(
                url.absoluteString == "about:blank"
                    || url.scheme == "https"
                        && (host == "bilibili.com" || host.hasSuffix(".bilibili.com"))
                    ? .allow : .cancel)
        }
    }
}
