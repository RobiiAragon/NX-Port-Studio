// NX Port Studio's Nextendo agent (docs/nextendo-agent.md). launchd starts it at login
// once Studio registers it; it has no window and lives in Studio's bundle.
import Foundation
import PortCore
import UserNotifications

/// Posts the hub's events as the agent app's own notifications.
struct AgentNotifications: NextendoHubNotifying {
    func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func post(_ event: NextendoHubEvent) async {
        let text = NextendoHubText.text(event)
        let content = UNMutableNotificationContent()
        content.title = text.title; content.body = text.body
        if case .revoked = event { content.sound = .default }
        let id: String = switch event {
        case .online(let friend, _): "online-\(friend.pid)"
        case .request(let friend): "request-\(friend.pid)"
        case .revoked: "revoked"
        }
        // A replacement per friend: someone who keeps reconnecting shows one notification.
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

let server = NextendoAgentServer.launchd(notifier: AgentNotifications())
server.resume()
dispatchMain()
