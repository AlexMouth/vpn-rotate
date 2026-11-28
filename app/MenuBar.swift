import SwiftUI

/// Réglage "Afficher dans la barre des menus", activé par défaut
enum MenuBarSetting {
    static let key = "menuBar"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Icône de la barre des menus : l'état du VPN d'un coup d'œil
struct MenuBarLabel: View {
    @ObservedObject var state: Box<VPNState>

    var body: some View {
        // Image modèle (monochrome) : macOS l'adapte au fond de la barre
        Image(systemName: state.value.symbol)
            .accessibilityLabel("VPN Rotate : \(state.value.title)")
    }
}

/// Garde le modèle sans suivre ses changements : chaque vue observe ce qu'elle affiche.
/// L'icône de la barre des menus ne se redessine ainsi que si l'état change.
@MainActor
final class Models: ObservableObject {
    let model = Model()
    let menuState: Box<VPNState>
    private var watch: Any?

    init() {
        menuState = Box(model.state)
        watch = model.objectWillChange.sink { [weak self] _ in
            // Après coup : objectWillChange part avant la modification
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.menuState.value != self.model.state else { return }
                    self.menuState.value = self.model.state
                }
            }
        }
    }
}

/// Menu natif : état, changement de serveur, arrêt et ouverture de la fenêtre
struct MenuBarMenu: View {
    @ObservedObject var model: Model
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let release = updater.available {
            Button("Installer la mise à jour \(release.version) et relancer") {
                Task { await updater.install(release) }
            }
            Divider()
        }

        Text(headline)
        if let ip = model.ip {
            Text("IP \(ip.ip)" + ([ip.city, ip.country].compactMap { $0 }.isEmpty ? ""
                : " · " + [ip.city, ip.country].compactMap { $0 }.joined(separator: ", ")))
        }
        if model.currentID != nil, let last = model.lastChange {
            Text("Prochain changement vers \(last.addingTimeInterval(model.interval).formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        Button("Changer de serveur maintenant") { model.changeNow() }
            .disabled(!model.installed || model.busy)
        Menu("Aller sur") {
            ForEach(servers, id: \.id) { server in
                Toggle(server.name, isOn: Binding(get: { model.currentID == server.id },
                                                  set: { _ in model.changeNow(server.id) }))
            }
        }
        .disabled(!model.installed || model.busy || servers.isEmpty)

        Divider()

        if model.installed {
            Button("Arrêter la rotation") { model.stop() }.disabled(model.busy)
        } else {
            Button("Démarrer la rotation") { model.apply() }.disabled(!model.canApply)
        }

        Divider()

        Button("Ouvrir VPN Rotate") { showWindow() }
        Button("Quitter VPN Rotate") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var headline: String {
        if model.busy { return "Opération en cours…" }
        if model.state == .connected, let name = model.currentName { return "Connecté : \(name)" }
        return model.state.title
    }

    /// Serveurs de la rotation installée, dans l'ordre de la liste
    private var servers: [(id: String, name: String)] {
        model.activeNames.sorted { $0.key < $1.key }.map { (id: $0.key, name: $0.value) }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Fenêtre fermée : l'application reste dans la barre des menus, sans icône dans le Dock
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarSetting.enabled
    }

    /// Clic sur l'icône du Dock ou nouvelle ouverture depuis le Finder sans fenêtre visible
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
