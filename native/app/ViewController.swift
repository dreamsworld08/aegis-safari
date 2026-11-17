import Cocoa
import CommonCrypto
import SafariServices
import WebKit

private let appBundleID = Bundle.main.bundleIdentifier ?? "dev.aegis.safari"
private let extensionBundleIdentifier = appBundleID + ".Extension"

/// Container-app window: shows extension state and runs the in-app updater.
class ViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    @IBOutlet var webView: WKWebView!

    private let updater = Updater()
    private var pending: Updater.Release?
    private let autoInstall = ProcessInfo.processInfo.arguments.contains("--install-update")

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "controller")
        webView.loadFileURL(Bundle.main.url(forResource: "Main", withExtension: "html")!,
                            allowingReadAccessTo: Bundle.main.resourceURL!)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            DispatchQueue.main.async {
                self.call("show", ["enabled": state?.isEnabled ?? false, "version": Updater.currentVersion])
            }
        }
        check()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "open-preferences":
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
        case "check-update": check()
        case "install-update": install()
        default: break
        }
    }

    private func call(_ fn: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(fn)(\(json))", completionHandler: nil)
    }

    private func check() {
        call("updateStatus", ["state": "checking"])
        updater.fetchLatest { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    self.call("updateStatus", ["state": "error", "message": e.localizedDescription])
                case .success(let rel):
                    if let rel = rel, Updater.isNewer(rel.version, than: Updater.currentVersion) {
                        self.pending = rel
                        self.call("updateStatus", ["state": "available", "latest": rel.version])
                        if self.autoInstall { self.install() }
                    } else {
                        self.call("updateStatus", ["state": "current", "latest": rel?.version ?? ""])
                    }
                }
            }
        }
    }

    private func install() {
        guard let rel = pending else { return check() }
        call("updateStatus", ["state": "installing", "latest": rel.version])
        updater.install(rel) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    self.call("updateStatus", ["state": "error", "message": e.localizedDescription])
                case .success(let app):
                    self.call("updateStatus", ["state": "relaunching", "latest": rel.version])
                    Updater.relaunch(app)
                }
            }
        }
    }
}

/// Self-updater backed by GitHub Releases. Integrity: HTTPS, fixed repo path,
/// SHA-256 checksum asset, matching bundle id, newer version and a valid code signature.
final class Updater {
    struct Release { let version: String; let zip: URL; let sha256: URL? }
    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static let repo = "dreamsworld08/aegis-safari"
    static let assetName = "Aegis-macOS-arm64.zip"

    static var currentVersion: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let appex = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
               .first(where: { $0.pathExtension == "appex" }),
           let v = manifestVersion(appex: appex) { return v }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func manifestVersion(appex: URL) -> String? {
        let url = appex.appendingPathComponent("Contents/Resources/manifest.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repo)/releases/download/")
    }

    func fetchLatest(_ done: @escaping (Result<Release?, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return done(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return done(.success(nil)) }
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let assets = obj["assets"] as? [[String: Any]] else {
                return done(.failure(UpdateError("Update check failed (HTTP \(code)).")))
            }
            func asset(_ name: String) -> URL? {
                assets.first { ($0["name"] as? String) == name }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap(URL.init(string:))
            }
            guard let zip = asset(Self.assetName) else {
                return done(.failure(UpdateError("Release \(tag) has no app download.")))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            done(.success(Release(version: version, zip: zip, sha256: asset(Self.assetName + ".sha256"))))
        }.resume()
    }

    func install(_ rel: Release, _ done: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do { done(.success(try self.performInstall(rel))) } catch { done(.failure(error)) }
        }
    }

    private func performInstall(_ rel: Release) throws -> URL {
        guard let shaURL = rel.sha256 else { throw UpdateError("Release has no checksum; not installing.") }
        guard Self.trusted(rel.zip), Self.trusted(shaURL) else { throw UpdateError("Untrusted download location.") }

        let fm = FileManager.default
        let dest = Bundle.main.bundleURL
        // Staging dir on the same volume as the app so the swap is atomic.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
        defer { try? fm.removeItem(at: work) }

        let zipData = try Self.fetch(rel.zip)
        let expected = String(decoding: try Self.fetch(shaURL), as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        guard !expected.isEmpty, Self.sha256(zipData) == expected else {
            throw UpdateError("Checksum mismatch; download discarded.")
        }

        let zipURL = work.appendingPathComponent("update.zip")
        try zipData.write(to: zipURL)
        let unpack = work.appendingPathComponent("unpacked")
        try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpack.path])

        guard let newApp = try fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("Downloaded app is not Aegis.")
        }
        if let appex = try? fm.contentsOfDirectory(at: newApp.appendingPathComponent("Contents/PlugIns"), includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "appex" }),
           let newVersion = Self.manifestVersion(appex: appex),
           !Self.isNewer(newVersion, than: Self.currentVersion) {
            throw UpdateError("Downloaded version \(newVersion) is not newer.")
        }
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        // Once installed from a team-signed build, only accept updates signed by the same team.
        if let mine = Self.teamID(Bundle.main.bundleURL), Self.teamID(newApp) != mine {
            throw UpdateError("Update is not signed by the same developer (team \(mine)); not installing.")
        }

        do {
            _ = try fm.replaceItemAt(dest, withItemAt: newApp)
        } catch {
            throw UpdateError("Could not replace \(dest.path). Make sure Aegis is in /Applications and you are an admin user. (\(error.localizedDescription))")
        }
        _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        return dest
    }

    /// Team identifier of a signed bundle; nil for ad-hoc or unsigned code.
    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let c = code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func fetch(_ url: URL) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, Error> = .failure(UpdateError("Download failed: \(url.lastPathComponent)"))
        URLSession.shared.dataTask(with: url) { d, r, e in
            if let e = e { out = .failure(e) }
            else if let d = d, (r as? HTTPURLResponse)?.statusCode == 200 { out = .success(d) }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) failed (exit \(p.terminationStatus)).")
        }
        return p.terminationStatus
    }
}
