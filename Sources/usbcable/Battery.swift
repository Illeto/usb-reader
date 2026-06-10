import Foundation
import IOKit

struct BatteryStatus {
    let percent: Int?
    let charging: Bool
    /// Power flowing into (+) or out of (-) the battery right now, in watts.
    let watts: Double?
}

enum Battery {
    static func read() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let amperageMA = (props["Amperage"] as? NSNumber)
            .map { Int64(truncatingIfNeeded: $0.int64Value) }
        let voltageMV = (props["Voltage"] as? NSNumber)?.int64Value

        var watts: Double?
        if let ma = amperageMA, let mv = voltageMV {
            watts = Double(ma) * Double(mv) / 1_000_000
        }

        return BatteryStatus(
            percent: (props["CurrentCapacity"] as? NSNumber)?.intValue,
            charging: (props["IsCharging"] as? Bool) ?? false,
            watts: watts
        )
    }
}
