import Foundation
import UserNotifications

/// Notifications du Centre de notifications. Elles ne partent que pendant que
/// l'application est ouverte : la rotation, elle, tourne sans elle.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let alertsKey = "notifyAlerts"
    static let changesKey = "notifyChanges"

    /// Hors d'un paquet .app (tests), le centre de notifications n'existe pas
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.alertsKey: true, Self.changesKey: false])
        center?.delegate = self
    }

    var alerts: Bool { UserDefaults.standard.bool(forKey: Self.alertsKey) }
    var changes: Bool { UserDefaults.standard.bool(forKey: Self.changesKey) }

    /// Demande l'autorisation (macOS ne la montre qu'une fois) ; rend vrai si refusée
    func authorize(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            center.getNotificationSettings { settings in
                let denied = settings.authorizationStatus == .denied
                DispatchQueue.main.async { MainActor.assumeIsolated { done(denied) } }
            }
        }
    }

    /// Un même `id` remplace la notification précédente au lieu de s'empiler
    func post(_ title: String, _ body: String, id: String, sound: Bool = false) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Affichées aussi quand l'application est au premier plan
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
