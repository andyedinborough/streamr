import SwiftUI
import WebKit
import SwiftData

// MARK: - BrowserViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var urlString: String = "https://"
    @Published var pageTitle: String = ""
    @Published var pageURL: URL? = nil
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var pendingCandidate: MediaCandidate? = nil

    /// Persisted last-visited URL — read by WebViewRepresentable.makeUIView on first open,
    /// written by the url KVO observer every time the page changes.
    @AppStorage("browser.lastURL") var lastSavedURL: String = ""

    var webView: WKWebView?

    func load(_ string: String) {
        var raw = string.trimmingCharacters(in: .whitespaces)
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            if raw.contains(".") {
                raw = "https://" + raw
            } else {
                raw = "https://duckduckgo.com/?q=" + raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            }
        }
        guard let url = URL(string: raw) else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
}

// MARK: - BrowserView

struct BrowserView: View {
    /// The playlist to which newly-added episodes will be assigned.
    let playlist: Playlist

    @StateObject private var vm = BrowserViewModel()
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playerVM: PlayerViewModel

    @State private var showConfirmSheet = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            WebViewRepresentable(vm: vm)
                .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle("")
        .navigationBarHidden(true)
        .sheet(isPresented: $showConfirmSheet) {
            if let candidate = vm.pendingCandidate {
                DownloadConfirmationSheet(candidate: candidate) {
                    addToQueue(candidate: candidate)
                    showConfirmSheet = false
                    vm.pendingCandidate = nil
                } onCancel: {
                    showConfirmSheet = false
                    vm.pendingCandidate = nil
                }
            }
        }
        .onChange(of: vm.pendingCandidate) { _, new in
            showConfirmSheet = new != nil
        }
    }

    // MARK: Address bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button(action: { vm.goBack() }) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(vm.canGoBack ? .primary : .tertiary)
            }
            .disabled(!vm.canGoBack)

            Button(action: { vm.goForward() }) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(vm.canGoForward ? .primary : .tertiary)
            }
            .disabled(!vm.canGoForward)

            TextField("Search or enter URL", text: $vm.urlString)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { vm.load(vm.urlString) }

            if vm.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: { vm.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Add to queue

    private func addToQueue(candidate: MediaCandidate) {
        let nextPosition = (playlist.episodes.map(\.queuePosition).max() ?? -1) + 1
        let episode = Episode(
            title: candidate.pageTitle.isEmpty ? candidate.pageURL.host() ?? "Unknown" : candidate.pageTitle,
            sourcePageURL: candidate.pageURL.absoluteString,
            pageIconURL: candidate.pageIconURL,
            mediaURL: candidate.mediaURL.absoluteString,
            queuePosition: nextPosition,
            playlist: playlist
        )
        modelContext.insert(episode)
        try? modelContext.save()

        // Capture only Sendable values across the async boundary.
        let episodeID = episode.id
        let container = modelContext.container

        DownloadManager.shared.download(episode: episode) { localURL in
            // Use mainContext — it is always the same context SwiftUI's @Query uses,
            // and it is safe to touch on MainActor.
            Task { @MainActor in
                let ctx = container.mainContext
                // Walk the live objects to find our episode by ID.
                let all = (try? ctx.fetch(FetchDescriptor<Episode>())) ?? []
                guard let saved = all.first(where: { $0.id == episodeID }) else {
                    print("[addToQueue] Could not find episode \(episodeID) in mainContext")
                    return
                }
                if let localURL {
                    saved.localFilename = localURL.lastPathComponent
                    saved.isDownloaded = true
                    saved.downloadProgress = 1.0
                    print("[addToQueue] Saved episode \(episodeID) localFilename=\(localURL.lastPathComponent)")
                } else {
                    saved.downloadProgress = -1
                    print("[addToQueue] Download failed for episode \(episodeID)")
                }
                try? ctx.save()
            }
        }
    }
}

// MARK: - WKWebView Representable

struct WebViewRepresentable: UIViewRepresentable {
    let vm: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        vm.webView = webView
        context.coordinator.webView = webView
        context.coordinator.startObserving(webView)

        // Restore last visited URL, or fall back to Google on first launch.
        let startURL = vm.lastSavedURL.isEmpty ? "https://www.google.com" : vm.lastSavedURL
        webView.load(URLRequest(url: URL(string: startURL)!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator
    //
    // Deliberately NOT @MainActor — WKNavigationDelegate and WKDownloadDelegate methods
    // are called by WebKit from its own internal queue. Marking the whole class @MainActor
    // causes the async delegate methods to be silently skipped or deadlocked because WebKit
    // cannot satisfy the actor isolation requirement. We hop to MainActor explicitly only
    // when touching the view model.

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let vm: BrowserViewModel
        weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        // Protects pendingDownloadContext from concurrent access (WebKit may call
        // delegate methods from different threads).
        private let lock = NSLock()
        private var _pendingDownloadContext: [ObjectIdentifier: (mediaURL: URL, pageURL: URL, title: String)] = [:]

        private func storeContext(_ ctx: (mediaURL: URL, pageURL: URL, title: String), for download: WKDownload) {
            lock.lock(); defer { lock.unlock() }
            _pendingDownloadContext[ObjectIdentifier(download)] = ctx
        }
        private func popContext(for download: WKDownload) -> (mediaURL: URL, pageURL: URL, title: String)? {
            lock.lock(); defer { lock.unlock() }
            return _pendingDownloadContext.removeValue(forKey: ObjectIdentifier(download))
        }

        init(vm: BrowserViewModel) {
            self.vm = vm
        }

        func startObserving(_ wv: WKWebView) {
            observations = [
                wv.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                    let v = wv.canGoBack
                    Task { @MainActor [weak self] in self?.vm.canGoBack = v }
                },
                wv.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                    let v = wv.canGoForward
                    Task { @MainActor [weak self] in self?.vm.canGoForward = v }
                },
                wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                    let v = wv.isLoading
                    Task { @MainActor [weak self] in self?.vm.isLoading = v }
                },
                wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    guard let url = wv.url else { return }
                    let str = url.absoluteString
                    Task { @MainActor [weak self] in
                        self?.vm.pageURL = url
                        self?.vm.urlString = str
                        self?.vm.lastSavedURL = str
                    }
                },
                wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                    let t = wv.title ?? ""
                    Task { @MainActor [weak self] in self?.vm.pageTitle = t }
                }
            ]
        }

        // MARK: - Navigation delegates

        // Use the iOS 13+ three-parameter variant — WebKit prefers this over the
        // two-parameter version on modern OS versions.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            let url = navigationAction.request.url
            print("[Browser] navigationAction url=\(url?.absoluteString ?? "nil") type=\(navigationAction.navigationType.rawValue) targetFrame=\(navigationAction.targetFrame?.isMainFrame == true ? "main" : navigationAction.targetFrame == nil ? "nil(new window)" : "subframe")")

            guard let url else { decisionHandler(.allow, preferences); return }

            // Known media extension — intercept immediately.
            if isMediaURL(url) {
                print("[Browser] navigationAction -> media extension, downloading")
                decisionHandler(.download, preferences)
                return
            }

            // Subframe navigations and new-window navigations (targetFrame == nil) that
            // are user-initiated link taps are almost certainly download links — the page
            // opened a subframe or new target to trigger the download.  Route them straight
            // to .download so WebKit hands them to WKDownloadDelegate before SOAuthorization
            // or any other system handler can intercept.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            if !isMainFrame && navigationAction.navigationType == .linkActivated {
                print("[Browser] navigationAction -> non-main-frame link tap, routing to download")
                decisionHandler(.download, preferences)
                return
            }

            decisionHandler(.allow, preferences)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mimeType = navigationResponse.response.mimeType
            let url      = navigationResponse.response.url
            print("[Browser] navigationResponse url=\(url?.absoluteString ?? "nil") mimeType=\(mimeType ?? "nil") mainFrame=\(navigationResponse.isForMainFrame)")

            if isMediaMIMEType(mimeType) {
                print("[Browser] navigationResponse -> media MIME, routing to WKDownload")
                decisionHandler(.download)
                return
            }
            if let url, isMediaURL(url) {
                print("[Browser] navigationResponse -> media URL extension, routing to WKDownload")
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            print("[Browser] redirect -> now at \(webView.url?.absoluteString ?? "nil")")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[Browser] didFailProvisionalNavigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[Browser] didFail: \(error)")
        }

        // MARK: - WKDownload bridging

        /// Fired when decidePolicyFor navigationResponse returns .download
        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            print("[Browser] navigationResponse didBecome download: \(navigationResponse.response.url?.absoluteString ?? "nil")")
            download.delegate = self
            let pageURL  = webView.url ?? navigationResponse.response.url ?? URL(string: "about:blank")!
            let title    = webView.title ?? ""
            let mediaURL = navigationResponse.response.url ?? pageURL
            storeContext((mediaURL: mediaURL, pageURL: pageURL, title: title), for: download)
        }

        /// Fired when decidePolicyFor navigationAction returns .download
        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            print("[Browser] navigationAction didBecome download: \(navigationAction.request.url?.absoluteString ?? "nil")")
            download.delegate = self
            let pageURL  = webView.url ?? navigationAction.request.url ?? URL(string: "about:blank")!
            let title    = webView.title ?? ""
            let mediaURL = navigationAction.request.url ?? pageURL
            storeContext((mediaURL: mediaURL, pageURL: pageURL, title: title), for: download)
        }

        // MARK: - WKDownloadDelegate

        /// WebKit asks where to save the file. We return nil to cancel the WKDownload,
        /// then hand off to our own URLSession-based download manager via the sheet.
        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            print("[Browser] WKDownloadDelegate decideDestination suggestedFilename=\(suggestedFilename)")
            completionHandler(nil)  // decline — we manage the download ourselves

            let ctx = popContext(for: download)
            let wv = webView  // capture weak ref value before async hop

            Task { @MainActor [weak self] in
                guard let self else { return }

                let iconURL = await Self.extractPageIconURL(from: wv)

                if let ctx {
                    print("[Browser] showing confirmation sheet for \(ctx.mediaURL)")
                    self.vm.pendingCandidate = MediaCandidate(
                        mediaURL:    ctx.mediaURL,
                        pageURL:     ctx.pageURL,
                        pageTitle:   ctx.title.isEmpty ? suggestedFilename : ctx.title,
                        pageIconURL: iconURL
                    )
                } else if let url = response.url {
                    print("[Browser] WKDownload context missing — using response URL")
                    self.vm.pendingCandidate = MediaCandidate(
                        mediaURL:    url,
                        pageURL:     url,
                        pageTitle:   suggestedFilename,
                        pageIconURL: iconURL
                    )
                }
            }
        }

        /// Runs JavaScript in the web view to find the best icon URL for the current page.
        /// Priority: og:image > apple-touch-icon > shortcut icon > /favicon.ico
        @MainActor
        private static func extractPageIconURL(from webView: WKWebView?) async -> String? {
            guard let webView else { return nil }
            let js = """
            (function() {
                var og = document.querySelector('meta[property="og:image"]');
                if (og && og.content) return og.content;
                var touch = document.querySelector('link[rel~="apple-touch-icon"]');
                if (touch && touch.href) return touch.href;
                var icon = document.querySelector('link[rel~="icon"]');
                if (icon && icon.href) return icon.href;
                return null;
            })()
            """
            let result = try? await webView.evaluateJavaScript(js)
            if let str = result as? String, !str.isEmpty {
                // Resolve relative URLs against the page origin.
                if str.hasPrefix("http://") || str.hasPrefix("https://") {
                    return str
                }
                if let base = webView.url {
                    return URL(string: str, relativeTo: base)?.absoluteString
                }
            }
            // Fall back to the standard favicon path.
            if let origin = webView.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
                var comps = origin
                comps.path = "/favicon.ico"
                comps.query = nil
                comps.fragment = nil
                return comps.url?.absoluteString
            }
            return nil
        }

        func downloadDidFinish(_ download: WKDownload) {
            print("[Browser] WKDownload finished (unexpected — we return nil destination)")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            print("[Browser] WKDownload failed: \(error)")
            _ = popContext(for: download)
        }
    }
}

// MARK: - Download Confirmation Sheet

struct DownloadConfirmationSheet: View {
    let candidate: MediaCandidate
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("Add to Queue", systemImage: "arrow.down.circle.fill")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").font(.caption).foregroundStyle(.secondary)
                    Text(candidate.pageTitle.isEmpty ? "(no title)" : candidate.pageTitle)
                        .font(.body)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Source").font(.caption).foregroundStyle(.secondary)
                    Text(candidate.pageURL.host() ?? candidate.pageURL.absoluteString)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Media URL").font(.caption).foregroundStyle(.secondary)
                    Text(candidate.mediaURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Spacer()

                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)

                    Button(action: onAdd) {
                        Label("Add & Download", systemImage: "arrow.down.circle")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium])
    }
}
