import SwiftUI
import CoreLocation
import Charts
import Combine
import UniformTypeIdentifiers

/// Remplace @State, dont la macro n'est pas fournie sans Xcode complet
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Outils d'affichage

/// Créée une seule fois : l'affichage la demande chaque seconde
let french = Locale(identifier: "fr_FR")

func speedParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
    let bits = bytesPerSecond * 8
    if bits >= 1_000_000 { return (String(format: "%.1f", locale: french, bits / 1_000_000), "Mbit/s") }
    return (String(format: "%.0f", locale: french, bits / 1_000), "kbit/s")
}

/// Pays de sortie d'un serveur d'après son nom ("wg-FR-12", "US-FL#10"…)
func countryCode(in name: String) -> String? { route(in: name).exit }

func flag(_ code: String) -> String {
    String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
}

func countryName(_ code: String) -> String {
    french.localizedString(forRegionCode: code) ?? code
}

struct FlagBadge: View {
    let name: String?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let code = name.flatMap(countryCode) {
                Text(flag(code)).font(.system(size: size * 0.55))
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Carte flottante posée sur la carte du monde
    func floatingCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

// MARK: - État du VPN

/// Une couleur et un symbole par état, les mêmes partout dans l'application
enum VPNState {
    case connected, noTunnel, off

    var color: Color {
        switch self {
        case .connected: .green
        case .noTunnel: .red
        case .off: .orange
        }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.shield.fill"
        case .noTunnel: "exclamationmark.shield.fill"
        case .off: "shield.slash.fill"
        }
    }

    var title: String {
        switch self {
        case .connected: "Connecté"
        case .noTunnel: "Aucun tunnel actif"
        case .off: "Rotation arrêtée"
        }
    }
}

/// Pastille ronde : symbole blanc sur la couleur de l'état
struct StatusIcon: View {
    let state: VPNState
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background(state.color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// État résumé de la rotation, partagé par la barre latérale et l'accueil
extension Model {
    var state: VPNState { currentID != nil ? .connected : installed ? .noTunnel : .off }
    var canApply: Bool { !busy && hasWireGuard && enabledCount >= 2 && (!installed || pending) }
}

// MARK: - Carte

extension CLLocationCoordinate2D {
    /// "latitude,longitude", comme le renvoie le service d'adresse IP
    init?(_ text: String?) {
        let parts = text?.split(separator: ",").compactMap { Double($0) } ?? []
        guard parts.count == 2 else { return nil }
        self.init(latitude: parts[0], longitude: parts[1])
        guard CLLocationCoordinate2DIsValid(self) else { return nil }
    }
}

/// Repère de la position actuelle, avec une onde quand le VPN protège
struct MapPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: VPNState
    let locating: Bool
    let title: String
    let detail: String

    private var color: Color { locating ? .gray : state.color }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            VStack(spacing: -3) {
                Image(systemName: locating ? "ellipsis" : state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 42, height: 42)
                    .background(color.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .background { halo }
                    .zIndex(1)
                PinTip().fill(.white).frame(width: 14, height: 10)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail), \(state.title)")
    }

    @ViewBuilder private var halo: some View {
        Circle().fill(color.opacity(0.25)).scaleEffect(1.5)
        if state == .connected && !locating && !reduceMotion {
            // Rejouée à chaque nouveau serveur
            Pulse(color: color).id(title)
        }
    }
}

/// Trois ondes puis plus rien : une animation sans fin redessinerait la carte en permanence
private struct Pulse: View {
    let color: Color
    @StateObject private var expanded = Box(false)

    var body: some View {
        Circle().fill(color)
            .scaleEffect(expanded.value ? 2.2 : 1)
            .opacity(expanded.value ? 0 : 0.45)
            .onAppear {
                withAnimation(.easeOut(duration: 2.2).repeatCount(3, autoreverses: false)) { expanded.value = true }
            }
    }
}

struct PinTip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Point de départ de la liaison avec le serveur
struct HomeDot: View {
    var body: some View {
        Image(systemName: "house.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.gray.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .help("Votre position, relevée la dernière fois rotation arrêtée")
            .accessibilityLabel("Votre position")
    }
}

// MARK: - Accueil

struct DashboardView: View {
    @EnvironmentObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var map = WorldMapController()
    @StateObject private var selection = Box<Int?>(nil)
    @AppStorage("showCircuit") private var showCircuit = false
    let showServers: () -> Void

    private var coordinate: CLLocationCoordinate2D? { CLLocationCoordinate2D(model.ip?.loc) }

    /// Faux le temps que l'adresse du nouveau serveur soit relevée
    private var located: Bool { model.ipServer == model.currentID }

    /// Position hors VPN, montrée seulement quand le serveur est ailleurs
    private var home: CLLocationCoordinate2D? {
        guard model.state == .connected, located, let coordinate,
              let home = CLLocationCoordinate2D(model.homeLocation),
              CLLocation(latitude: home.latitude, longitude: home.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) > 50_000
        else { return nil }
        return home
    }

    private var circuit: Circuit { model.circuitMap }

    /// Serveur du passage choisi, sinon celui qui est connecté
    private var highlighted: String? {
        selection.value.flatMap { id in model.circuit.first { $0.id == id }?.name } ?? model.currentName
    }

    /// Pays de sortie du serveur connecté : celui de l'adresse relevée, sinon celui du nom
    private var connectedCountry: String? {
        guard model.state == .connected else { return nil }
        let named = model.currentName.flatMap(countryCode)
        return (located ? model.ip?.country?.uppercased() : nil) ?? named
    }

    var body: some View {
        let circuit = circuit
        let circuitMap = CircuitMap(circuit: circuit, highlighted: highlighted, current: model.currentName) { place in
            // Plusieurs clics sur un même repère font défiler ses passages
            let numbers = place.numbers
            let next = selection.value.flatMap { numbers.firstIndex(of: $0) }.map { $0 - 1 }
            selection.value = numbers[next.map { $0 < 0 ? numbers.count - 1 : $0 } ?? numbers.count - 1]
        }
        let home = home, coordinate = coordinate
        let link = home.flatMap { home in coordinate.map { [home, $0] } }
        let lines = showCircuit ? circuitMap.lines
            : link.map { [MapLine(id: "home", points: $0, color: VPNState.connected.color, width: 3, dash: [2, 8])] } ?? []
        return WorldMap(controller: map, highlight: connectedCountry, lines: lines) { project in
            if showCircuit {
                circuitMap.markers(project)
            } else {
                if let home { HomeDot().mapMarker(at: home, project) }
                if let coordinate {
                    MapPin(state: model.state, locating: !located, title: pinTitle, detail: pinDetail)
                        .mapMarker(at: coordinate, project, bottom: true)
                }
            }
        }
        // Carte sombre et sobre, où le pays surligné ressort ; les cartes posées
        // dessus gardent l'apparence du système
        .environment(\.colorScheme, .dark)
        // Les cartes réservent leur place : le repère reste centré dans la zone libre
        .safeAreaInset(edge: .top, spacing: 0) { statusCard.padding(14) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Picker("Vue de la carte", selection: $showCircuit) {
                        Label("Position", systemImage: "mappin.and.ellipse").tag(false)
                        Label("Circuit", systemImage: "point.topleft.down.to.point.bottomright.curvepath").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    Spacer()
                    if showCircuit || coordinate != nil { recenterButton }
                }
                if showCircuit {
                    CircuitCard(circuit: circuit, running: model.installed, current: model.currentName,
                                selection: $selection.value)
                } else {
                    TrafficCard(live: model.live)
                }
            }
            .padding(14)
        }
        .onChange(of: cameraKey, initial: true) {
            // Pas de mouvement tant que la nouvelle position n'est pas connue
            if showCircuit || located { recenter() }
        }
        // Une nouvelle rotation renumérote les passages
        .onChange(of: model.circuit.first?.start) { selection.value = nil }
    }

    // MARK: Carte

    private var pinTitle: String {
        let code = model.ip?.country ?? ""
        let city = model.ip?.city ?? "Position"
        return code.count == 2 ? "\(flag(code)) \(city)" : city
    }

    private var pinDetail: String {
        if !located { return "Localisation…" }
        return model.state == .connected ? "Serveur VPN" : "Vous · sans VPN"
    }

    /// Change quand la vue doit être recadrée
    private var cameraKey: String {
        if showCircuit {
            let places = circuit.stops.map { "\($0.name)@\($0.coordinate.latitude),\($0.coordinate.longitude)" }
            return "circuit|\(selection.value ?? 0)|\(model.homeLocation ?? "")|" + places.joined(separator: "|")
        }
        guard located, let loc = model.ip?.loc else { return "" }
        return loc + (home == nil ? "" : "|" + (model.homeLocation ?? ""))
    }

    private func recenter() {
        let chosen = selection.value.flatMap { id in model.circuit.first { $0.id == id }?.name }
        let target = showCircuit ? circuit.region(highlighting: chosen)
            : coordinate.map { MapRegion(showing: $0, and: home) }
        guard let target else { return }
        map.show(target, animated: !reduceMotion)
    }

    private var recenterButton: some View {
        Button(action: recenter) {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Recentrer la carte")
        .accessibilityLabel("Recentrer la carte")
    }

    // MARK: État

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                FlagBadge(name: model.currentName ?? model.ip?.country, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        StatusIcon(state: model.state, size: 24)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                            .offset(x: 5, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.title.uppercased())
                        .font(.caption.weight(.semibold)).tracking(0.6)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(model.state.color.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(model.state.color.opacity(0.5)))
                    Text(model.currentName ?? place ?? "Position inconnue")
                        .font(.title.weight(.bold)).lineLimit(1)
                    addressLine
                }
                Spacer(minLength: 8)
                if model.installed, let last = model.lastChange { Countdown(live: model.live, since: last, interval: model.interval) }
            }
            actions
        }
        .floatingCard()
    }

    private var place: String? {
        guard let ip = model.ip else { return nil }
        let parts = [ip.city, ip.country.map(countryName)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder private var addressLine: some View {
        if let ip = model.ip {
            let details = [model.currentName == nil ? nil : place, ip.org].compactMap { $0 }
            HStack(spacing: 6) {
                Text(ip.ip).monospacedDigit().textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip.ip, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copier l'adresse IP")
                    .accessibilityLabel("Copier l'adresse IP")
                if !details.isEmpty { Text("·  " + details.joined(separator: "  ·  ")).lineLimit(1) }
            }
            .font(.callout).foregroundStyle(.secondary)
        } else {
            Text(model.ipError ? "Adresse IP indisponible" : "Recherche de l'adresse IP…")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            if model.installed {
                Button { model.changeNow() } label: { Label("Serveur suivant", systemImage: "forward.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r")
                    .help("Changer de serveur maintenant (⌘R)")
                if !model.pending && !model.activeNames.isEmpty {
                    Menu {
                        ForEach(model.activeNames.keys.sorted(), id: \.self) { id in
                            Button { model.changeNow(id) } label: {
                                let name = model.activeNames[id] ?? id
                                Text([countryCode(in: name).map(flag), name].compactMap { $0 }.joined(separator: " "))
                            }
                            .disabled(id == model.currentID)
                        }
                    } label: { Label("Choisir un serveur", systemImage: "list.bullet") }
                        .fixedSize()
                }
                Spacer()
                Button(role: .destructive) { model.stop() } label: { Label("Arrêter", systemImage: "stop.fill") }
                    .help("Arrêter la rotation et couper le VPN")
            } else if model.enabledCount >= 2 {
                Button { model.apply() } label: { Label("Démarrer la rotation", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApply)
                Text("\(model.enabledCount) serveurs · toutes les \(model.library.minutes) min. Quittez d'abord toute autre application VPN.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Button(action: showServers) { Label("Ajouter des serveurs", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Text("Cochez au moins 2 serveurs pour démarrer la rotation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
        .disabled(model.busy)
    }
}

/// Redessiné par le même signal que les débits : une seule mise en page par seconde
struct Countdown: View {
    @ObservedObject var live: Live
    let since: Date
    let interval: TimeInterval

    var body: some View {
        let left = max(0, since.addingTimeInterval(interval).timeIntervalSinceNow)
        let seconds = Int(left)
        return ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 6)
            Circle().trim(from: 0, to: min(1, left / max(1, interval)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(seconds >= 3600
                     ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                     : String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: seconds >= 3600 ? 14 : 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("restant").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prochain changement dans \(seconds / 60) minutes et \(seconds % 60) secondes")
        .help("Temps avant le prochain changement de serveur")
    }
}

// MARK: - Débits

/// Seule partie qui se redessine chaque seconde : la carte du monde n'est pas touchée
struct TrafficCard: View {
    @EnvironmentObject var model: Model
    @ObservedObject var live: Live

    var body: some View {
        let last = live.samples.last
        let end = last?.id ?? 60
        return VStack(alignment: .leading, spacing: 10) {
            // Fenêtre étroite : les données de la connexion passent sous le débit
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    rates(last)
                    if let connection = live.connection {
                        Divider().frame(height: 44)
                        connectionTotals(connection)
                    }
                    Spacer()
                    tunnelLabel
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 24) {
                        rates(last)
                        Spacer()
                        tunnelLabel
                    }
                    if let connection = live.connection { connectionTotals(connection) }
                }
            }
            Chart {
                ForEach(live.samples) { sample in
                    AreaMark(x: .value("t", sample.id), y: .value("Mbit/s", sample.down * 8 / 1_000_000))
                        .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                ForEach(live.samples) { sample in
                    LineMark(x: .value("t", sample.id), y: .value("Mbit/s", sample.down * 8 / 1_000_000),
                             series: .value("Sens", "Réception"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", sample.id), y: .value("Mbit/s", sample.up * 8 / 1_000_000),
                             series: .value("Sens", "Envoi"))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: (end - 59) ... end)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 80)
            .accessibilityLabel("Débit des 60 dernières secondes, en mégabits par seconde")
            Text("60 dernières secondes · Mbit/s").font(.caption2).foregroundStyle(.secondary)
        }
        .floatingCard()
    }

    private func rates(_ last: Sample?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            rate("Réception", "arrow.down", .blue, last?.down ?? 0)
            rate("Envoi", "arrow.up", .orange, last?.up ?? 0)
        }
    }

    private var tunnelLabel: some View {
        Label {
            Text(model.interface.map { "Tunnel \($0)" } ?? "Hors tunnel").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: model.interface == nil ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(model.interface == nil ? VPNState.off.color : VPNState.connected.color)
        }
            .font(.caption).lineLimit(1)
            .help(model.interface == nil ? "Débit du réseau local"
                  : "Débit mesuré sur la carte réseau, chiffrement du VPN compris")
    }

    /// Remis à zéro à chaque connexion à un serveur
    private func connectionTotals(_ connection: Connection) -> some View {
        let received = Int64(clamping: connection.received)
        let sent = Int64(clamping: connection.sent)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Depuis la connexion · \(duration(max(0, Date().timeIntervalSince(connection.start))))")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                amount("Réception", "arrow.down", .blue, received)
                amount("Envoi", "arrow.up", .orange, sent)
                amount("Total", "sum", .secondary, received + sent)
            }
        }
        .lineLimit(1)
        .help("Données utilisées depuis la connexion à \(model.currentName ?? "ce serveur")")
    }

    private func amount(_ title: String, _ symbol: String, _ color: Color, _ bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(dataSize(bytes)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(dataSize(bytes))")
    }

    private func rate(_ title: String, _ symbol: String, _ color: Color, _ value: Double) -> some View {
        let parts = speedParts(value)
        return VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(parts.unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Serveurs

struct ServersView: View {
    @EnvironmentObject var model: Model
    @StateObject private var dropping = Box(false)
    @StateObject private var removal = Box<Server?>(nil)
    let add: () -> Void

    var body: some View {
        Group {
            if model.library.servers.isEmpty {
                ContentUnavailableView {
                    Label("Aucun serveur", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Glissez vos fichiers WireGuard .conf ici, ou choisissez-les.")
                } actions: {
                    Button("Ajouter des fichiers .conf", action: add).buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropping.value {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay {
                        Label("Déposez pour ajouter", systemImage: "plus.circle.fill")
                            .font(.title2.weight(.semibold))
                            .padding(16).background(.regularMaterial, in: Capsule())
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropping.value = $0 }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Tout cocher") { setAll(true) }
                    Button("Tout décocher") { setAll(false) }
                    Divider()
                } label: { Label("Options", systemImage: "ellipsis.circle") }
                Button(action: add) { Label("Ajouter", systemImage: "plus") }
                    .help("Ajouter des fichiers .conf (⌘O)")
            }
        }
        .confirmationDialog("Retirer « \(removal.value?.name ?? "") » ?",
                            isPresented: Binding(get: { removal.value != nil },
                                                 set: { if !$0 { removal.value = nil } }),
                            presenting: removal.value) { server in
            Button("Retirer", role: .destructive) { model.remove(server) }
        } message: { _ in
            Text("La copie du fichier .conf gardée par l'application sera supprimée. Votre fichier d'origine n'est pas touché.")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach($model.library.servers) { $server in
                    row($server)
                }
                .onMove { model.library.servers.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("\(model.enabledCount) sur \(model.library.servers.count) dans la rotation")
            } footer: {
                Text(model.pending
                     ? "Appliquez les changements pour pouvoir choisir un serveur."
                     : "Glissez les lignes pour changer l'ordre. Cliquez sur un nom pour le renommer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ binding: Binding<Server>) -> some View {
        let server = binding.wrappedValue
        let id = activeID(server)
        let connected = id != nil && id == model.currentID
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            FlagBadge(name: server.name).opacity(server.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nom", text: binding.name)
                    .textFieldStyle(.plain).font(.body.weight(.medium))
                    .foregroundStyle(server.enabled ? .primary : .secondary)
                Text(subtitle(server)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                Label("Connecté", systemImage: VPNState.connected.symbol)
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            } else if let id {
                Button("Se connecter") { model.changeNow(id) }.disabled(model.busy)
            }
            Toggle("Dans la rotation", isOn: binding.enabled)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(server.enabled ? "Retirer de la rotation" : "Ajouter à la rotation")
            Button { removal.value = server } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Retirer de l'application")
                .accessibilityLabel("Retirer \(server.name)")
        }
        .padding(.vertical, 6)
        .contextMenu {
            if let id, !connected { Button("Se connecter") { model.changeNow(id) }.disabled(model.busy) }
            Button(server.enabled ? "Retirer de la rotation" : "Ajouter à la rotation") {
                binding.wrappedValue.enabled.toggle()
            }
            Divider()
            Button("Retirer de l'application…", role: .destructive) { removal.value = server }
        }
    }

    private func subtitle(_ server: Server) -> String {
        let country = countryCode(in: server.name).map(countryName)
        let position = model.library.servers.filter(\.enabled).firstIndex { $0.id == server.id }
        let state: String
        if let position { state = model.library.random ? "Dans la rotation" : "N° \(position + 1) dans la rotation" }
        else { state = "Hors rotation" }
        return [country, state].compactMap { $0 }.joined(separator: " · ")
    }

    private func setAll(_ value: Bool) {
        for index in model.library.servers.indices { model.library.servers[index].enabled = value }
    }

    /// Identifiant installé du serveur, seulement si la rotation correspond à la liste affichée
    private func activeID(_ server: Server) -> String? {
        guard model.installed, !model.pending,
              let index = model.library.servers.filter(\.enabled).firstIndex(where: { $0.id == server.id })
        else { return nil }
        return String(format: "vpn%02d", index + 1)
    }
}

// MARK: - Réglages

/// Léger enfoncement dès l'appui
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Pastille d'icône colorée, comme dans les Réglages de macOS
struct IconBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsCard<Content: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

/// Case à choisir : bordure et fond colorés quand elle est active
struct ChoiceTile<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsPage: View {
    @EnvironmentObject var model: Model
    @StateObject private var confirmUninstall = Box(false)
    private let presets = [5, 10, 15, 30, 60, 120]

    private var minutes: Binding<Int> {
        Binding(get: { model.library.minutes },
                set: { model.library.minutes = min(1440, max(1, $0)) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                frequency
                order
                wireGuard
                uninstall
            }
            .frame(maxWidth: 680)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Désinstaller le service de rotation ?", isPresented: $confirmUninstall.value) {
            Button("Désinstaller", role: .destructive) { model.uninstall() }
        } message: {
            Text("Le VPN sera coupé.")
        }
    }

    private var frequency: some View {
        let perDay = max(1, 1440 / model.library.minutes)
        return SettingsCard(symbol: "timer", color: .blue, title: "Fréquence de rotation",
                            subtitle: "Environ \(perDay) changement\(perDay > 1 ? "s" : "") par jour, avec une brève coupure à chaque fois.") {
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { value in
                    ChoiceTile(selected: model.library.minutes == value) {
                        minutes.wrappedValue = value
                    } content: {
                        VStack(spacing: 0) {
                            Text("\(value < 60 ? value : value / 60)")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                            Text(value < 60 ? "min" : value == 60 ? "heure" : "heures")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
                    .accessibilityLabel(value < 60 ? "\(value) minutes" : "\(value / 60) heures")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Text("Durée personnalisée")
                Spacer()
                TextField("Minutes", value: minutes, format: .number)
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .multilineTextAlignment(.trailing).frame(width: 70)
                Text("min").foregroundStyle(.secondary)
                Stepper("Minutes", value: minutes, in: 1...1440).labelsHidden()
            }
        }
    }

    private var order: some View {
        SettingsCard(symbol: "arrow.triangle.swap", color: .purple, title: "Ordre des serveurs",
                     subtitle: "Comment le serveur suivant est choisi.") {
            HStack(spacing: 10) {
                orderTile(false, "list.number", "Dans l'ordre", "Suit votre liste de serveurs, de haut en bas.")
                orderTile(true, "shuffle", "Aléatoire", "Un autre serveur, tiré au hasard à chaque fois.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func orderTile(_ random: Bool, _ symbol: String, _ title: String, _ detail: String) -> some View {
        let selected = model.library.random == random
        return ChoiceTile(selected: selected) {
            model.library.random = random
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary.opacity(0.5))
                }
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var wireGuard: some View {
        SettingsCard(symbol: "lock.shield.fill", color: model.hasWireGuard ? .green : .orange,
                     title: "WireGuard",
                     subtitle: model.hasWireGuard ? "Inclus dans l'application, rien d'autre à installer."
                         : "Absent de cette copie de l'application.") {
            EmptyView()
        }
    }

    private var uninstall: some View {
        SettingsCard(symbol: "trash.fill", color: .red, title: "Désinstaller le service",
                     subtitle: "Supprime le service, l'autorisation sans mot de passe, la copie des serveurs et le journal. Vos serveurs ajoutés et vos statistiques sont conservés.") {
            HStack {
                Spacer()
                Button("Désinstaller…", role: .destructive) { confirmUninstall.value = true }
                    .controlSize(.large)
                    .disabled(model.busy)
            }
        }
    }
}

// MARK: - Journal

struct LogEntry {
    let line: String
    let date: String?
    let time: String
    let message: String

    init(_ line: String) {
        self.line = line
        if Self.isDated(line) {
            date = String(line.prefix(10))
            time = String(line.dropFirst(11).prefix(8))
            message = String(line.dropFirst(20))
        } else {
            date = nil
            time = ""
            message = line
        }
    }

    /// Vrai si la ligne commence par "AAAA-MM-JJ HH:MM:SS " (sans expression régulière, plus rapide)
    private static func isDated(_ line: String) -> Bool {
        let pattern = Array("0000-00-00 00:00:00 ".utf8)
        var count = 0
        for (byte, expected) in zip(line.utf8, pattern) {
            if expected == UInt8(ascii: "0") {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            } else if byte != expected {
                return false
            }
            count += 1
        }
        return count == pattern.count
    }

    var style: (symbol: String, color: Color) {
        if message.contains("ÉCHEC") || message.contains("injoignable") { return ("xmark.octagon.fill", .red) }
        if message.contains(" KO") { return ("exclamationmark.triangle.fill", .orange) }
        if message.hasPrefix("connecté") { return ("checkmark.circle.fill", .green) }
        if message.hasPrefix("rotation arrêtée") { return ("stop.circle.fill", .secondary) }
        return ("info.circle", .secondary)
    }

    private static let parser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// "2026-11-27" devient "27 novembre 2026"
    static func day(_ date: String) -> String {
        guard let value = parser.date(from: date) else { return date }
        return value.formatted(.dateTime.day().month(.wide).year().locale(french))
    }
}

/// Une ligne du journal, avec le titre du jour quand elle en commence un
private struct LogRow: Identifiable {
    let id: Int
    let entry: LogEntry
    let day: String?
}

struct LogPage: View {
    @EnvironmentObject var model: Model
    @StateObject private var search = Box("")
    @StateObject private var detailed = Box(false)

    private var entries: [LogEntry] {
        model.log.map(LogEntry.init).filter {
            (detailed.value || $0.date != nil) &&
            (search.value.isEmpty || $0.line.localizedCaseInsensitiveContains(search.value))
        }
    }

    private func rows(_ entries: [LogEntry]) -> [LogRow] {
        var previous: String?
        return entries.enumerated().map { index, entry in
            var day: String?
            if let date = entry.date {
                if date != previous { day = LogEntry.day(date) }
                previous = date
            }
            return LogRow(id: index, entry: entry, day: day)
        }
    }

    var body: some View {
        let shown = entries
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows(shown)) { row in
                    let entry = row.entry
                    if entry.date != nil {
                        if let day = row.day {
                            Text(day)
                                .font(.headline)
                                .padding(.top, row.id == 0 ? 0 : 14).padding(.bottom, 6)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.time).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: entry.style.symbol).foregroundStyle(entry.style.color).frame(width: 18)
                            Text(entry.message).textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text(entry.line)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if shown.isEmpty {
                if search.value.isEmpty {
                    ContentUnavailableView("Journal vide", systemImage: "doc.text",
                                           description: Text("Les connexions apparaîtront ici."))
                } else {
                    ContentUnavailableView("Aucun résultat", systemImage: "magnifyingglass",
                                           description: Text("Essayez un autre mot."))
                }
            }
        }
        .searchable(text: $search.value, prompt: "Rechercher")
        .toolbar {
            ToolbarItemGroup {
                Picker("Affichage", selection: $detailed.value) {
                    Text("Événements").tag(false)
                    Text("Tout").tag(true)
                }
                .pickerStyle(.segmented)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(\.line).joined(separator: "\n"), forType: .string)
                } label: { Label("Copier", systemImage: "doc.on.doc") }
                    .help("Copier les lignes affichées")
                    .disabled(shown.isEmpty)
            }
        }
    }
}

// MARK: - Fenêtre

enum Page: String, CaseIterable, Identifiable {
    case home = "Accueil", servers = "Serveurs", stats = "Statistiques", settings = "Réglages", log = "Journal"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .home: "globe.europe.africa.fill"
        case .servers: "server.rack"
        case .stats: "chart.bar.fill"
        case .settings: "gearshape"
        case .log: "list.bullet.rectangle"
        }
    }
}

struct SidebarStatus: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    StatusIcon(state: model.state)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.busy ? "En cours…" : model.state.title).font(.callout.weight(.semibold))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if !model.installed {
                wide("Démarrer", "play.fill") { model.apply() }
                    .buttonStyle(.borderedProminent).disabled(!model.canApply)
                    .help(model.enabledCount < 2 ? "Cochez au moins 2 serveurs" : "Démarrer la rotation")
            } else {
                wide("Arrêter", "stop.fill") { model.stop() }
                    .disabled(model.busy)
                    .help("Arrêter la rotation et couper le VPN")
            }
        }
        .controlSize(.large)
        .padding(12)
    }

    private var detail: String? {
        if let name = model.currentName { return name }
        if model.installed { return "Rotation toutes les \(Int(model.interval / 60)) min" }
        return nil
    }

    private func wide(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity) }
    }
}

struct Banner<Trailing: View>: View {
    let symbol: String
    let color: Color
    let text: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(color.opacity(0.14))
    }
}

struct Banners: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                Banner(symbol: "exclamationmark.octagon.fill", color: .red, text: message) {
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Fermer le message")
                }
            }
            if !model.hasWireGuard {
                Banner(symbol: "wrench.and.screwdriver.fill", color: .orange,
                       text: "WireGuard n'est pas inclus dans cette copie de l'application.") { EmptyView() }
            }
            if model.installed && !model.pending && (model.scriptsOutdated || !model.statsEnabled) {
                Banner(symbol: "arrow.down.circle.fill", color: .blue,
                       text: "Réappliquez la rotation pour installer la mise à jour (brève coupure).") {
                    Button("Mettre à jour") { model.apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.hasWireGuard || model.enabledCount < 2)
                }
            }
            if model.pending {
                Banner(symbol: "arrow.triangle.2.circlepath", color: .orange,
                       text: model.enabledCount < 2 ? "Cochez au moins 2 serveurs pour appliquer."
                                                    : "Modifications non appliquées.") {
                    Button("Appliquer") { model.apply() }
                        .buttonStyle(.borderedProminent).disabled(!model.canApply)
                        .keyboardShortcut("s")
                        .help("Appliquer les changements (⌘S)")
                }
            }
        }
    }
}

struct RootView: View {
    @StateObject private var model = Model()
    @StateObject private var page = Box(Page.home)
    @StateObject private var importing = Box(false)

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(get: { page.value }, set: { if let new = $0 { page.value = new } })) {
                ForEach(Page.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .badge(item == .servers ? model.library.servers.count : 0)
                        .tag(item)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Banners()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(page.value.rawValue)
        }
        .environmentObject(model)
        .frame(minWidth: 860, minHeight: 640)
        .background { shortcuts }
        .fileImporter(isPresented: $importing.value,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .task { await model.fetchIP() }
    }

    @ViewBuilder private var content: some View {
        switch page.value {
        case .home: DashboardView { page.value = .servers }
        case .servers: ServersView { importing.value = true }
        case .stats: StatsPage()
        case .settings: SettingsPage()
        case .log: LogPage()
        }
    }

    /// Raccourcis clavier : ⌘1 à ⌘5 pour les pages, ⌘O pour ajouter des fichiers
    private var shortcuts: some View {
        Group {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, item in
                Button(item.rawValue) { page.value = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Button("Ajouter") { importing.value = true }.keyboardShortcut("o")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

@main
struct RotationApp: App {
    var body: some Scene {
        Window("VPN Rotate", id: "main") { RootView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 980, height: 720)
    }
}
