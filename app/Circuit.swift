import SwiftUI
import MapKit

// MARK: - Trajet d'un serveur

private let regionCodes = Set(Locale.Region.isoRegions.map(\.identifier))

private let secureCore = try! NSRegularExpression(pattern: "(?<![A-Za-z])(CH|IS|SE)-[A-Z]{2}(?![A-Za-z])")
private final class Route {
    let value: (entry: String?, exit: String?)
    init(_ value: (entry: String?, exit: String?)) { self.value = value }
}
/// La carte et les listes redemandent sans cesse les mêmes noms
private let routes = NSCache<NSString, Route>()

/// Pays traversés, d'après le nom du serveur. Un nom Secure Core ("CH-DE-9")
/// passe par une entrée (Suisse, Islande ou Suède) avant le pays de sortie.
func route(in name: String) -> (entry: String?, exit: String?) {
    if let known = routes.object(forKey: name as NSString) { return known.value }
    let found = findRoute(in: name)
    routes.setObject(Route(found), forKey: name as NSString)
    return found
}

private func findRoute(in name: String) -> (entry: String?, exit: String?) {
    func code(_ text: Substring) -> String? {
        let code = text == "UK" ? "GB" : String(text)
        return regionCodes.contains(code) ? code : nil
    }
    if let match = secureCore.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
       let range = Range(match.range, in: name),
       let exit = code(name[range].suffix(2)) {
        return (String(name[range].prefix(2)), exit)
    }
    let first = name.split(whereSeparator: { !$0.isLetter })
        .filter { $0.count == 2 && $0.allSatisfy(\.isUppercase) }
        .lazy.compactMap(code).first
    return (nil, first)
}

/// Ville principale de chaque pays, quand la position exacte n'est pas connue
private let countryPositions: [String: (Double, Double)] = [
    "AD": (42.51, 1.52), "AE": (25.20, 55.27), "AF": (34.56, 69.21), "AL": (41.33, 19.82),
    "AM": (40.18, 44.51), "AO": (-8.84, 13.23), "AR": (-34.60, -58.38), "AT": (48.21, 16.37),
    "AU": (-33.87, 151.21), "AZ": (40.41, 49.87), "BA": (43.86, 18.41), "BD": (23.81, 90.41),
    "BE": (50.85, 4.35), "BG": (42.70, 23.32), "BH": (26.23, 50.59), "BN": (4.90, 114.94),
    "BO": (-16.50, -68.15), "BR": (-23.55, -46.63), "BT": (27.47, 89.64), "BY": (53.90, 27.57),
    "BZ": (17.50, -88.20), "CA": (43.65, -79.38), "CD": (-4.32, 15.31), "CH": (47.38, 8.54),
    "CI": (5.36, -4.01), "CL": (-33.45, -70.67), "CM": (3.87, 11.52), "CN": (31.23, 121.47),
    "CO": (4.71, -74.07), "CR": (9.93, -84.08), "CU": (23.11, -82.37), "CY": (35.19, 33.38),
    "CZ": (50.08, 14.44), "DE": (50.11, 8.68), "DK": (55.68, 12.57), "DO": (18.49, -69.93),
    "DZ": (36.75, 3.06), "EC": (-0.18, -78.47), "EE": (59.44, 24.75), "EG": (30.04, 31.24),
    "ER": (15.32, 38.93), "ES": (40.42, -3.70), "ET": (9.03, 38.74), "FI": (60.17, 24.94),
    "FR": (48.86, 2.35), "GB": (51.51, -0.13), "GE": (41.72, 44.83), "GH": (5.60, -0.19),
    "GL": (64.18, -51.72), "GR": (37.98, 23.73), "GT": (14.63, -90.51), "HK": (22.32, 114.17),
    "HN": (14.07, -87.19), "HR": (45.81, 15.98), "HU": (47.50, 19.04), "ID": (-6.21, 106.85),
    "IE": (53.35, -6.26), "IL": (32.09, 34.78), "IN": (19.08, 72.88), "IQ": (33.31, 44.37),
    "IR": (35.69, 51.39), "IS": (64.15, -21.94), "IT": (45.46, 9.19), "JM": (17.97, -76.79),
    "JO": (31.95, 35.93), "JP": (35.68, 139.69), "KE": (-1.29, 36.82), "KG": (42.87, 74.59),
    "KH": (11.56, 104.92), "KR": (37.57, 126.98), "KW": (29.38, 47.99), "KZ": (43.24, 76.89),
    "LA": (17.98, 102.63), "LB": (33.89, 35.50), "LI": (47.14, 9.52), "LK": (6.93, 79.86),
    "LT": (54.69, 25.28), "LU": (49.61, 6.13), "LV": (56.95, 24.11), "LY": (32.89, 13.19),
    "MA": (33.57, -7.59), "MC": (43.74, 7.42), "MD": (47.01, 28.86), "ME": (42.43, 19.26),
    "MK": (42.00, 21.43), "MM": (16.87, 96.20), "MN": (47.89, 106.91), "MR": (18.08, -15.98),
    "MT": (35.90, 14.51), "MU": (-20.16, 57.50), "MX": (19.43, -99.13), "MY": (3.14, 101.69),
    "MZ": (-25.97, 32.57), "NG": (6.52, 3.38), "NI": (12.11, -86.24), "NL": (52.37, 4.90),
    "NO": (59.91, 10.75), "NP": (27.72, 85.32), "NZ": (-36.85, 174.76), "OM": (23.59, 58.41),
    "PA": (8.98, -79.52), "PE": (-12.05, -77.04), "PH": (14.60, 120.98), "PK": (24.86, 67.01),
    "PL": (52.23, 21.01), "PR": (18.47, -66.11), "PT": (38.72, -9.14), "PY": (-25.26, -57.58),
    "QA": (25.29, 51.53), "RO": (44.43, 26.10), "RS": (44.79, 20.45), "RU": (55.76, 37.62),
    "RW": (-1.94, 30.06), "SA": (24.71, 46.68), "SD": (15.50, 32.56), "SE": (59.33, 18.07),
    "SG": (1.35, 103.82), "SI": (46.06, 14.51), "SK": (48.15, 17.11), "SN": (14.72, -17.47),
    "SO": (2.05, 45.32), "SV": (13.69, -89.22), "SY": (33.51, 36.29), "TD": (12.13, 15.06),
    "TG": (6.14, 1.22), "TH": (13.76, 100.50), "TJ": (38.56, 68.79), "TM": (37.96, 58.33),
    "TN": (36.81, 10.18), "TR": (41.01, 28.98), "TT": (10.65, -61.50), "TW": (25.03, 121.57),
    "TZ": (-6.79, 39.21), "UA": (50.45, 30.52), "UG": (0.35, 32.58), "US": (39.10, -94.58),
    "UY": (-34.90, -56.19), "UZ": (41.30, 69.24), "VE": (10.48, -66.90), "VN": (10.82, 106.63),
    "YE": (15.37, 44.19), "ZA": (-26.20, 28.05), "ZW": (-17.83, 31.05),
]

func countryCoordinate(_ code: String?) -> CLLocationCoordinate2D? {
    guard let code, let position = countryPositions[code] else { return nil }
    return CLLocationCoordinate2D(latitude: position.0, longitude: position.1)
}

// MARK: - Journal

/// Passage sur un serveur pendant une rotation
struct Visit: Identifiable, Equatable {
    /// Numéro dans la rotation, à partir de 1
    let id: Int
    let name: String
    let start: Date
    /// nil : dernier serveur d'une rotation qui n'a pas été arrêtée
    var end: Date?
}

/// Serveurs visités depuis le dernier démarrage (ou pendant la dernière
/// rotation si elle est arrêtée), d'après les lignes écrites par les scripts
func visits(inLog text: String) -> [Visit] {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let marker = " connecté : "
    var result: [Visit] = []
    var stopped = false
    for line in text.split(separator: "\n") {
        if line.hasSuffix(" rotation arrêtée") {
            guard !stopped, !result.isEmpty, let date = format.date(from: String(line.prefix(19))) else { continue }
            result[result.count - 1].end = date
            stopped = true
        } else if let range = line.range(of: marker),
                  let date = format.date(from: String(line[..<range.lowerBound])) {
            if stopped { result = []; stopped = false }
            if !result.isEmpty { result[result.count - 1].end = date }
            result.append(Visit(id: result.count + 1, name: String(line[range.upperBound...]), start: date))
        }
    }
    return result
}

// MARK: - Tracé

/// Un serveur du circuit, placé sur la carte
struct Stop: Identifiable {
    var id: String { name }
    let name: String
    let entry: String?
    let coordinate: CLLocationCoordinate2D
    /// Placé sur la ville principale du pays, faute de position relevée
    let approximate: Bool
    var numbers: [Int]
}

/// Serveurs au même endroit, réunis sous un seul repère
struct Place: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    var stops: [Stop]
    var numbers: [Int] { stops.flatMap(\.numbers).sorted() }
}

struct Circuit {
    /// Les plus récents seulement, pour que la carte reste lisible
    let visits: [Visit]
    let stops: [Stop]
    let home: CLLocationCoordinate2D?

    init(visits all: [Visit], locations: [String: String], home: String?) {
        visits = Array(all.suffix(30))
        self.home = CLLocationCoordinate2D(home)
        var stops: [Stop] = []
        for visit in visits {
            if let index = stops.firstIndex(where: { $0.name == visit.name }) {
                stops[index].numbers.append(visit.id)
                continue
            }
            let path = route(in: visit.name)
            let exact = CLLocationCoordinate2D(locations[visit.name])
            guard let coordinate = exact ?? countryCoordinate(path.exit) else { continue }
            stops.append(Stop(name: visit.name, entry: path.entry, coordinate: coordinate,
                              approximate: exact == nil, numbers: [visit.id]))
        }
        self.stops = stops
    }

    func path(to stop: Stop) -> [CLLocationCoordinate2D] {
        [home, countryCoordinate(stop.entry), stop.coordinate].compactMap { $0 }
    }

    var entries: [String] { Array(Set(stops.compactMap(\.entry))).sorted() }

    var places: [Place] {
        var places: [Place] = []
        for stop in stops {
            let key = String(format: "%.1f,%.1f", stop.coordinate.latitude, stop.coordinate.longitude)
            if let index = places.firstIndex(where: { $0.id == key }) {
                places[index].stops.append(stop)
            } else {
                places.append(Place(id: key, coordinate: stop.coordinate, stops: [stop]))
            }
        }
        return places
    }

    /// Zone qui contient tout le circuit, ou le seul trajet du serveur choisi
    func region(highlighting name: String?) -> MKCoordinateRegion? {
        let shown = name.flatMap { name in stops.first { $0.name == name } }.map { [$0] } ?? stops
        let points = shown.flatMap(path)
        guard let south = points.map(\.latitude).min(), let north = points.map(\.latitude).max(),
              let west = points.map(\.longitude).min(), let east = points.map(\.longitude).max()
        else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: max(-65, min(65, (south + north) / 2)),
                                           longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(120, max(10, (north - south) * 1.5)),
                                   longitudeDelta: min(340, max(16, (east - west) * 1.3))))
    }
}

struct CircuitMap: MapContent {
    let circuit: Circuit
    /// Serveur dont le trajet est mis en avant
    let highlighted: String?
    /// Serveur connecté en ce moment
    let current: String?
    let select: (Place) -> Void

    var body: some MapContent {
        // Le trajet mis en avant est tracé en dernier, au-dessus des autres
        ForEach(circuit.stops.sorted { $0.name != highlighted && $1.name == highlighted }) { stop in
            MapPolyline(coordinates: circuit.path(to: stop), contourStyle: .geodesic)
                .stroke(color(stop.name).opacity(highlighted == nil ? 0.8 : stop.name == highlighted ? 1 : 0.3),
                        style: StrokeStyle(lineWidth: stop.name == highlighted ? 4 : 2, lineCap: .round,
                                           lineJoin: .round,
                                           dash: stop.name == highlighted ? [] : [3, 6]))
        }
        if let home = circuit.home {
            Annotation("Votre position", coordinate: home) { HomeDot() }
                .annotationTitles(.hidden)
        }
        ForEach(circuit.entries, id: \.self) { code in
            if let coordinate = countryCoordinate(code) {
                Annotation("Entrée \(countryName(code))", coordinate: coordinate) { EntryDot(code: code) }
                    .annotationTitles(.hidden)
            }
        }
        ForEach(circuit.places) { place in
            Annotation(place.stops[0].name, coordinate: place.coordinate) {
                StopMarker(place: place,
                           color: color(place.stops.first { $0.name == current }?.name ?? ""),
                           highlighted: place.stops.contains { $0.name == highlighted }) { select(place) }
            }
            .annotationTitles(.hidden)
        }
    }

    private func color(_ name: String) -> Color {
        name == current ? VPNState.connected.color : .accentColor
    }
}

/// Pays d'entrée d'un serveur Secure Core
struct EntryDot: View {
    let code: String

    var body: some View {
        Text(flag(code))
            .font(.system(size: 14))
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .help("Entrée Secure Core : \(countryName(code))")
            .accessibilityLabel("Entrée Secure Core, \(countryName(code))")
    }
}

/// Numéros de passage à l'endroit d'un ou plusieurs serveurs
struct StopMarker: View {
    let place: Place
    let color: Color
    let highlighted: Bool
    let action: () -> Void

    private var label: String {
        let numbers = place.numbers
        let text = numbers.suffix(3).map(String.init).joined(separator: " · ")
        return numbers.count > 3 ? "… " + text : text
    }

    private var detail: String {
        place.stops.map { $0.name + ($0.approximate ? " (position approximative)" : "") }
            .joined(separator: "\n")
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(minWidth: 28, minHeight: 28)
                .background(color.gradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white, lineWidth: highlighted ? 3 : 2))
                .shadow(color: .black.opacity(0.3), radius: highlighted ? 6 : 3, y: 2)
                .fixedSize()
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(detail)
        .accessibilityLabel("Passage \(label), \(detail)")
    }
}

// MARK: - Liste des passages

struct CircuitCard: View {
    let circuit: Circuit
    let running: Bool
    let current: String?
    /// Passage choisi, nil pour tout le circuit
    @Binding var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(running ? "Circuit de la rotation en cours" : "Circuit de la dernière rotation")
                    .font(.headline)
                Spacer()
                if selection != nil {
                    Button("Tout afficher") { selection = nil }.buttonStyle(.borderless)
                } else if !circuit.visits.isEmpty {
                    Text("\(circuit.visits.last?.id ?? 0) passage\((circuit.visits.last?.id ?? 0) > 1 ? "s" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if circuit.visits.isEmpty {
                Text("Aucun serveur visité pour l'instant. Le circuit se dessine dès que la rotation démarre.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(circuit.visits) { visit in
                                chip(visit)
                                if visit.id != circuit.visits.last?.id {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.vertical, 2).padding(.horizontal, 1)
                    }
                    // Le passage le plus récent est à droite
                    .onChange(of: circuit.visits.last?.id, initial: true) {
                        if let last = circuit.visits.last?.id { proxy.scrollTo(last, anchor: .trailing) }
                    }
                }
            }
        }
        .floatingCard()
    }

    private func chip(_ visit: Visit) -> some View {
        let path = route(in: visit.name)
        let live = visit.id == circuit.visits.last?.id && visit.name == current
        let selected = selection == visit.id
        let color = live ? VPNState.connected.color : Color.accentColor
        let countries = [path.entry, path.exit].compactMap { $0 }.map(flag)
        return Button {
            selection = selected ? nil : visit.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(visit.id)")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(color, in: Capsule())
                    Text((["Vous"] + countries).joined(separator: " → "))
                        .font(.callout.weight(.semibold))
                }
                Text(visit.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(timing(visit, live: live)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(10)
            .frame(width: 170, alignment: .leading)
            .background(color.opacity(selected ? 0.22 : live ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected || live ? color.opacity(0.8) : .primary.opacity(0.1),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .help(visit.name)
        .id(visit.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func timing(_ visit: Visit, live: Bool) -> String {
        let day = Calendar.current.isDateInToday(visit.start)
            ? "" : visit.start.formatted(.dateTime.day().month(.abbreviated).locale(french)) + " "
        let start = day + visit.start.formatted(.dateTime.hour().minute().locale(french))
        if live { return "depuis \(start)" }
        guard let end = visit.end else { return start }
        let seconds = Int(max(0, end.timeIntervalSince(visit.start)))
        let length = seconds < 60 ? "\(seconds) s"
            : seconds < 3600 ? "\(seconds / 60) min"
            : String(format: "%d h %02d", seconds / 3600, seconds / 60 % 60)
        return "\(start) · \(length)"
    }
}
