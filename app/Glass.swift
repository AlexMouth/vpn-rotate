import SwiftUI

// Liquid Glass (macOS 26 et plus récent) pour la couche qui flotte au-dessus de la carte :
// cartes d'état, sélecteur de vue, boutons de la carte. Le contenu des pages (réglages,
// statistiques) reste sur des fonds opaques, comme le recommande Apple.
// Sur un système plus ancien, l'ancien matériau translucide est gardé.
// Réduire la transparence (Accessibilité) est respecté automatiquement par le verre.

extension View {
    /// Fond de verre dans la forme donnée ; `interactive` fait réagir le verre au clic
    @ViewBuilder
    func glassPanel<S: InsettableShape>(_ shape: S, interactive: Bool = false, shadow: CGFloat = 6) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: shadow, y: shadow / 2)
        }
    }

    /// Regroupe des éléments de verre voisins : ils se fondent quand ils se rapprochent
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Action principale d'une carte flottante
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Action secondaire d'une carte flottante
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
