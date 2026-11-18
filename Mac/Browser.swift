import AppKit
import Observation
import SwiftUI
import WebKit

/// A small built-in browser. Anything you download goes straight into
/// Documents/Songs/Floaters (and so into the Floating list).
///
/// Memory: WebKit runs each site in its own helper process. The browser only
/// exists while its window is open; closing the window tears it down, so it
/// costs nothing the rest of the time. Ads and trackers are blocked, which
/// trims a lot on ad-heavy sites, and the toolbar shows the page's memory with
/// a warning above 100 MB.
@MainActor @Observable
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    struct Download: Identifiable {
        let id = UUID()
        var name: String
        var progress: Double = 0
        var done = false
        var failed = false
        @ObservationIgnored var observer: NSKeyValueObservation?
    }

    static let limitMB = 100.0

    private(set) var webView: WKWebView?
    var address = ""
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    private(set) var progress = 0.0
    /// The page's memory (its WebKit process), in MB.
    private(set) var memoryMB: Double = 0
    private(set) var downloads: [Download] = []
    var blockAds = UserDefaults.standard.object(forKey: "browserBlockAds") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(blockAds, forKey: "browserBlockAds")
            applyRules()
            webView?.reload()
        }
    }

    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var memoryTimer: Timer?
    @ObservationIgnored fileprivate var rules: WKContentRuleList?
    @ObservationIgnored private var destinations: [ObjectIdentifier: UUID] = [:]

    var overLimit: Bool { memoryMB > Self.limitMB }

    // MARK: Lifecycle

    /// Creates the web view when the window opens (and reopens the last site).
    func attach() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()            // keeps logins and cookies
        config.suppressesIncrementalRendering = false
        config.preferences.isElementFullscreenEnabled = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = nil
        webView = web

        observers = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            web.observe(\.isLoading, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.loading = w.isLoading } },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
            web.observe(\.title, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            web.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = w.url else { return }
                    self.address = url.absoluteString
                    UserDefaults.standard.set(url.absoluteString, forKey: "browserLastURL")
                } },
        ]
        applyRules()
        let last = UserDefaults.standard.string(forKey: "browserLastURL") ?? "https://www.google.com"
        go(last)

        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
        memoryTimer?.tolerance = 0.5
        return web
    }

    /// Window closed: drop the web view so WebKit's page process goes away.
    func teardown() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        observers = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        memoryMB = 0
        loading = false
    }

    // MARK: Navigation

    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url: URL?
        if trimmed.contains(" ") || !trimmed.contains(".") {
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = comps.url
        } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            url = URL(string: trimmed)
        } else {
            url = URL(string: "https://" + trimmed)
        }
        guard let url else { return }
        address = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reloadOrStop() {
        if loading { webView?.stopLoading() } else { webView?.reload() }
    }

    // MARK: Memory

    /// The page process's memory footprint (what Activity Monitor shows as "Memory").
    private func measure() {
        guard let web = webView,
              let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return }
        guard let footprint = Self.footprint(pid) else { return }
        let mb = Double(footprint) / 1_048_576
        if abs(mb - memoryMB) >= 1 { memoryMB = mb }
    }

    private nonisolated static func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result: Int32 = withUnsafeMutablePointer(to: &usage) { (ptr: UnsafeMutablePointer<rusage_info_v4>) -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { (raw: UnsafeMutablePointer<rusage_info_t?>) -> Int32 in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    // MARK: Ad blocking

    private func applyRules() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllContentRuleLists()
        guard blockAds else { return }
        if let rules {
            controller.add(rules)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "musiplex-adblock-1",
                                                                encodedContentRuleList: Self.adRules) { [weak self] list, _ in
            Task { @MainActor in
                guard let self, let list else { return }
                self.rules = list
                if self.blockAds { self.webView?.configuration.userContentController.add(list) }
            }
        }
    }

    /// Common ad, tracker and pop-up networks (third-party loads only).
    private static let adRules: String = {
        let domains = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
            "googletagmanager.com", "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
            "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "taboola.com", "outbrain.com", "criteo.com",
            "criteo.net", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "scorecardresearch.com",
            "quantserve.com", "moatads.com", "adform.net", "smartadserver.com", "yieldmo.com", "media.net",
            "zedo.com", "propellerads.com", "popads.net", "popcash.net", "adsterra.com", "exoclick.com",
            "juicyads.com", "hilltopads.net", "onclickads.net", "trafficjunky.net", "mgid.com", "revcontent.com",
            "hotjar.com", "mouseflow.com", "fullstory.com", "facebook.net", "connect.facebook.net", "ads-twitter.com",
            "analytics.twitter.com", "bat.bing.com", "clarity.ms", "adcolony.com", "applovin.com", "unityads.unity3d.com",
            "chartbeat.com", "newrelic.com", "nr-data.net", "segment.io", "mixpanel.com", "branch.io",
            "onesignal.com", "pushwoosh.com", "a-ads.com", "coinzilla.com", "bidvertiser.com", "adcash.com",
        ]
        let rules = domains.map { d in
            """
            {"trigger":{"url-filter":"^https?://([^/]+\\\\.)?\(d.replacingOccurrences(of: ".", with: "\\\\."))[/:]","load-type":["third-party"]},"action":{"type":"block"}}
            """
        }
        return "[" + rules.joined(separator: ",") + "]"
    }()

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Anything the browser can't show (or that says "attachment") is a download.
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"), disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        if let mime = navigationResponse.response.mimeType, mime.hasPrefix("audio/") || mime == "application/octet-stream" {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { adopt(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { adopt(download) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page process crashed or was ended by macOS (e.g. memory): reload it.
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// Links that open a new window open here instead (one page at a time keeps memory down).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: Downloads → Floaters

    private func adopt(_ download: WKDownload) {
        download.delegate = self
        var item = Download(name: "Downloading…")
        item.observer = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let value = p.fractionCompleted
            Task { @MainActor in
                guard let self, let i = self.downloads.firstIndex(where: { $0.id == item.id }) else { return }
                if value - self.downloads[i].progress > 0.02 || value >= 1 { self.downloads[i].progress = value }
            }
        }
        downloads.insert(item, at: 0)
        destinations[ObjectIdentifier(download)] = item.id
        if downloads.count > 20 { downloads.removeLast() }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = LibraryStore.floatersFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = suggestedFilename.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: " ")
        var target = folder.appendingPathComponent(clean)
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        if let id = destinations[ObjectIdentifier(download)], let i = downloads.firstIndex(where: { $0.id == id }) {
            downloads[i].name = target.lastPathComponent
        }
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, failed: false)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, failed: true)
    }

    private func finish(_ download: WKDownload, failed: Bool) {
        guard let id = destinations.removeValue(forKey: ObjectIdentifier(download)),
              let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].done = !failed
        downloads[i].failed = failed
        downloads[i].progress = failed ? downloads[i].progress : 1
        downloads[i].observer = nil
    }
}

// MARK: - Self-test

extension Browser {
    func selfTest(report: String, model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 1100, height: 760), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView().environment(model))
        window.orderFrontRegardless()
        var lines: [String] = []
        Task {
            go("https://en.wikipedia.org/wiki/Music")
            try? await Task.sleep(for: .seconds(12))
            lines.append("title: \(title)")
            lines.append(String(format: "page memory: %.0f MB (limit %.0f, over: %@)", memoryMB, Browser.limitMB, overLimit ? "yes" : "no"))
            lines.append("ad rules compiled: \(rules != nil)")
            go("https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3")
            for _ in 0..<60 where !(downloads.first?.done ?? false) && !(downloads.first?.failed ?? false) {
                try? await Task.sleep(for: .seconds(1))
            }
            lines.append("download: \(downloads.first.map { "\($0.name) done=\($0.done) failed=\($0.failed)" } ?? "none")")
            window.close()
            teardown()
            try? await Task.sleep(for: .seconds(2))
            lines.append(String(format: "after close: %.0f MB, web view gone: %@", memoryMB, webView == nil ? "yes" : "no"))
            try? lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Window

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showDownloads = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var browser = model.browser
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navButton("chevron.left", enabled: browser.canGoBack) { browser.back() }
                navButton("chevron.right", enabled: browser.canGoForward) { browser.forward() }
                navButton(browser.loading ? "xmark" : "arrow.clockwise", enabled: true) { browser.reloadOrStop() }

                HStack(spacing: 6) {
                    Image(systemName: browser.address.hasPrefix("https") ? "lock.fill" : "globe")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    TextField("Search or enter a site", text: $browser.address)
                        .textFieldStyle(.plain)
                        .focused($addressFocused)
                        .onSubmit { browser.go(browser.address); addressFocused = false }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(alignment: .bottom) {
                    if browser.loading {
                        GeometryReader { geo in
                            Capsule().fill(Theme.gradient).frame(width: geo.size.width * browser.progress, height: 2)
                        }
                        .frame(height: 2)
                    }
                }

                memoryBadge(browser)

                Button { showDownloads.toggle() } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(browser.downloads.contains { !$0.done && !$0.failed } ? Theme.accent : .white)
                        .overlay(alignment: .topTrailing) {
                            if !browser.downloads.isEmpty {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 3, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("Downloads (saved to Documents › Songs › Floaters)")
                .popover(isPresented: $showDownloads, arrowEdge: .bottom) { downloadsList(browser) }

                Toggle(isOn: $browser.blockAds) { Image(systemName: "shield.lefthalf.filled") }
                    .toggleStyle(.button)
                    .help(browser.blockAds ? "Blocking ads and trackers" : "Ads allowed")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel)

            if browser.overLimit {
                HStack(spacing: 10) {
                    Image(systemName: "memorychip").foregroundStyle(.orange)
                    Text("This page is using \(Int(browser.memoryMB)) MB, over your \(Int(Browser.limitMB)) MB limit. Closing the browser frees it all.")
                        .font(.callout)
                    Spacer()
                    Button("Close Browser") { dismissWindow(id: "browser") }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
            }

            WebViewHost(browser: browser)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Theme.bg)
        .onDisappear { browser.teardown() }
        .navigationTitle(browser.title.isEmpty ? "Browser" : browser.title)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func memoryBadge(_ browser: Browser) -> some View {
        Text(browser.memoryMB > 0 ? "\(Int(browser.memoryMB)) MB" : "— MB")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((browser.overLimit ? Color.orange : Color.white).opacity(0.15), in: Capsule())
            .foregroundStyle(browser.overLimit ? .orange : .white)
            .help("Memory used by this page. Closing the browser frees it.")
    }

    private func downloadsList(_ browser: Browser) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(LibraryStore.floatersFolder) }
            }
            Text("Saved to Documents › Songs › Floaters. Music files appear in the Floating list in Settings.")
                .font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            if browser.downloads.isEmpty {
                Text("Nothing downloaded yet.").font(.callout).foregroundStyle(Theme.dim)
            }
            ForEach(browser.downloads) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: item.failed ? "exclamationmark.triangle.fill" : item.done ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(item.failed ? .orange : item.done ? .green : Theme.accent)
                        Text(item.name).lineLimit(1).font(.callout)
                    }
                    if !item.done, !item.failed { ProgressView(value: item.progress).tint(Theme.accent) }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Hosts the browser's WKWebView (created when the window opens).
private struct WebViewHost: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let web = browser.attach()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
