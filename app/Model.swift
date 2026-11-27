import SwiftUI

private let env = ProcessInfo.processInfo.environment
private let root = env["VPNROTATE_TEST_ROOT"] ?? ""
/// Dossier réservé à l'administrateur, rempli par install.sh
let helperPath = root + "/Library/PrivilegedHelperTools/local.vpnrotate"
/// L'ancien emplacement reste lu tant que la mise à jour n'est pas installée
var sharePath: String {
    FileManager.default.fileExists(atPath: helperPath + "/share")
        ? helperPath + "/share" : root + "/usr/local/share/vpnrotate"
}
let logPath = root + "/var/log/vpnrotate.log"
let plistPath = root + "/Library/LaunchDaemons/local.vpnrotate.plist"
let statsPlistPath = root + "/Library/LaunchDaemons/local.vpnrotate.stats.plist"

struct Server: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var file: String { "\(id.uuidString).conf" }
}

struct Library: Codable, Equatable {
    var servers: [Server] = []
    var minutes = 30
    var random = false
    /// Bloque le trafic hors du tunnel (pare-feu pf)
    var killSwitch = true

    init() {}

    // Les réglages enregistrés avant l'ajout d'un champ restent lisibles
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 30
        random = try c.decodeIfPresent(Bool.self, forKey: .random) ?? false
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? true
    }
}

struct IPInfo: Decodable, Equatable {
    let ip: String
    let city: String?
    let country: String?
    let org: String?
    let loc: String?
}

/// Cumul enregistré par stats.sh pour un serveur
struct ServerStat: Identifiable, Equatable {
    let id: String
    var name: String
    var seconds: Double = 0
    var received: Int64 = 0
    var sent: Int64 = 0
    var bytes: Int64 { received + sent }
}

/// Une heure d'utilisation d'un serveur
struct HistoryEntry {
    let hour: Date
    let server: String
    let seconds: Double
    let received: Int64
    let sent: Int64
}

/// Identifiant des heures passées sans la rotation, à côté de ceux des serveurs
let offlineID = "offline"

struct Sample: Identifiable {
    let id: Int
    let down: Double
    let up: Double
}

/// Données du tunnel depuis la connexion au serveur en cours
struct Connection {
    let start: Date
    /// Octets reçus et envoyés au dernier relevé de WireGuard
    var recorded: (UInt64, UInt64)
    /// Mesuré sur la carte réseau depuis ce relevé
    var since: (UInt64, UInt64) = (0, 0)
    var received: UInt64 = 0
    var sent: UInt64 = 0

    mutating func update(recorded new: (UInt64, UInt64), traffic: (UInt64, UInt64)) {
        if new == recorded {
            since = (since.0 + traffic.0, since.1 + traffic.1)
        } else {
            recorded = new
            since = (0, 0)
        }
        // Un total affiché ne recule pas quand le relevé corrige l'estimation
        received = max(received, recorded.0 + since.0)
        sent = max(sent, recorded.1 + since.1)
    }
}

/// Compteurs d'octets d'une interface, ou de toutes les interfaces "en*"
func byteCounters(_ interface: String?) -> [String: (UInt32, UInt32)] {
    var result: [String: (UInt32, UInt32)] = [:]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return result }
    defer { freeifaddrs(list) }
    var current = list
    while let entry = current {
        defer { current = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_LINK),
              let data = entry.pointee.ifa_data else { continue }
        let name = String(cString: entry.pointee.ifa_name)
        if let interface { if name != interface { continue } }
        else if !name.hasPrefix("en") { continue }
        let stats = data.assumingMemoryBound(to: if_data.self).pointee
        result[name] = (stats.ifi_ibytes, stats.ifi_obytes)
    }
    return result
}

/// Octets passés entre deux lectures des compteurs
func traffic(from old: [String: (UInt32, UInt32)], to new: [String: (UInt32, UInt32)],
             seconds: TimeInterval) -> (UInt64, UInt64) {
    // Un écart impossible signale un compteur reparti de zéro
    let limit = min(Double(1 << 31), max(seconds, 1) * 1.5e9)
    var received: UInt64 = 0, sent: UInt64 = 0
    for (name, value) in new {
        guard let before = old[name] else { continue }
        // &- absorbe le retour à zéro des compteurs 32 bits
        let down = value.0 &- before.0, up = value.1 &- before.1
        if Double(down) < limit { received += UInt64(down) }
        if Double(up) < limit { sent += UInt64(up) }
    }
    return (received, sent)
}

/// Empreinte d'un fichier : évite de le relire tant qu'il n'a pas changé
private struct FileStamp: Equatable {
    var seconds = 0, nanoseconds = 0
    var size: off_t = 0
    var inode: ino_t = 0

    init(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
        inode = info.st_ino
    }
}

/// Ce qui change chaque seconde, à part : seule la carte de débit se redessine
@MainActor
final class Live: ObservableObject {
    private(set) var samples: [Sample] = []
    private(set) var connection: Connection?
    /// Fenêtre cachée : les mesures continuent, sans rien redessiner
    var visible = true {
        didSet { if visible, !oldValue { objectWillChange.send() } }
    }

    /// `oldest` : les relevés jusqu'à ce numéro sortent de la fenêtre affichée
    func record(_ sample: Sample?, oldest: Int, connection: Connection?) {
        if visible { objectWillChange.send() }
        if let sample { samples.append(sample) }
        samples.removeAll { $0.id <= oldest }
        self.connection = connection
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var library = Library() { didSet { if library != oldValue { save() } } }
    @Published var applied: Library?
    @Published var installed = false
    @Published var hasWireGuard = false
    @Published var currentID: String?
    @Published var interface: String?
    @Published var lastChange: Date?
    @Published var interval: TimeInterval = 1800
    @Published var activeNames: [String: String] = [:]
    @Published var log: [String] = []
    @Published var stats: [ServerStat] = []
    @Published var statsSince: Date?
    @Published var statsEnabled = false
    /// Les scripts installés ne sont plus ceux de l'application
    @Published var scriptsOutdated = false
    @Published var history: [HistoryEntry] = []
    /// Données passées hors VPN, relevées par l'application tant qu'elle est ouverte
    @Published private(set) var offline: [HistoryEntry] = []
    @Published var ip: IPInfo?
    @Published var ipError = false
    /// Serveur actif au moment où l'adresse affichée a été relevée (nil : hors VPN)
    @Published private(set) var ipServer: String?
    /// Dernière position relevée rotation arrêtée ("latitude,longitude"), pour la carte
    @Published private(set) var homeLocation = UserDefaults.standard.string(forKey: "homeLocation") {
        didSet { cachedCircuit = nil }
    }
    /// Position relevée pour chaque serveur (par nom), pour tracer le circuit
    @Published private(set) var serverLocations =
        UserDefaults.standard.dictionary(forKey: "serverLocations") as? [String: String] ?? [:] {
        didSet { cachedCircuit = nil }
    }
    @Published private(set) var circuit: [Visit] = [] { didSet { cachedCircuit = nil } }
    let live = Live()
    @Published var busy = false
    @Published var message: String?
    /// Notifications refusées dans les Réglages Système
    @Published var notificationsDenied = false

    let notifier = Notifier()
    /// Taille du journal déjà lue : seules les lignes suivantes déclenchent une notification
    private var logOffset: Int?
    /// Plus aucun serveur joignable, jusqu'à la prochaine connexion
    private var failed = false
    private var downSince: Date?
    private var downNotified = false

    private let folder: URL
    private var previous: (time: Date, interface: String?, bytes: [String: (UInt32, UInt32)])?
    private var tickCount = 0
    /// Empêche App Nap de ralentir la mesure quand la fenêtre est masquée
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var stamps: [String: FileStamp] = [:]
    private var scriptsMatch = false
    private var statsMatch = false
    /// Dernier contenu de stats.state
    private var savedState: [String] = []
    /// Relevés hors VPN pas encore ajoutés à `offline`
    private var pendingOffline: [HistoryEntry] = []
    private var cachedCircuit: Circuit?
    private var offlineFile: URL { folder.appendingPathComponent("offline.tsv") }
    /// Faux si le fichier existe mais n'a pas pu être lu : il ne faut pas l'écraser
    private var offlineWritable = false
    private var offlineChanged = false

    init() {
        if let custom = env["VPNROTATE_LIBRARY"] {
            folder = URL(fileURLWithPath: custom)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VPNRotation")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        library = read("library.json") ?? Library()
        applied = read("applied.json")
        loadOffline()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOffline() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.live.visible = NSApp.occlusionState.contains(.visible) }
        }
        refresh()
        startTicking()
        if notifier.alerts || notifier.changes { enableNotifications() }
    }

    /// Demande l'autorisation de macOS et note si elle est refusée
    func enableNotifications() {
        notifier.authorize { [weak self] denied in self?.assign(\.notificationsDenied, denied) }
    }

    /// Le circuit placé sur la carte, recalculé seulement quand ses données changent
    var circuitMap: Circuit {
        if let cachedCircuit { return cachedCircuit }
        let result = Circuit(visits: circuit, locations: serverLocations, home: homeLocation)
        cachedCircuit = result
        return result
    }

    var currentName: String? { currentID.map { activeNames[$0] ?? $0 } }
    var enabledCount: Int { library.servers.filter(\.enabled).count }
    var pending: Bool { installed && applied != library }

    // MARK: Bibliothèque

    private func read(_ name: String) -> Library? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }

    private func write(_ value: Library, to name: String) {
        do {
            try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            message = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    private func save() { write(library, to: "library.json") }

    func add(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "\t", with: " ")
            guard url.pathExtension.lowercased() == "conf",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("[Interface]"), text.contains("[Peer]"),
                  text.range(of: "(?im)^\\s*(pre|post)(up|down)\\s*=", options: .regularExpression) == nil
            else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let server = Server(name: name)
            let target = folder.appendingPathComponent(server.file)
            if FileManager.default.createFile(atPath: target.path, contents: Data(text.utf8),
                                              attributes: [.posixPermissions: 0o600]) {
                library.servers.append(server)
            } else {
                rejected.append(url.lastPathComponent)
            }
        }
        message = rejected.isEmpty ? nil : "Fichiers refusés : \(rejected.joined(separator: ", "))"
    }

    func remove(_ server: Server) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(server.file))
        library.servers.removeAll { $0.id == server.id }
    }

    // MARK: Actions administrateur

    func apply() {
        let selected = library.servers.filter(\.enabled)
        guard (2...99).contains(selected.count) else {
            message = "Sélectionnez entre 2 et 99 serveurs."
            return
        }
        let stage = folder.appendingPathComponent("stage")
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: stage)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var names = ""
            var ids = ""
            for (index, server) in selected.enumerated() {
                let id = String(format: "vpn%02d", index + 1)
                try fm.copyItem(at: folder.appendingPathComponent(server.file),
                                to: stage.appendingPathComponent("\(id).conf"))
                names += "\(id)\t\(server.name)\n"
                ids += "\(id)\t\(server.id.uuidString)\n"
            }
            try names.write(to: stage.appendingPathComponent("names.tsv"), atomically: true, encoding: .utf8)
            try ids.write(to: stage.appendingPathComponent("ids.tsv"), atomically: true, encoding: .utf8)
        } catch {
            message = "Préparation impossible : \(error.localizedDescription)"
            return
        }
        let snapshot = library
        run(["apply", stage.path, String(snapshot.minutes * 60), snapshot.random ? "random" : "sequential",
             snapshot.killSwitch ? "on" : "off"]) {
            self.applied = snapshot
            self.write(snapshot, to: "applied.json")
        } always: {
            try? fm.removeItem(at: stage)
        }
    }

    func changeNow(_ id: String? = nil) {
        // Après une mise à jour, la rotation doit d'abord être réappliquée
        if scriptsOutdated { apply() } else { run(["now"] + (id.map { [$0] } ?? [])) }
    }
    func stop() { run(["stop"]) }

    func uninstall() {
        run(["uninstall"]) {
            self.applied = nil
            try? FileManager.default.removeItem(at: self.folder.appendingPathComponent("applied.json"))
        }
    }

    private static let scripts = ["control.sh", "rotate.sh", "net.sh", "stats.sh"]
    private static let tools = ["bash", "wg", "wg-quick", "wireguard-go"]

    /// Vrai si le fichier installé est identique à celui de l'application
    private func upToDate(_ installedName: String, _ bundledName: String) -> Bool {
        guard let resources = Bundle.main.resourcePath else { return false }
        return FileManager.default.contentsEqual(atPath: helperPath + "/" + installedName,
                                                 andPath: resources + "/" + bundledName)
    }

    /// Première utilisation sur ce compte, ou application mise à jour
    private var needsInstall: Bool {
        !FileManager.default.fileExists(atPath: root + "/etc/sudoers.d/vpnrotate-\(getuid())")
            || !Self.scripts.allSatisfy { upToDate($0, $0) }
            || !Self.tools.allSatisfy { upToDate("bin/" + $0, "wireguard/bin/" + $0) }
    }

    /// Lance une commande ; renvoie son message d'erreur, ou nil si elle a réussi
    private func execute(_ path: String, _ arguments: [String]) async -> String? {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        // Lecture jusqu'à la fin, hors du fil principal
        let data = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("-128") ? "Action annulée." : String(text.suffix(300))
    }

    /// Seule étape qui demande le mot de passe administrateur
    private func install() async -> String? {
        guard let script = Bundle.main.path(forResource: "install", ofType: "sh") else {
            return "Programme d'installation introuvable."
        }
        // Les arguments sont échappés par AppleScript ("quoted form")
        return await execute("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "set cmd to \"/bin/bash -p\"",
            "-e", "repeat with a in argv",
            "-e", "set cmd to cmd & \" \" & quoted form of (a as text)",
            "-e", "end repeat",
            "-e", "do shell script cmd with prompt \"Installation de VPN Rotate. Le mot de passe ne sera plus demandé pour ses actions.\" with administrator privileges",
            "-e", "end run",
            script, String(getuid())
        ])
    }

    private func run(_ arguments: [String], success: @escaping () -> Void = {},
                     always: @escaping () -> Void = {}) {
        busy = true
        message = nil
        Task {
            var failure: String?
            if needsInstall { failure = await install() }
            if failure == nil {
                // -n : échoue au lieu d'attendre un mot de passe
                failure = await execute("/usr/bin/sudo", ["-n", helperPath + "/control.sh"] + arguments)
            }
            if let failure {
                message = failure
            } else {
                success()
                try? await Task.sleep(for: .seconds(5))
                refresh()
                await fetchIP()
            }
            always()
            refresh()
            busy = false
        }
    }

    // MARK: État en direct

    /// Publie une valeur seulement si elle change : sinon toute l'interface se redessinerait
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Model, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Vrai au premier appel, puis quand le fichier a changé
    private func changed(_ path: String) -> Bool {
        let stamp = FileStamp(path)
        guard stamps[path] != stamp else { return false }
        stamps[path] = stamp
        return true
    }

    private func contents(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func refresh() {
        let fm = FileManager.default
        let share = sharePath
        assign(\.installed, fm.fileExists(atPath: plistPath))
        assign(\.hasWireGuard, Bundle.main.resourcePath
            .map { fm.isExecutableFile(atPath: $0 + "/wireguard/bin/wg-quick") } == true)

        let intervalPath = share + "/interval"
        if changed(intervalPath) {
            assign(\.interval, TimeInterval(contents(intervalPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1800)
        }

        let namesPath = share + "/names.tsv"
        if changed(namesPath) {
            var names: [String: String] = [:]
            for line in contents(namesPath).split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2 { names[String(parts[0])] = String(parts[1]) }
            }
            assign(\.activeNames, names)
        }

        let status = contents(share + "/status").trimmingCharacters(in: .newlines)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        var id: String?, iface: String?, date: Date?
        if status.count == 3, let epoch = TimeInterval(status[2]) {
            id = status[0]
            iface = status[1].isEmpty ? nil : status[1]
            date = Date(timeIntervalSince1970: epoch)
            // Après un redémarrage, le fichier d'état peut rester alors que le tunnel n'existe plus
            if let name = iface, byteCounters(name).isEmpty { id = nil; iface = nil; date = nil }
        }
        assign(\.currentID, id)
        assign(\.interface, iface)
        assign(\.lastChange, date)

        // Les scripts installés ne sont comparés à nouveau que si l'un d'eux a changé
        if Self.scripts.map({ changed(helperPath + "/" + $0) }).contains(true) {
            scriptsMatch = Self.scripts.allSatisfy { upToDate($0, $0) }
            statsMatch = upToDate("stats.sh", "stats.sh")
        }
        // Vrai seulement si la version installée du relevé est celle de l'application
        assign(\.statsEnabled, fm.fileExists(atPath: statsPlistPath) && statsMatch)
        assign(\.scriptsOutdated, installed && !scriptsMatch)

        loadHistory(share + "/history.tsv")

        let sincePath = share + "/stats-since"
        if changed(sincePath) {
            assign(\.statsSince, TimeInterval(contents(sincePath).trimmingCharacters(in: .whitespacesAndNewlines))
                .map(Date.init(timeIntervalSince1970:)))
        }

        let statsPath = share + "/stats.tsv"
        if changed(statsPath) {
            assign(\.stats, contents(statsPath).split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 5, let seconds = Double(parts[2]),
                      let received = Int64(parts[3]), let sent = Int64(parts[4]) else { return nil }
                return ServerStat(id: parts[0], name: parts[1], seconds: seconds, received: received, sent: sent)
            })
        }

        if changed(logPath) {
            let journal = contents(logPath)
            assign(\.log, Array(journal.split(separator: "\n").suffix(500).map(String.init)))
            // Tout le journal : les messages de WireGuard repoussent vite les connexions au-delà de 500 lignes
            assign(\.circuit, visits(inLog: journal))
            scanLog(journal)
        }
        watchTunnel()
    }

    // MARK: Notifications

    /// Lit les lignes ajoutées au journal depuis la dernière fois. Au premier
    /// passage et après un raccourcissement du journal, rien n'est notifié.
    private func scanLog(_ journal: String) {
        let size = journal.utf8.count
        defer { logOffset = size }
        guard let start = logOffset, size > start else { return }
        let fresh = String(decoding: journal.utf8.dropFirst(start), as: UTF8.self)
        for raw in fresh.split(separator: "\n") {
            // Retire la date "AAAA-MM-JJ HH:MM:SS "
            let chars = Array(raw.prefix(20))
            let dated = chars.count == 20 && chars[4] == "-" && chars[10] == " " && chars[13] == ":"
            notify(forLogLine: dated ? String(raw.dropFirst(20)) : String(raw))
        }
    }

    private func notify(forLogLine line: String) {
        let alerts = notifier.alerts
        if line.hasPrefix("connecté : ") {
            let name = String(line.dropFirst("connecté : ".count))
            if failed || downNotified {
                if alerts { notifier.post("VPN rétabli", "Connecté à \(name).", id: "state") }
            } else if notifier.changes, !NSApp.isActive {
                notifier.post("Nouveau serveur", name, id: "state")
            }
            failed = false
            downNotified = false
            downSince = nil
        } else if line.hasPrefix("serveur injoignable : ") {
            let name = String(line.dropFirst("serveur injoignable : ".count))
            if alerts {
                notifier.post("Serveur injoignable", "\(name) ne répond pas : passage au serveur suivant.",
                              id: "unreachable-\(name)")
            }
        } else if line.hasPrefix("ÉCHEC : aucun serveur joignable") {
            failed = true
            if alerts {
                notifier.post("Aucun serveur joignable",
                              line.contains("trafic bloqué")
                                  ? "Internet est bloqué pour protéger votre adresse. Vérifiez votre connexion ou arrêtez la rotation."
                                  : "Le VPN est coupé : votre vraie adresse est visible.",
                              id: "state", sound: true)
            }
        } else if line.hasPrefix("ÉCHEC : ") {
            let detail = String(line.dropFirst("ÉCHEC : ".count))
            if alerts {
                notifier.post("Problème détecté", detail.prefix(1).uppercased() + detail.dropFirst(),
                              id: "failure-\(detail)", sound: true)
            }
        }
    }

    /// Tunnel tombé sans message dans le journal : signalé après une minute,
    /// plus long qu'un changement de serveur normal
    private func watchTunnel() {
        guard installed, !busy, !failed else { downSince = nil; return }
        if currentID != nil {
            if downNotified, notifier.alerts {
                notifier.post("VPN rétabli", "Connecté à \(currentName ?? "un serveur").", id: "state")
            }
            downSince = nil
            downNotified = false
            return
        }
        let now = Date()
        guard let since = downSince else { downSince = now; return }
        guard !downNotified, now.timeIntervalSince(since) > 60 else { return }
        downNotified = true
        guard notifier.alerts else { return }
        notifier.post("VPN coupé",
                      applied?.killSwitch ?? true
                          ? "Le tunnel est tombé. Internet reste bloqué jusqu'au prochain serveur."
                          : "Le tunnel est tombé : votre vraie adresse est visible jusqu'au prochain serveur.",
                      id: "state", sound: true)
    }

    private func loadHistory(_ path: String) {
        guard changed(path) else { return }
        history = contents(path).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 5, let hour = TimeInterval(parts[0]), let seconds = Double(parts[2]),
                  let received = Int64(parts[3]), let sent = Int64(parts[4]) else { return nil }
            return HistoryEntry(hour: Date(timeIntervalSince1970: hour), server: String(parts[1]),
                                seconds: seconds, received: received, sent: sent)
        }
    }

    /// La mesure ne dépend pas de la fenêtre : elle continue derrière un navigateur
    private func startTicking() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Mesure du débit en direct")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Laisse macOS regrouper les réveils du processeur
        timer.tolerance = 0.2
        // .common : continue aussi pendant l'ouverture d'un menu ou un défilement
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Appelé chaque seconde
    private func tick() {
        tickCount += 1
        if tickCount % 3 == 0 {
            let before = lastChange
            refresh()
            if before != lastChange { Task { await fetchIP() } }
        }
        if tickCount % 60 == 0 { Task { await fetchIP() } }

        let now = Date()
        // Toujours les cartes réseau : macOS compte presque en double ce qui est reçu sur utun
        let bytes = byteCounters(nil)
        var moved: (UInt64, UInt64) = (0, 0)
        var sample: Sample?
        if let previous, previous.interface == interface {
            let seconds = now.timeIntervalSince(previous.time)
            moved = traffic(from: previous.bytes, to: bytes, seconds: seconds)
            if interface == nil, !bytes.isEmpty { recordOffline(moved, seconds: seconds, at: now) }
            if seconds > 0 {
                sample = Sample(id: tickCount, down: Double(moved.0) / seconds, up: Double(moved.1) / seconds)
            }
        }
        previous = (now, interface, bytes)
        // Seuls les points des 60 secondes affichées sont gardés, même s'il en manque
        live.record(sample, oldest: tickCount - 60, connection: trackConnection(moved))
        if tickCount % 30 == 0 { saveOffline() }
    }

    // MARK: Hors VPN

    /// Ajoute à l'heure en cours ce qui est passé par les interfaces réseau depuis le dernier relevé
    private func recordOffline(_ moved: (UInt64, UInt64), seconds: TimeInterval, at now: Date) {
        guard seconds > 0 else { return }
        // Après une veille du Mac, le temps endormi n'est pas compté
        let time = seconds < 10 ? seconds : 1
        let epoch = now.timeIntervalSince1970
        let hour = Date(timeIntervalSince1970: epoch - epoch.truncatingRemainder(dividingBy: 3600))
        Self.merge(HistoryEntry(hour: hour, server: offlineID, seconds: time,
                                received: Int64(clamping: moved.0), sent: Int64(clamping: moved.1)),
                   into: &pendingOffline)
    }

    private static func merge(_ new: HistoryEntry, into list: inout [HistoryEntry]) {
        if let index = list.lastIndex(where: { $0.hour == new.hour }) {
            let entry = list[index]
            list[index] = HistoryEntry(hour: new.hour, server: offlineID, seconds: entry.seconds + new.seconds,
                                       received: entry.received + new.received, sent: entry.sent + new.sent)
        } else {
            list.append(new)
        }
    }

    /// Ajoute les relevés en attente aux statistiques affichées
    func flushOffline() {
        guard !pendingOffline.isEmpty else { return }
        var merged = offline
        for entry in pendingOffline { Self.merge(entry, into: &merged) }
        pendingOffline = []
        offline = merged
        offlineChanged = true
    }

    ///   offline.tsv : heure (epoch), secondes, octets reçus, octets envoyés
    private func loadOffline() {
        guard FileManager.default.fileExists(atPath: offlineFile.path) else {
            offlineWritable = true
            return
        }
        guard let text = try? String(contentsOf: offlineFile, encoding: .utf8) else { return }
        offlineWritable = true
        offline = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 4, let hour = TimeInterval(parts[0]), let seconds = Double(parts[1]),
                  let received = Int64(parts[2]), let sent = Int64(parts[3]) else { return nil }
            return HistoryEntry(hour: Date(timeIntervalSince1970: hour), server: offlineID,
                                seconds: seconds, received: received, sent: sent)
        }
    }

    private func saveOffline() {
        flushOffline()
        guard offlineWritable, offlineChanged else { return }
        let text = offline.map {
            "\(Int($0.hour.timeIntervalSince1970))\t\($0.seconds)\t\($0.received)\t\($0.sent)\n"
        }.joined()
        if (try? Data(text.utf8).write(to: offlineFile, options: .atomic)) != nil { offlineChanged = false }
    }

    /// Le relevé de la minute donne le chiffre exact ; la carte réseau complète entre deux
    private func trackConnection(_ moved: (UInt64, UInt64)) -> Connection? {
        guard interface != nil, let start = lastChange else { return nil }
        let saved = savedCounters(start: start)
        let known = live.connection?.start == start ? live.connection : nil
        var current = known ?? Connection(start: start, recorded: saved)
        // La première seconde d'une connexion peut dater d'avant elle
        current.update(recorded: saved, traffic: known == nil ? (0, 0) : moved)
        return current
    }

    /// Octets de la connexion en cours au dernier relevé des statistiques
    private func savedCounters(start: Date) -> (UInt64, UInt64) {
        let path = sharePath + "/stats.state"
        if changed(path) { savedState = contents(path).split(whereSeparator: \.isWhitespace).map(String.init) }
        let parts = savedState
        guard let currentID, parts.count == 4, parts[0] == "\(currentID)-\(Int(start.timeIntervalSince1970))",
              let received = UInt64(parts[2]), let sent = UInt64(parts[3]) else { return (0, 0) }
        return (received, sent)
    }

    func fetchIP() async {
        var request = URLRequest(url: URL(string: "https://ipinfo.io/json")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        // Session neuve : pas de connexion réutilisée d'avant le changement
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let server = currentID, change = lastChange, wasInstalled = installed
        do {
            let (data, _) = try await session.data(for: request)
            let info = try JSONDecoder().decode(IPInfo.self, from: data)
            // Réponse obtenue pendant un changement : on ne sait pas par où elle est passée
            guard server == currentID, change == lastChange else { return }
            assign(\.ip, info)
            assign(\.ipServer, server)
            assign(\.ipError, false)
            if let server, let name = activeNames[server], let location = info.loc, serverLocations[name] != location {
                serverLocations[name] = location
                UserDefaults.standard.set(serverLocations, forKey: "serverLocations")
            }
            if !wasInstalled, !installed, !busy, server == nil, let location = info.loc {
                homeLocation = location
                UserDefaults.standard.set(location, forKey: "homeLocation")
            }
        } catch {
            guard server == currentID, change == lastChange else { return }
            assign(\.ip, nil)
            assign(\.ipError, true)
        }
    }
}
