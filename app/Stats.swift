import SwiftUI
import Charts

// MARK: - Formats et couleurs

func dataSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(french))
}

func duration(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    if minutes >= 1440 { return "\(minutes / 1440) j \(minutes / 60 % 24) h" }
    if minutes >= 60 { return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" }
    if minutes >= 1 { return "\(minutes) min" }
    return seconds > 0 ? "< 1 min" : "0 min"
}

/// Couleur choisie séparément pour le mode clair et le mode sombre
private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
}

private let receivedColor = adaptive(0x2A78D6, 0x3987E5)
private let sentColor = adaptive(0xEB6834, 0xD95926)
private let timeColor = adaptive(0x6250D6, 0x9085E9)

private extension View {
    func statCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.09)))
    }
}

// MARK: - Périodes

enum Period: String, CaseIterable, Identifiable {
    case hour = "Heure", day = "Jour", week = "Semaine", month = "Mois", year = "Année"
    var id: Self { self }

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// Nombre de barres affichées à la fois
    var count: Int {
        switch self {
        case .hour: 24
        case .day: 30
        case .week, .month: 12
        case .year: 5
        }
    }

    /// Une étiquette d'axe toutes les n barres
    var labelStep: Int {
        switch self {
        case .hour: 3
        case .day: 5
        case .week: 2
        case .month, .year: 1
        }
    }

    var span: String {
        switch self {
        case .hour: "24 heures"
        case .day: "30 jours"
        case .week: "12 semaines"
        case .month: "12 mois"
        case .year: "5 ans"
        }
    }

    var unit: String {
        switch self {
        case .hour: "heure"
        case .day: "jour"
        case .week: "semaine"
        case .month: "mois"
        case .year: "année"
        }
    }

    func axisLabel(_ date: Date) -> String {
        let style = Date.FormatStyle(locale: french)
        switch self {
        case .hour: return date.formatted(style.hour())
        case .day, .week: return date.formatted(style.day(.twoDigits).month(.twoDigits))
        case .month: return date.formatted(style.month(.abbreviated))
        case .year: return date.formatted(style.year())
        }
    }

    func title(_ date: Date) -> String {
        let style = Date.FormatStyle(locale: french)
        switch self {
        case .hour: return date.formatted(style.weekday(.abbreviated).day().month(.abbreviated).hour())
        case .day: return date.formatted(style.weekday(.wide).day().month(.wide))
        case .week: return "Semaine du " + date.formatted(style.day().month(.wide))
        case .month: return date.formatted(style.month(.wide).year())
        case .year: return date.formatted(style.year())
        }
    }
}

/// Semaines du lundi au dimanche
private let calendar: Calendar = {
    var value = Calendar(identifier: .iso8601)
    value.locale = french
    value.timeZone = .autoupdatingCurrent
    return value
}()

struct Usage {
    var seconds: Double = 0
    var received: Int64 = 0
    var sent: Int64 = 0
    var bytes: Int64 { received + sent }
    var isEmpty: Bool { seconds == 0 && bytes == 0 }

    mutating func add(_ seconds: Double, _ received: Int64, _ sent: Int64) {
        self.seconds += seconds
        self.received += received
        self.sent += sent
    }
}

struct Bucket: Identifiable {
    let id: String
    let start: Date
    var usage = Usage()
}

/// Les barres d'une fenêtre de temps et le détail par serveur sur cette fenêtre
struct Report {
    var buckets: [Bucket]
    var servers: [String: Usage] = [:]
    var total = Usage()
    let end: Date

    init(_ history: [HistoryEntry], period: Period, offset: Int, now: Date = Date()) {
        let component = period.component
        let current = calendar.dateInterval(of: component, for: now)?.start ?? now
        func step(_ date: Date, _ value: Int) -> Date {
            calendar.date(byAdding: component, value: value, to: date) ?? date
        }
        let last = step(current, -offset * period.count)
        let starts = (0..<period.count).map { step(last, $0 - period.count + 1) }
        buckets = starts.enumerated().map { Bucket(id: String($0.offset), start: $0.element) }
        end = step(last, 1)

        for entry in history where entry.hour >= starts[0] && entry.hour < end {
            // Recherche de la dernière barre qui commence avant cette heure
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= entry.hour { low = middle } else { high = middle - 1 }
            }
            buckets[low].usage.add(entry.seconds, entry.received, entry.sent)
            servers[entry.server, default: Usage()].add(entry.seconds, entry.received, entry.sent)
            total.add(entry.seconds, entry.received, entry.sent)
        }
    }
}

/// Unité d'un axe, choisie selon la plus grande valeur affichée
private struct Scale {
    let divisor: Double
    let unit: String
    let top: Double

    init(data largest: Double) {
        if largest >= 1e9 { divisor = 1e9; unit = "Go" }
        else if largest >= 1e6 { divisor = 1e6; unit = "Mo" }
        else { divisor = 1e3; unit = "ko" }
        top = largest > 0 ? largest / divisor * 1.12 : 1
    }

    init(time largest: Double) {
        if largest >= 7200 { divisor = 3600; unit = "h" }
        else { divisor = 60; unit = "min" }
        top = largest > 0 ? largest / divisor * 1.12 : 1
    }
}

/// Mesure qui sert à classer les serveurs
enum Measure: String, CaseIterable, Identifiable {
    case total = "Total", received = "Réception", sent = "Envoi", time = "Temps"
    var id: Self { self }

    func value(_ usage: Usage) -> Double {
        switch self {
        case .total: Double(usage.bytes)
        case .received: Double(usage.received)
        case .sent: Double(usage.sent)
        case .time: usage.seconds
        }
    }
}

/// Ce que la page compte
enum Coverage: String, CaseIterable, Identifiable {
    case all = "Tout", vpn = "VPN", offline = "Hors VPN"
    var id: Self { self }

    var timeTitle: String {
        switch self {
        case .all: "Temps mesuré"
        case .vpn: "Temps connecté"
        case .offline: "Temps hors VPN"
        }
    }
}

// MARK: - Page

struct StatsPage: View {
    @EnvironmentObject var model: Model
    @StateObject private var period = Box(Period.day)
    @StateObject private var offset = Box(0)
    @StateObject private var selection = Box<String?>(nil)
    @StateObject private var allTime = Box(false)
    @StateObject private var measure = Box(Measure.total)
    @StateObject private var detailed = Box(false)
    @StateObject private var coverage = Box(Coverage.all)

    /// Les heures correspondant au choix Tout, VPN ou Hors VPN
    private var entries: [HistoryEntry] {
        switch coverage.value {
        case .all: model.history + model.offline
        case .vpn: model.history
        case .offline: model.offline
        }
    }

    var body: some View {
        // Les dernières secondes hors VPN sont ajoutées à l'ouverture de la page
        Group { content }.onAppear { model.flushOffline() }
    }

    @ViewBuilder private var content: some View {
        if model.stats.isEmpty && model.history.isEmpty && model.offline.isEmpty {
            ContentUnavailableView("Pas encore de statistiques", systemImage: "chart.bar",
                description: Text(model.statsEnabled
                    ? "Le premier relevé arrive en moins d'une minute après la connexion."
                    : "Démarrez la rotation ou réappliquez-la pour commencer à les enregistrer."))
        } else {
            // Liste réunie une seule fois par affichage
            let entries = entries
            let report = Report(entries, period: period.value, offset: offset.value)
            let earliest = entries.lazy.map(\.hour).min()
            ScrollView {
                VStack(spacing: 14) {
                    filters(report, earliest: earliest)
                    if model.history.isEmpty && !model.stats.isEmpty && coverage.value != .offline { notice }
                    tiles(report)
                    dataChart(report, "Réception", receivedColor, \.received)
                    dataChart(report, "Envoi", sentColor, \.sent)
                    timeChart(report)
                    if coverage.value != .offline { serverCard(report) }
                    detailCard(report)
                    Text(footer(since: earliest)).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
        }
    }

    // MARK: Filtres

    private func filters(_ report: Report, earliest: Date?) -> some View {
        let canGoBack = earliest.map { $0 < report.buckets[0].start } ?? false
        return HStack(spacing: 12) {
            Picker("Données comptées", selection: Binding(get: { coverage.value }, set: {
                coverage.value = $0
                selection.value = nil
            })) {
                ForEach(Coverage.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Compter tout le trafic, seulement le VPN ou seulement hors VPN")
            Picker("Période", selection: Binding(get: { period.value }, set: {
                period.value = $0
                offset.value = 0
                selection.value = nil
            })) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            Text(range(report)).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
            ControlGroup {
                Button { offset.value += 1; selection.value = nil } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                    .help("\(period.value.span) plus tôt")
                    .accessibilityLabel("Période précédente")
                Button { offset.value -= 1; selection.value = nil } label: { Image(systemName: "chevron.right") }
                    .disabled(offset.value == 0)
                    .help("\(period.value.span) plus tard")
                    .accessibilityLabel("Période suivante")
            }
            .fixedSize()
            Button("Actuel") { offset.value = 0; selection.value = nil }
                .disabled(offset.value == 0)
        }
    }

    private func range(_ report: Report) -> String {
        guard let first = report.buckets.first?.start else { return "" }
        let last = report.end.addingTimeInterval(-1)
        let style = Date.FormatStyle(locale: french)
        let format: Date.FormatStyle
        switch period.value {
        case .hour: format = style.day().month(.abbreviated).hour()
        case .day, .week: format = style.day().month(.abbreviated).year()
        case .month: format = style.month(.abbreviated).year()
        case .year: format = style.year()
        }
        let from = period.value == .hour ? report.buckets[0].start : first
        let to = period.value == .hour ? report.buckets[report.buckets.count - 1].start : last
        return "\(from.formatted(format)) – \(to.formatted(format))"
    }

    private var notice: some View {
        Label("Le détail par période commence au prochain relevé, une fois la rotation démarrée avec cette version. Les cumuls plus anciens restent visibles dans « Depuis le début ».",
              systemImage: "info.circle")
            .font(.callout)
            .statCard()
    }

    // MARK: Chiffres clés

    private func tiles(_ report: Report) -> some View {
        let used = report.buckets.filter { !$0.usage.isEmpty }
        let count = Int64(max(1, used.count))
        let servers = report.servers.keys.filter { $0 != offlineID }.count
        let connected = report.total.seconds - (report.servers[offlineID]?.seconds ?? 0)
        let serverText = "\(servers) serveur\(servers > 1 ? "s" : "")"
        let timeDetail = switch coverage.value {
        case .all: "dont \(duration(connected)) sur VPN"
        case .vpn: serverText
        case .offline: "Application ouverte"
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            tile("Réception", "arrow.down", dataSize(report.total.received),
                 "Moyenne \(dataSize(report.total.received / count)) par \(period.value.unit)", receivedColor)
            tile("Envoi", "arrow.up", dataSize(report.total.sent),
                 "Moyenne \(dataSize(report.total.sent / count)) par \(period.value.unit)", sentColor)
            tile("Total", "arrow.up.arrow.down", dataSize(report.total.bytes), "Réception + envoi")
            peakTile(used, "Record de réception", \.received, receivedColor)
            peakTile(used, "Record d'envoi", \.sent, sentColor)
            tile(coverage.value.timeTitle, "clock", duration(report.total.seconds), timeDetail, timeColor)
        }
    }

    private func peakTile(_ used: [Bucket], _ title: String, _ amount: KeyPath<Usage, Int64>,
                          _ color: Color) -> some View {
        let peak = used.max { $0.usage[keyPath: amount] < $1.usage[keyPath: amount] }
        let value = peak?.usage[keyPath: amount] ?? 0
        return tile(title, "arrow.up.to.line", dataSize(value),
                    value > 0 ? peak.map { period.value.title($0.start) } ?? "" : "Aucune activité", color)
    }

    private func tile(_ title: String, _ symbol: String, _ value: String, _ detail: String,
                      _ color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .statCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: Graphiques

    /// Un graphique par sens, chacun à son échelle : l'envoi reste lisible
    private func dataChart(_ report: Report, _ title: String, _ color: Color,
                           _ amount: KeyPath<Usage, Int64>) -> some View {
        let scale = Scale(data: Double(report.buckets.map { $0.usage[keyPath: amount] }.max() ?? 0))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text("\(title) par \(period.value.unit)").font(.headline)
                Spacer()
                Text(dataSize(report.total[keyPath: amount]))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            Chart {
                ForEach(report.buckets) { bucket in
                    let bytes = bucket.usage[keyPath: amount]
                    if bytes > 0 {
                        BarMark(x: .value("Période", bucket.id),
                                y: .value(scale.unit, Double(bytes) / scale.divisor),
                                width: .ratio(0.7))
                            .foregroundStyle(color)
                            .cornerRadius(3)
                            .opacity(dimming(bucket))
                            .accessibilityLabel(period.value.title(bucket.start))
                            .accessibilityValue("\(title) \(dataSize(bytes))")
                    }
                }
                if let bucket = selected(report) {
                    marker(bucket) {
                        tooltipLine(dataSize(bucket.usage[keyPath: amount]), title, color)
                    }
                }
            }
            .modifier(Axes(report: report, period: period.value, scale: scale, selection: $selection.value))
            .frame(height: 170)
            .overlay { if report.total[keyPath: amount] == 0 { empty } }
        }
        .statCard()
    }

    private func timeChart(_ report: Report) -> some View {
        let scale = Scale(time: report.buckets.map(\.usage.seconds).max() ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(coverage.value.timeTitle) par \(period.value.unit)").font(.headline)
            Chart {
                ForEach(report.buckets) { bucket in
                    if bucket.usage.seconds > 0 {
                        BarMark(x: .value("Période", bucket.id),
                                y: .value(scale.unit, bucket.usage.seconds / scale.divisor),
                                width: .ratio(0.7))
                            .foregroundStyle(timeColor)
                            .cornerRadius(3)
                            .opacity(dimming(bucket))
                            .accessibilityLabel(period.value.title(bucket.start))
                            .accessibilityValue(duration(bucket.usage.seconds))
                    }
                }
                if let bucket = selected(report) {
                    marker(bucket) {
                        tooltipLine(duration(bucket.usage.seconds),
                                    coverage.value == .vpn ? "Connecté"
                                        : coverage.value == .offline ? "Hors VPN" : "Mesuré", timeColor)
                    }
                }
            }
            .modifier(Axes(report: report, period: period.value, scale: scale, selection: $selection.value))
            .frame(height: 140)
            .overlay { if report.total.seconds == 0 { empty } }
        }
        .statCard()
    }

    private var empty: some View {
        Text("Aucune activité sur cette période").font(.callout).foregroundStyle(.secondary)
    }

    private func selected(_ report: Report) -> Bucket? {
        report.buckets.first { $0.id == selection.value }
    }

    private func dimming(_ bucket: Bucket) -> Double {
        selection.value == nil || selection.value == bucket.id ? 1 : 0.4
    }

    /// Repère vertical et bulle d'information de la barre survolée
    @ChartContentBuilder
    private func marker<Content: View>(_ bucket: Bucket,
                                       @ViewBuilder content: () -> Content) -> some ChartContent {
        let lines = content()
        // Dans la moitié droite, l'infobulle s'ouvre à gauche, et inversement
        let rightHalf = (Int(bucket.id) ?? 0) >= period.value.count / 2
        // Le repère passe derrière les barres, l'infobulle devant :
        // une infobulle hérite du plan de sa marque, il en faut donc deux.
        // La seconde couvre toute la case, pour ouvrir l'infobulle à côté de la barre
        RuleMark(x: .value("Période", bucket.id))
            .foregroundStyle(.primary.opacity(0.15))
            .zIndex(-1)
        RectangleMark(x: .value("Période", bucket.id), width: .ratio(1))
            .foregroundStyle(.clear)
            .zIndex(1)
            .accessibilityHidden(true)
            .annotation(position: rightHalf ? .leading : .trailing, alignment: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(period.value.title(bucket.start)).font(.caption.weight(.semibold))
                    lines
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            }
    }

    private func tooltipLine(_ value: String, _ name: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Serveurs

    private struct ServerRow: Identifiable {
        let id: String
        let name: String
        let usage: Usage
    }

    private func serverRows(_ report: Report) -> [ServerRow] {
        var totals = Dictionary(model.stats.map {
            ($0.id, Usage(seconds: $0.seconds, received: $0.received, sent: $0.sent))
        }, uniquingKeysWith: { first, _ in first })
        if coverage.value == .all && !model.offline.isEmpty {
            totals[offlineID] = model.offline.reduce(into: Usage()) { $0.add($1.seconds, $1.received, $1.sent) }
        }
        let source = allTime.value ? totals : report.servers
        var names = Dictionary(model.stats.map { ($0.id, $0.name + " (retiré)") }, uniquingKeysWith: { first, _ in first })
        for server in model.library.servers { names[server.id.uuidString] = server.name }
        names[offlineID] = "Hors VPN"
        // Les serveurs de la liste apparaissent même sans activité
        let ids = Set(source.keys).union(model.library.servers.map(\.id.uuidString))
        return ids.map { ServerRow(id: $0, name: names[$0] ?? "Serveur retiré", usage: source[$0] ?? Usage()) }
            .sorted {
                let first = measure.value.value($0.usage)
                let second = measure.value.value($1.usage)
                return first != second ? first > second
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func serverCard(_ report: Report) -> some View {
        let rows = serverRows(report)
        // Réception et envoi partagent la même échelle pour rester comparables
        let largest = max(1, rows.map {
            measure.value == .time ? $0.usage.seconds : Double(max($0.usage.received, $0.usage.sent))
        }.max() ?? 1)
        let sum = rows.map { measure.value.value($0.usage) }.reduce(0, +)
        let total = rows.reduce(into: Usage()) { $0.add($1.usage.seconds, $1.usage.received, $1.usage.sent) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(coverage.value == .all ? "Répartition" : "Par serveur").font(.headline)
                Spacer()
                Picker("Portée", selection: $allTime.value) {
                    Text("Période affichée").tag(false)
                    Text("Depuis le début").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Classer par", selection: $measure.value) {
                    ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Spacer()
                columnTitle("Réception", receivedColor)
                columnTitle("Envoi", sentColor)
                columnTitle("Temps", timeColor)
            }
            ForEach(rows) { row in
                serverLine(row, largest: largest,
                           percent: sum > 0 ? measure.value.value(row.usage) / sum : 0)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total").font(.body.weight(.semibold))
                    Text("\(dataSize(total.bytes)) au total").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                columns(total, emphasized: true)
            }
        }
        .statCard()
    }

    private func columnTitle(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(width: 82, alignment: .trailing)
    }

    private func serverLine(_ row: ServerRow, largest: Double, percent: Double) -> some View {
        HStack(spacing: 12) {
            FlagBadge(name: row.name, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).font(.body.weight(.medium)).lineLimit(1)
                if measure.value == .time {
                    bar(row.usage.seconds / largest, timeColor)
                } else {
                    VStack(spacing: 2) {
                        bar(Double(row.usage.received) / largest, receivedColor)
                        bar(Double(row.usage.sent) / largest, sentColor)
                    }
                }
                Text("\(dataSize(row.usage.bytes)) au total · "
                     + percent.formatted(.percent.precision(.fractionLength(0)).locale(french))
                     + (measure.value == .time ? " du temps" : measure.value == .total ? " des données"
                        : measure.value == .received ? " de la réception" : " de l'envoi"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            columns(row.usage, emphasized: false)
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ share: Double, _ color: Color) -> some View {
        GeometryReader { area in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.6))
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: area.size.width * share)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func columns(_ usage: Usage, emphasized: Bool) -> some View {
        HStack(spacing: 8) {
            Text(dataSize(usage.received)).frame(width: 82, alignment: .trailing)
                .accessibilityLabel("Réception \(dataSize(usage.received))")
            Text(dataSize(usage.sent)).frame(width: 82, alignment: .trailing)
                .accessibilityLabel("Envoi \(dataSize(usage.sent))")
            Text(duration(usage.seconds)).foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
        }
        .font(.body.weight(emphasized ? .semibold : .regular))
        .monospacedDigit()
    }

    // MARK: Tableau

    private func detailCard(_ report: Report) -> some View {
        let used = report.buckets.reversed().filter { !$0.usage.isEmpty }
        return DisclosureGroup(isExpanded: $detailed.value) {
            if used.isEmpty {
                Text("Aucune activité sur cette période").foregroundStyle(.secondary).padding(.top, 8)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        Text(period.value.rawValue).gridColumnAlignment(.leading)
                        Text("Réception")
                        Text("Envoi")
                        Text("Total")
                        Text("Temps")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(used) { bucket in
                        GridRow {
                            Text(period.value.title(bucket.start)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(dataSize(bucket.usage.received))
                            Text(dataSize(bucket.usage.sent))
                            Text(dataSize(bucket.usage.bytes)).fontWeight(.semibold)
                            Text(duration(bucket.usage.seconds))
                        }
                        .monospacedDigit()
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 10)
            }
        } label: {
            Text("Tableau détaillé").font(.headline)
        }
        .statCard()
    }

    private func footer(since earliest: Date?) -> String {
        let since = earliest.map {
            "Détail par période depuis le "
                + $0.formatted(Date.FormatStyle(locale: french).day().month(.wide).year()) + ". "
        } ?? ""
        let vpn = "VPN : actualisé chaque minute pendant la rotation, même quand l'application est fermée."
        let outside = "Hors VPN : compté seulement quand l'application est ouverte, réseau local compris."
        switch coverage.value {
        case .all: return since + vpn + " " + outside
        case .vpn: return since + vpn
        case .offline: return since + outside
        }
    }
}

/// Axes et survol communs aux graphiques
private struct Axes: ViewModifier {
    let report: Report
    let period: Period
    let scale: Scale
    let selection: Binding<String?>

    func body(content: Content) -> some View {
        // La dernière barre a toujours son étiquette
        let labelled = report.buckets.reversed().enumerated()
            .filter { $0.offset % period.labelStep == 0 }.map(\.element.id)
        return content
            .chartXScale(domain: report.buckets.map(\.id))
            .chartYScale(domain: 0 ... scale.top)
            .chartXAxis {
                AxisMarks(values: labelled) { value in
                    AxisValueLabel {
                        if let id = value.as(String.self), let index = Int(id), report.buckets.indices.contains(index) {
                            Text(period.axisLabel(report.buckets[index].start))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(number.formatted(.number.precision(.fractionLength(0...1)).locale(french))) \(scale.unit)")
                                // Même largeur pour aligner les graphiques
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            .chartXSelection(value: selection)
    }
}
