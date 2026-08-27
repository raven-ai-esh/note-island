import Foundation
@preconcurrency import UserNotifications

private let meetingNotificationIdentifierPrefix = "note-island.meeting."

enum MeetingNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

enum MeetingNotificationState: Equatable, Sendable {
    case disabled
    case enabling
    case enabled
    case denied
    case failed(String)
}

struct MeetingNotificationRequest: Equatable, Sendable {
    let identifier: String
    let meetingID: String
    let fireDate: Date
    let title: String
    let body: String
    let meetingURL: URL?
}

enum MeetingNotificationPlan {
    static let leadTime: TimeInterval = 10 * 60
    static let maximumPendingCount = 50

    static func requests(
        for meetings: [MeetingItem],
        now: Date,
        leadTime: TimeInterval = leadTime
    ) -> [MeetingNotificationRequest] {
        meetings
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(maximumPendingCount)
            .map { meeting in
                let requestedFireDate = meeting.startDate.addingTimeInterval(-leadTime)
                let fireDate = max(requestedFireDate, now.addingTimeInterval(1))
                var bodyParts = [meeting.startDate.formatted(date: .omitted, time: .shortened)]
                if let location = meeting.location { bodyParts.append(location) }
                return MeetingNotificationRequest(
                    identifier: identifier(for: meeting.id),
                    meetingID: meeting.id,
                    fireDate: fireDate,
                    title: "Скоро: \(meeting.title)",
                    body: bodyParts.joined(separator: " · "),
                    meetingURL: meeting.url
                )
            }
    }

    private static func identifier(for meetingID: String) -> String {
        let encoded = Data(meetingID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return meetingNotificationIdentifierPrefix + encoded
    }
}

@MainActor
protocol MeetingNotificationScheduling: AnyObject {
    func getAuthorizationStatus(
        _ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void
    )
    func requestAuthorization(
        _ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
    )
    func replacePendingRequests(
        with requests: [MeetingNotificationRequest],
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    )
    func cancelAll()
}

@MainActor
final class InertMeetingNotificationScheduler: MeetingNotificationScheduling {
    func getAuthorizationStatus(
        _ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void
    ) {
        completion(.denied)
    }

    func requestAuthorization(
        _ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
    ) {
        completion(.success(false))
    }

    func replacePendingRequests(
        with requests: [MeetingNotificationRequest],
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }

    func cancelAll() {}
}

@MainActor
protocol MeetingNotificationCenterClient: AnyObject {
    func getAuthorizationStatus(
        _ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void
    )
    func requestAuthorization(
        _ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
    )
    func getPendingIdentifiers(
        _ completion: @escaping @MainActor @Sendable ([String]) -> Void
    )
    func add(
        _ request: UNNotificationRequest,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    )
    func removePending(identifiers: [String])
}

@MainActor
final class SystemMeetingNotificationCenterClient: MeetingNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func getAuthorizationStatus(
        _ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void
    ) {
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(.authorized)
                case .notDetermined:
                    completion(.notDetermined)
                case .denied:
                    completion(.denied)
                @unknown default:
                    completion(.denied)
                }
            }
        }
    }

    func requestAuthorization(
        _ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(granted))
                }
            }
        }
    }

    func getPendingIdentifiers(
        _ completion: @escaping @MainActor @Sendable ([String]) -> Void
    ) {
        center.getPendingNotificationRequests { pending in
            let identifiers = pending.map(\.identifier)
            Task { @MainActor in completion(identifiers) }
        }
    }

    func add(
        _ request: UNNotificationRequest,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        center.add(request) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

@MainActor
final class SystemMeetingNotificationScheduler: MeetingNotificationScheduling {
    private let client: MeetingNotificationCenterClient
    private var operationID = 0

    init(client: MeetingNotificationCenterClient = SystemMeetingNotificationCenterClient()) {
        self.client = client
    }

    func getAuthorizationStatus(
        _ completion: @escaping @MainActor @Sendable (MeetingNotificationAuthorization) -> Void
    ) {
        client.getAuthorizationStatus(completion)
    }

    func requestAuthorization(
        _ completion: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void
    ) {
        client.requestAuthorization(completion)
    }

    func replacePendingRequests(
        with requests: [MeetingNotificationRequest],
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        operationID &+= 1
        let currentOperation = operationID
        client.getPendingIdentifiers { [weak self] pendingIdentifiers in
            let oldIdentifiers = pendingIdentifiers.filter {
                $0.hasPrefix(meetingNotificationIdentifierPrefix)
            }
            guard let self, self.operationID == currentOperation else { return }
            self.client.removePending(identifiers: oldIdentifiers)
            self.add(requests, at: 0, operationID: currentOperation, completion: completion)
        }
    }

    func cancelAll() {
        operationID &+= 1
        let currentOperation = operationID
        client.getPendingIdentifiers { [weak self] pendingIdentifiers in
            let identifiers = pendingIdentifiers.filter {
                $0.hasPrefix(meetingNotificationIdentifierPrefix)
            }
            guard let self, self.operationID == currentOperation else { return }
            self.client.removePending(identifiers: identifiers)
        }
    }

    private func add(
        _ requests: [MeetingNotificationRequest],
        at index: Int,
        operationID: Int,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        guard self.operationID == operationID else { return }
        guard index < requests.count else {
            completion(.success(()))
            return
        }
        let request = requests[index]
        let runtimeIdentifier = runtimeIdentifier(for: request, operationID: operationID)
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = [
            "meetingID": request.meetingID,
            "meetingURL": request.meetingURL?.absoluteString ?? ""
        ]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: request.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        client.add(UNNotificationRequest(
            identifier: runtimeIdentifier,
            content: content,
            trigger: trigger
        )) { [weak self] error in
            guard let self else { return }
            guard self.operationID == operationID else {
                self.client.removePending(identifiers: [runtimeIdentifier])
                return
            }
            if let error {
                self.client.removePending(identifiers: requests.map {
                    self.runtimeIdentifier(for: $0, operationID: operationID)
                })
                completion(.failure(error))
            } else {
                self.add(requests, at: index + 1, operationID: operationID, completion: completion)
            }
        }
    }

    private func runtimeIdentifier(
        for request: MeetingNotificationRequest,
        operationID: Int
    ) -> String {
        "\(request.identifier).operation.\(operationID)"
    }
}

@MainActor
protocol MeetingNotificationPreferenceStoring: AnyObject {
    var isEnabled: Bool { get set }
}

@MainActor
final class TransientMeetingNotificationPreference: MeetingNotificationPreferenceStoring {
    var isEnabled = false
}

@MainActor
final class UserDefaultsMeetingNotificationPreference: MeetingNotificationPreferenceStoring {
    private static let key = "meetings.notifications.enabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

enum MeetingNotificationControl {
    static func symbolName(enabled: Bool) -> String {
        enabled ? "bell" : "bell.slash"
    }
}
