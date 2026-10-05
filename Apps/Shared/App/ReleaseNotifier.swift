#if !os(tvOS)
import Foundation
import LanternaKit
@preconcurrency import UserNotifications

/// Local notifications (no push entitlement) for the next episode or release of watchlist and favourite titles.
/// Re-planned whenever the app becomes active, so the schedule follows the watchlist.
@MainActor
enum ReleaseNotifier {
    static let prefix = "release."

    /// Asks for permission. Returns false when the owner declined.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func refresh(env: AppEnvironment) async {
        guard env.config.notifyReleases else { await cancelAll(); return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let keys = Set(await env.library.titleKeys(.watchlist) + env.library.titleKeys(.favorite)).filter { $0.hasPrefix("movie:") || $0.hasPrefix("show:") }
        await cancelAll()
        for key in keys.prefix(40) {
            guard let ref = TitleRef(key: key), let detail = await env.detail(for: ref), let upcoming = detail.upcoming else { continue }
            guard let fire = fireDate(for: upcoming.date) else { continue }
            let content = UNMutableNotificationContent()
            content.title = detail.summary.title
            content.body = ref.kind == .movie ? "Out today." : "\(upcoming.label) is out today."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(identifier: prefix + key, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
    }

    /// TMDB dates are plain days (UTC midnight). Fire at 9 in the morning, local time, on that day. Past days are skipped.
    static func fireDate(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: day)
        var local = calendar
        local.timeZone = .current
        guard let fire = local.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 9)), fire > now else { return nil }
        return fire
    }
}
#endif
