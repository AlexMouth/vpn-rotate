// Dessine l'icône de VPN Rotate : un bouclier au centre de deux flèches en rotation.
// Pour la régénérer, depuis le dossier du projet :
//   swift app/icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o app/AppIcon.icns
import AppKit

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

/// Dessin sur une grille de 1024 points, origine en bas à gauche
func draw(_ c: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Ombre portée de la tuile
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    c.addPath(tile)
    c.setFillColor(color(0x0B1440))
    c.fillPath()
    c.restoreGState()

    // Fond : bleu nuit en bas, bleu vif en haut
    c.saveGState()
    c.addPath(tile)
    c.clip()
    c.drawLinearGradient(gradient([color(0x2F6BEB), color(0x1B2C8C), color(0x0A1236)]),
                         start: CGPoint(x: 260, y: 924), end: CGPoint(x: 700, y: 100),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.drawRadialGradient(gradient([color(0x45D6E8, 0.38), color(0x45D6E8, 0)]),
                         startCenter: center, startRadius: 0, endCenter: center, endRadius: 430, options: [])
    c.restoreGState()

    // Deux flèches qui se suivent, dans le sens des aiguilles d'une montre
    let radius: CGFloat = 288, width: CGFloat = 58
    func point(_ degrees: CGFloat, _ distance: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + distance * cos(a), y: center.y + distance * sin(a))
    }
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.3))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    for start in [CGFloat(160), 340] {
        let end = start - 128
        c.setStrokeColor(color(0xFFFFFF))
        c.setLineWidth(width)
        c.setLineCap(.round)
        c.addArc(center: center, radius: radius, startAngle: start * .pi / 180,
                 endAngle: end * .pi / 180, clockwise: true)
        c.strokePath()

        // Pointe : base sur l'arc, sommet un peu plus loin dans le sens de rotation
        c.setFillColor(color(0xFFFFFF))
        c.setStrokeColor(color(0xFFFFFF))
        c.setLineWidth(22)
        c.setLineJoin(.round)
        c.move(to: point(end + 1, radius + 74))
        c.addLine(to: point(end + 1, radius - 74))
        c.addLine(to: point(end - 24, radius))
        c.closePath()
        c.drawPath(using: .fillStroke)
    }
    c.endTransparencyLayer()
    c.restoreGState()

    // Bouclier
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 697))
    shield.addCurve(to: CGPoint(x: 662, y: 641), control1: CGPoint(x: 556, y: 667), control2: CGPoint(x: 608, y: 647))
    shield.addLine(to: CGPoint(x: 662, y: 521))
    shield.addCurve(to: CGPoint(x: 512, y: 327), control1: CGPoint(x: 662, y: 427), control2: CGPoint(x: 600, y: 361))
    shield.addCurve(to: CGPoint(x: 362, y: 521), control1: CGPoint(x: 424, y: 361), control2: CGPoint(x: 362, y: 427))
    shield.addLine(to: CGPoint(x: 362, y: 641))
    shield.addCurve(to: CGPoint(x: 512, y: 697), control1: CGPoint(x: 416, y: 647), control2: CGPoint(x: 468, y: 667))
    shield.closeSubpath()

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.35))
    c.addPath(shield)
    c.setFillColor(color(0x1FAF6B))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shield)
    c.clip()
    c.drawLinearGradient(gradient([color(0x6FF0A8), color(0x13945F)]),
                         start: CGPoint(x: 512, y: 697), end: CGPoint(x: 512, y: 327), options: [])
    c.restoreGState()

    // Coche
    c.setStrokeColor(color(0xFFFFFF))
    c.setLineWidth(40)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: 442, y: 523))
    c.addLine(to: CGPoint(x: 494, y: 471))
    c.addLine(to: CGPoint(x: 590, y: 573))
    c.strokePath()
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// Jusqu'à 512 pixels, sans doublon : le fichier reste léger
for (size, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [2])] {
    for scale in scales {
        let pixels = size * scale
        let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Les ombres ne suivent pas l'échelle : on dessine en 1024 puis on réduit
        let large = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(large)
        c.interpolationQuality = .high
        c.draw(large.makeImage()!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
