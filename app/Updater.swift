import AppKit
import Foundation

/// Dernière version publiée dans les Releases GitHub du projet
struct Release: Equatable {
    let version: String
    let notes: String
    let page: URL
    let download: URL
}

/// Mise à jour depuis GitHub : recherche, téléchargement, remplacement de l'application, relance
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(Release, String)
        case failed(String)
    }

    static let autoKey = "autoCheckUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let api = URL(string: "https://api.github.com/repos/AlexMouth/vpn-rotate/releases/latest")!
    private static let assetName = "VPN-Rotate.zip"

    @Published private(set) var phase = Phase.idle
    let current: String
    private let app: URL

    init(current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         app: URL = Bundle.main.bundleURL) {
        self.current = current
        self.app = app
        Task { await checkPeriodically() }
    }

    var available: Release? {
        if case .available(let release) = phase { return release }
        return nil
    }

    var busy: Bool {
        switch phase {
        case .checking, .installing: true
        default: false
        }
    }

    /// Une recherche discrète au plus par jour, tant que l'application est ouverte
    private func checkPeriodically() async {
        while !Task.isCancelled {
            let enabled = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
            let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
            if enabled, Date().timeIntervalSince(last) > 86_400, !busy, available == nil {
                await check(quietly: true)
            }
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    /// `quietly` : une erreur réseau ne s'affiche pas (recherche automatique)
    func check(quietly: Bool = false) async {
        guard !busy else { return }
        let before = phase
        phase = .checking
        do {
            let release = try await Self.latest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            phase = Self.isNewer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            phase = quietly ? before : .failed("Recherche impossible : \(error.localizedDescription)")
        }
    }

    private static func latest() async throws -> Release {
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VPN-Rotate", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 404: throw UpdateError("aucune version publique trouvée sur GitHub")
        default: throw UpdateError("GitHub ne répond pas")
        }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("La dernière version ne contient pas \(assetName)")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, notes: payload.body ?? "", page: payload.html_url,
                       download: asset.browser_download_url)
    }

    /// Compare "2.10" et "2.9" chiffre par chiffre
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installation

    /// Télécharge, vérifie, remplace l'application puis relance la nouvelle version
    func install(_ release: Release) async {
        guard !busy else { return }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            phase = .failed("Impossible de remplacer l'application dans « \(folder.lastPathComponent) ». "
                            + "Téléchargez la nouvelle version depuis GitHub.")
            return
        }
        do {
            phase = .installing(release, "Téléchargement…")
            let (zip, response) = try await URLSession.shared.download(from: release.download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Téléchargement refusé") }

            phase = .installing(release, "Vérification…")
            let app = self.app, expectedID = Bundle(url: app)?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
            try await Task.detached {
                let fresh = try Self.unpack(zip, near: app, expectedID: expectedID, version: release.version)
                try Self.replace(app, with: fresh)
            }.value

            phase = .installing(release, "Redémarrage…")
            relaunch()
        } catch {
            phase = .failed("Mise à jour impossible : \(error.localizedDescription)")
        }
    }

    /// Décompresse l'archive à côté de l'application (même disque, pour un échange instantané)
    /// et vérifie qu'il s'agit bien de VPN Rotate, dans la version annoncée, à la signature intacte
    nonisolated static func unpack(_ zip: URL, near app: URL, expectedID: String, version: String) throws -> URL {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        var verified = false
        defer { if !verified { try? fm.removeItem(at: work) } }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], "Archive illisible")
        guard let fresh = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("Aucune application dans l'archive") }
        let bundle = Bundle(url: fresh)
        guard bundle?.bundleIdentifier == expectedID else { throw UpdateError("L'archive ne contient pas VPN Rotate") }
        guard bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError("La version de l'archive ne correspond pas")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path], "Signature de l'application invalide")
        verified = true
        return fresh
    }

    /// Échange les deux applications d'un coup : l'ancienne n'est jamais à moitié remplacée
    nonisolated static func replace(_ app: URL, with fresh: URL) throws {
        _ = try FileManager.default.replaceItemAt(app, withItemAt: fresh)
        try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent())
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.phase = .failed("Nouvelle version installée, mais relance impossible : \(error.localizedDescription). Rouvrez VPN Rotate.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], _ failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(failure) }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
