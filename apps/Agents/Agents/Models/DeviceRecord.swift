import Foundation
import SwiftData

/// One per device running the app. Each device refreshes its own `lastSeen` while open, so every device
/// can show which others are connected through iCloud, and scheduled tasks know whether a Mac is around.
@Model
final class DeviceRecord {
    var deviceID: String = ""
    var name: String = ""
    /// "mac" or "iphone" / "ipad".
    var platform: String = ""
    var lastSeen: Date = Date.distantPast

    init(deviceID: String, name: String, platform: String) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.lastSeen = Date()
    }

    var isMac: Bool { platform == "mac" }
    /// Seen in the last two minutes: the app is open there right now.
    var isActive: Bool { Date().timeIntervalSince(lastSeen) < 120 }
}
