import SwiftUI
import CoreLocation

// Carte du monde dessinée par l'application : quelques centaines de Ko de
// contours au lieu des tuiles et du moteur de MapKit.

// MARK: - Projection

/// Zone à cadrer, centre et étendue en degrés
struct MapRegion {
    var center: CLLocationCoordinate2D
    var latitudeDelta: Double
    var longitudeDelta: Double
}

extension MapRegion {
    /// Cadre un point, ou deux avec une marge autour
    init(showing point: CLLocationCoordinate2D, and other: CLLocationCoordinate2D?) {
        guard let other else {
            self.init(center: point, latitudeDelta: 24, longitudeDelta: 36)
            return
        }
        // Le plus court chemin peut passer par l'antiméridien
        var east = other.longitude - point.longitude
        if east > 180 { east -= 360 }
        if east < -180 { east += 360 }
        let latitude = (point.latitude + other.latitude) / 2
        self.init(center: CLLocationCoordinate2D(latitude: min(65, max(-65, latitude)),
                                                 longitude: point.longitude + east / 2),
                  latitudeDelta: min(110, max(16, abs(other.latitude - point.latitude) * 1.7)),
                  longitudeDelta: min(300, max(24, abs(east) * 1.5)))
    }
}

private let maxLatitude = 82.0

/// Mercator, monde ramené à un carré de côté 1 (x vers l'est, y vers le sud)
private func mercator(latitude: Double, longitude: Double) -> CGPoint {
    let lat = max(-maxLatitude, min(maxLatitude, latitude)) * .pi / 180
    return CGPoint(x: (longitude + 180) / 360, y: 0.5 - log(tan(.pi / 4 + lat / 2)) / (2 * .pi))
}

private func mercator(_ c: CLLocationCoordinate2D) -> CGPoint {
    mercator(latitude: c.latitude, longitude: c.longitude)
}

/// Points d'écran par unité du monde au niveau de zoom 0
private let baseScale = 256.0

/// Point du monde au centre de la zone libre, et zoom en puissances de 2
struct MapCamera: Equatable {
    var x: Double
    var y: Double
    var zoom: Double
    var scale: Double { baseScale * pow(2, zoom) }
}

/// Place une coordonnée à l'écran, sur la copie du monde la plus proche du centre
struct MapProjection {
    let camera: MapCamera
    let center: CGPoint

    func callAsFunction(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        let p = mercator(coordinate)
        let x = p.x + (camera.x - p.x).rounded()
        return CGPoint(x: center.x + (x - camera.x) * camera.scale, y: center.y + (p.y - camera.y) * camera.scale)
    }
}

extension View {
    /// Repère posé sur la carte, centré sur sa coordonnée ou la pointe en bas
    func mapMarker(at coordinate: CLLocationCoordinate2D, _ project: MapProjection,
                   bottom: Bool = false) -> some View {
        Color.clear.frame(width: 0, height: 0)
            .overlay(alignment: bottom ? .bottom : .center) { fixedSize() }
            .position(project(coordinate))
    }
}

/// Trait géodésique entre plusieurs points
struct MapLine: Identifiable, Equatable {
    let id: String
    let points: [CLLocationCoordinate2D]
    let color: Color
    let width: CGFloat
    var dash: [CGFloat] = []

    static func == (a: MapLine, b: MapLine) -> Bool {
        a.id == b.id && a.color == b.color && a.width == b.width && a.dash == b.dash
            && a.points.elementsEqual(b.points) { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// Tracé dans le monde, sans saut à l'antiméridien
    fileprivate var path: Path {
        var path = Path()
        var previous: Double?
        for (a, b) in zip(points, points.dropFirst()) {
            for c in greatCircle(a, b) {
                var longitude = c.longitude
                if let previous {
                    while longitude - previous > 180 { longitude -= 360 }
                    while longitude - previous < -180 { longitude += 360 }
                }
                let p = mercator(latitude: c.latitude, longitude: longitude)
                if previous == nil { path.move(to: p) } else { path.addLine(to: p) }
                previous = longitude
            }
        }
        return path
    }
}

/// Points du grand cercle entre deux coordonnées
private func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
    func vector(_ c: CLLocationCoordinate2D) -> (Double, Double, Double) {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }
    let u = vector(a), v = vector(b)
    let angle = acos(max(-1, min(1, u.0 * v.0 + u.1 * v.1 + u.2 * v.2)))
    guard angle > 0.001 else { return [a, b] }
    let steps = max(2, Int(angle * 40))
    return (0...steps).map { i in
        let t = Double(i) / Double(steps)
        let s = sin(angle)
        let k1 = sin((1 - t) * angle) / s, k2 = sin(t * angle) / s
        let x = k1 * u.0 + k2 * v.0, y = k1 * u.1 + k2 * v.1, z = k1 * u.2 + k2 * v.2
        return CLLocationCoordinate2D(latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
                                      longitude: atan2(y, x) * 180 / .pi)
    }
}

// MARK: - Contours des pays

/// Contours des pays (Natural Earth 1:50m, voir countries.py)
private final class CountryShapes {
    static let shared = CountryShapes()
    private let data: Data
    /// Position de chaque pays dans le fichier
    private var offsets: [String: Int] = [:]
    private var paths: [String: Path] = [:]

    /// Les terres, rangées par case d'une grille 8 × 8 pour ne dessiner que
    /// celles qui sont à l'écran. Chaque case garde l'emprise réelle de ses contours.
    private(set) lazy var tiles: [(box: CGRect, path: Path)] = {
        var tiles = [Int: (box: CGRect, path: Path)]()
        for offset in offsets.values {
            forEachRing(at: offset) { ring in
                let box = ring.boundingRect
                let key = min(7, max(0, Int(box.midX * 8))) * 8 + min(7, max(0, Int(box.midY * 8)))
                var tile = tiles[key] ?? (box, Path())
                tile.box = tile.box.union(box)
                tile.path.addPath(ring)
                tiles[key] = tile
            }
        }
        return Array(tiles.values)
    }()

    private init() {
        data = Bundle.main.url(forResource: "countries", withExtension: "bin")
            .flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) } ?? Data()
        var i = 0
        while i + 4 <= data.count {
            offsets[String(decoding: data[i..<i + 2], as: UTF8.self)] = i
            let rings = Int(word(i + 2))
            i += 4
            for _ in 0..<rings { i += 2 + 4 * Int(word(i)) }
        }
    }

    private func word(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }

    private func forEachRing(at offset: Int, _ body: (Path) -> Void) {
        var i = offset
        let count = Int(word(i + 2))
        i += 4
        for _ in 0..<count {
            let points = Int(word(i))
            i += 2
            var ring = Path()
            for n in 0..<points {
                let p = i + 4 * n
                let point = mercator(latitude: Double(Int16(bitPattern: word(p))) / 100,
                                     longitude: Double(Int16(bitPattern: word(p + 2))) / 100)
                if n == 0 { ring.move(to: point) } else { ring.addLine(to: point) }
            }
            ring.closeSubpath()
            body(ring)
            i += 4 * points
        }
    }

    func path(_ code: String) -> Path? {
        if let known = paths[code] { return known }
        guard let offset = offsets[code] else { return nil }
        var path = Path()
        forEachRing(at: offset) { path.addPath($0) }
        paths[code] = path
        return path
    }
}

private let ocean = Color(red: 0.06, green: 0.07, blue: 0.11)
private let landColor = Color(red: 0.16, green: 0.17, blue: 0.23)
private let borderColor = Color(red: 0.27, green: 0.29, blue: 0.37)

// MARK: - Caméra

/// Garde la caméra et la taille de la carte. Ne publie rien lui-même :
/// seule la carte suit les mouvements, pas le reste de l'accueil.
final class WorldMapController: ObservableObject {
    let camera = Box(MapCamera(x: 0.5, y: 0.38, zoom: 1.6))
    fileprivate var size = CGSize.zero
    fileprivate var insets = EdgeInsets()
    fileprivate var hover: CGPoint?
    fileprivate var gestureStart: MapCamera?
    /// Dernier cadrage demandé, refait si la place change avant que l'on bouge la carte
    private var fitted: MapRegion?
    private var monitor: Any?

    /// Zone que les cartes posées dessus laissent libre
    fileprivate var free: CGRect {
        let rect = CGRect(x: insets.leading, y: insets.top,
                          width: size.width - insets.leading - insets.trailing,
                          height: size.height - insets.top - insets.bottom)
        return rect.width > 80 && rect.height > 80 ? rect : CGRect(origin: .zero, size: size)
    }

    fileprivate var center: CGPoint { CGPoint(x: free.midX, y: free.midY) }

    /// Le monde occupe au moins la hauteur de la carte
    private var minZoom: Double { log2(max(1, size.height) * 0.9 / (baseScale * 0.85)) }

    private func clamped(_ camera: MapCamera) -> MapCamera {
        var camera = camera
        camera.zoom = min(9, max(minZoom, camera.zoom))
        camera.y = min(0.92, max(0.08, camera.y))
        return camera
    }

    func show(_ region: MapRegion, animated: Bool) {
        fitted = region
        guard size.width > 0 else { return }
        var target = fit(region)
        // Par le plus court chemin, quelle que soit la copie du monde affichée
        target.x += (camera.value.x - target.x).rounded()
        if animated {
            withAnimation(.smooth(duration: 1.2)) { camera.value = target }
        } else {
            camera.value = target
        }
    }

    private func fit(_ region: MapRegion) -> MapCamera {
        let lat = region.center.latitude, half = region.latitudeDelta / 2
        let north = mercator(latitude: lat + half, longitude: 0).y
        let south = mercator(latitude: lat - half, longitude: 0).y
        let width = region.longitudeDelta / 360, height = max(0.001, south - north)
        let scale = min(free.width / width, free.height / height)
        return clamped(MapCamera(x: (region.center.longitude + 180) / 360, y: (north + south) / 2,
                                 zoom: log2(scale / baseScale)))
    }

    fileprivate func layout(size: CGSize, insets: EdgeInsets) {
        guard size != self.size || insets != self.insets else { return }
        self.size = size
        self.insets = insets
        if let fitted { show(fitted, animated: false) } else { camera.value = clamped(camera.value) }
    }

    /// Mouvement de l'utilisateur : le cadrage automatique s'arrête là
    fileprivate func move(_ camera: MapCamera) {
        fitted = nil
        self.camera.value = clamped(camera)
    }

    /// Zoom qui garde immobile le point du monde sous `point`
    fileprivate func zoomed(_ camera: MapCamera, by delta: Double, around point: CGPoint) -> MapCamera {
        let c = center, before = camera.scale
        let wx = camera.x + (point.x - c.x) / before, wy = camera.y + (point.y - c.y) / before
        var next = clamped(MapCamera(x: camera.x, y: camera.y, zoom: camera.zoom + delta))
        next.x = wx - (point.x - c.x) / next.scale
        next.y = wy - (point.y - c.y) / next.scale
        return next
    }

    fileprivate func zoom(by delta: Double, around point: CGPoint? = nil, animated: Bool) {
        let target = zoomed(camera.value, by: delta, around: point ?? center)
        fitted = nil
        if animated {
            withAnimation(.smooth(duration: 0.35)) { camera.value = clamped(target) }
        } else {
            camera.value = clamped(target)
        }
    }

    /// Molette : zoom ; trackpad à deux doigts : déplacement
    fileprivate func startScrolling() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let hover = self.hover, self.free.contains(hover) else { return event }
            if event.hasPreciseScrollingDeltas {
                let s = self.camera.value.scale
                var next = self.camera.value
                next.x -= event.scrollingDeltaX / s
                next.y -= event.scrollingDeltaY / s
                self.move(next)
            } else if event.scrollingDeltaY != 0 {
                self.zoom(by: max(-1, min(1, event.scrollingDeltaY * 0.25)), around: hover, animated: false)
            }
            return nil
        }
    }

    fileprivate func stopScrolling() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Vue

struct WorldMap<Overlay: View>: View {
    let controller: WorldMapController
    @ObservedObject private var camera: Box<MapCamera>
    let highlight: String?
    let lines: [MapLine]
    let overlay: (MapProjection) -> Overlay

    init(controller: WorldMapController, highlight: String?, lines: [MapLine],
         @ViewBuilder overlay: @escaping (MapProjection) -> Overlay) {
        self.controller = controller
        camera = controller.camera
        self.highlight = highlight
        self.lines = lines
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { proxy in
            let free = controller.free
            ZStack(alignment: .topLeading) {
                WorldCanvas(camera: camera.value, center: CGPoint(x: free.midX, y: free.midY),
                            highlight: highlight, lines: lines, overlay: overlay)
                zoomButtons.position(x: free.maxX - 26, y: free.minY + 48)
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(magnify)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                controller.zoom(by: 1, around: value.location, animated: true)
            })
            .onContinuousHover { phase in
                if case .active(let point) = phase { controller.hover = point } else { controller.hover = nil }
            }
            .onChange(of: proxy.size, initial: true) { controller.layout(size: proxy.size, insets: proxy.safeAreaInsets) }
            .onChange(of: proxy.safeAreaInsets) { controller.layout(size: proxy.size, insets: proxy.safeAreaInsets) }
        }
        .ignoresSafeArea()
        .onAppear { controller.startScrolling() }
        .onDisappear { controller.stopScrolling() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Carte du monde")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = controller.gestureStart ?? camera.value
                controller.gestureStart = start
                controller.move(MapCamera(x: start.x - value.translation.width / start.scale,
                                          y: start.y - value.translation.height / start.scale, zoom: start.zoom))
            }
            .onEnded { _ in controller.gestureStart = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = controller.gestureStart ?? camera.value
                controller.gestureStart = start
                controller.move(controller.zoomed(start, by: log2(max(0.05, value.magnification)),
                                                  around: value.startLocation))
            }
            .onEnded { _ in controller.gestureStart = nil }
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            zoomButton("plus", "Zoomer", 1)
            Divider().frame(width: 20)
            zoomButton("minus", "Dézoomer", -1)
        }
        .glassPanel(RoundedRectangle(cornerRadius: 9, style: .continuous), shadow: 5)
    }

    private func zoomButton(_ symbol: String, _ label: String, _ delta: Double) -> some View {
        Button { controller.zoom(by: delta, animated: true) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Le dessin et les repères, interpolés ensemble quand la caméra s'anime
private struct WorldCanvas<Overlay: View>: View, Animatable {
    var camera: MapCamera
    let center: CGPoint
    let highlight: String?
    let lines: [MapLine]
    let overlay: (MapProjection) -> Overlay

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.x, camera.y), camera.zoom) }
        set { camera = MapCamera(x: newValue.first.first, y: newValue.first.second, zoom: newValue.second) }
    }

    var body: some View {
        ZStack {
            // Redessiné seulement quand la carte change, pas à chaque mise à jour de l'accueil
            MapLayer(camera: camera, center: center, highlight: highlight, lines: lines).equatable()
            overlay(MapProjection(camera: camera, center: center))
        }
    }
}

private struct MapLayer: View, Equatable {
    let camera: MapCamera
    let center: CGPoint
    let highlight: String?
    let lines: [MapLine]

    var body: some View {
        let camera = camera, center = center
        let shapes = CountryShapes.shared
        let highlighted = highlight.flatMap(shapes.path)
        let traced = lines.map { ($0, $0.path) }
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ocean))
            let s = camera.scale
            let west = camera.x - center.x / s, east = camera.x + (size.width - center.x) / s
            let top = camera.y - center.y / s, bottom = camera.y + (size.height - center.y) / s
            func world(_ copy: Int) -> GraphicsContext {
                var c = context
                c.translateBy(x: center.x, y: center.y)
                c.scaleBy(x: s, y: s)
                c.translateBy(x: Double(copy) - camera.x, y: -camera.y)
                return c
            }
            for copy in Int(floor(west))...Int(floor(east)) {
                let c = world(copy)
                // Partie de cette copie du monde qui est à l'écran
                let visible = CGRect(x: west - Double(copy), y: top, width: east - west, height: bottom - top)
                for tile in shapes.tiles where tile.box.intersects(visible) {
                    c.fill(tile.path, with: .color(landColor))
                    c.stroke(tile.path, with: .color(borderColor), lineWidth: 0.6 / s)
                }
                if let highlighted, highlighted.boundingRect.intersects(visible) {
                    c.fill(highlighted, with: .color(VPNState.connected.color.opacity(0.4)))
                    c.stroke(highlighted, with: .color(VPNState.connected.color.opacity(0.95)), lineWidth: 1.5 / s)
                }
            }
            // Un trajet peut déborder de sa copie du monde
            guard !traced.isEmpty else { return }
            for copy in Int(floor(west)) - 1...Int(floor(east)) + 1 {
                let c = world(copy)
                for (line, path) in traced {
                    c.stroke(path, with: .color(line.color),
                             style: StrokeStyle(lineWidth: line.width / s, lineCap: .round, lineJoin: .round,
                                                dash: line.dash.map { $0 / s }))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
