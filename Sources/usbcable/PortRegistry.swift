import Foundation
import IOKit

// Reads USB-C port state from the IORegistry "IOPort" plane, where macOS
// publishes per-port PD state: cable e-marker identity (SOP'), port partner
// identity (SOP), and power-source PDOs. All readable without root.

let kIOPortPlane = "IOPort"

struct PowerSourceOption {
    let voltageMV: Int
    let maxCurrentMA: Int
    let maxPowerMW: Int
    let className: String
}

struct PowerSourceInfo {
    let name: String
    let options: [PowerSourceOption]
    let winning: PowerSourceOption?
}

struct PortSnapshot {
    let name: String
    let activeCable: Bool
    let opticalCable: Bool
    let connectionActive: Bool
    /// Raw 32-bit VDO words from the cable e-marker (SOP' Discover Identity), if present.
    let cableIdentityVDOs: [UInt32]
    /// Raw property dictionary of the SOP' node, for --verbose / debugging.
    let sopPrimeProperties: [String: Any]
    /// Cable e-marker VID/PID, published as "Vendor/Product ID (SOP1)" on the CC node.
    let cableVendorID: UInt16?
    let cableProductID: UInt16?
    /// Human-readable info about the attached device/charger, keyed by label
    /// (Product, Manufacturer, Serial Number, ...). Empty if nothing attached.
    let partnerDetails: [String: String]
    let powerSources: [PowerSourceInfo]
    /// Actual USB data-link state: "None", "Device", "Host"...
    let usbConnectString: String?
    let superSpeedActive: Bool
    /// e.g. "Gen 1" when a SuperSpeed link is up.
    let linkSpeedDescription: String?
    /// macOS "Allow accessory to connect" security is withholding data on
    /// this port. The transport still signals a SuperSpeed rate, but no data
    /// flows until the user approves the accessory.
    let dataBlockedBySecurity: Bool
}

enum PortRegistry {

    static func snapshotPorts() -> [PortSnapshot] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var ports: [PortSnapshot] = []
        forEachDescendant(of: root, plane: kIOPortPlane) { entry, name in
            guard name.hasPrefix("Port-") else { return true }
            ports.append(snapshot(port: entry, name: name))
            return false // don't descend into port nodes here; snapshot() does
        }
        return ports
    }

    private static func snapshot(port: io_registry_entry_t, name: String) -> PortSnapshot {
        let props = properties(of: port)

        var vdos: [UInt32] = []
        var sopPrimeProps: [String: Any] = [:]
        var sources: [PowerSourceInfo] = []
        var cableVID: UInt16?
        var cablePID: UInt16?
        var partner: [String: String] = [:]
        var linkSpeed: String?
        var dataBlocked = false
        var connectionActive = (props["ConnectionActive"] as? Bool) ?? false

        // First value found wins; "0"/empty placeholders are skipped.
        func note(_ label: String, _ value: Any?) {
            guard partner[label] == nil else { return }
            if let s = value as? String, !s.isEmpty, s != "0" {
                partner[label] = s
            } else if let n = value as? Int, n != 0 {
                partner[label] = String(format: "0x%04X", n)
            }
        }

        forEachDescendant(of: port, plane: kIOPortPlane) { entry, childName in
            let className = ioClassName(of: entry)
            let childProps = properties(of: entry)

            if className.contains("USBPDSOPp") || childName == "SOP'" || childName == "SOPp" {
                sopPrimeProps = childProps
                vdos = extractVDOs(from: childProps)
            } else if className == "IOPortFeaturePowerSource" {
                sources.append(powerSource(named: childName, props: childProps))
            } else if className == "IOPortTransportStateCC" {
                // The cable's e-marker VID/PID surfaces here ("SOP1" = SOP').
                let meta = (childProps["Metadata"] as? [String: Any]) ?? [:]
                if let vid = (childProps["Vendor ID (SOP1)"] ?? meta["Vendor ID (SOP1)"]) as? Int {
                    cableVID = UInt16(truncatingIfNeeded: vid)
                }
                if let pid = (childProps["Product ID (SOP1)"] ?? meta["Product ID (SOP1)"]) as? Int {
                    cablePID = UInt16(truncatingIfNeeded: pid)
                }
            } else if className == "IOPortTransportProtocolAppleUVDM" {
                // Apple chargers/devices describe themselves over UVDM.
                note("Product", childProps["User String"])
                note("Manufacturer", childProps["Vendor"])
                note("Model", childProps["Model"])
                note("Serial Number", childProps["Serial Number"])
                note("Hardware Version", childProps["Hardware Version"])
                note("Firmware Version", childProps["Firmware Version"])
            }
            if linkSpeed == nil, let desc = childProps["SuperSpeedSignalingDescription"] as? String {
                linkSpeed = desc
            }
            // macOS TRM (Trust and Restrict Management) blocks data on a USB3
            // or CIO transport until the user approves the accessory. The flag
            // can be a CFBoolean or a 0/1 CFNumber depending on the node.
            if let r = childProps["TRM_TransportRestricted"],
               (r as? Bool == true) || ((r as? NSNumber)?.boolValue == true) {
                dataBlocked = true
            }
            // Attached USB devices self-describe in a Metadata dict on various nodes.
            if let meta = childProps["Metadata"] as? [String: Any], meta["Product"] != nil {
                note("Product", meta["Product"])
                note("Manufacturer", meta["Manufacturer"])
                note("Serial Number", meta["Serial Number"])
            }
            if !childProps.isEmpty, childProps["ConnectionActive"] as? Bool == true {
                connectionActive = true
            }
            return true
        }

        // A populated CC/USB-PD subtree, an active power source, or a blocked
        // transport all mean something is plugged in, even if the port node
        // itself doesn't say so.
        if !sources.isEmpty || !vdos.isEmpty || dataBlocked { connectionActive = true }

        return PortSnapshot(
            name: name,
            activeCable: (props["ActiveCable"] as? Bool) ?? false,
            opticalCable: (props["OpticalCable"] as? Bool) ?? false,
            connectionActive: connectionActive,
            cableIdentityVDOs: vdos,
            sopPrimeProperties: sopPrimeProps,
            cableVendorID: cableVID,
            cableProductID: cablePID,
            partnerDetails: partner,
            powerSources: sources,
            usbConnectString: props["IOAccessoryUSBConnectString"] as? String,
            superSpeedActive: (props["IOAccessoryUSBSuperSpeedActive"] as? Bool) ?? false,
            linkSpeedDescription: linkSpeed,
            dataBlockedBySecurity: dataBlocked
        )
    }

    // MARK: - VDO extraction

    /// The SOP' node carries the Discover Identity response. Property naming
    /// varies across macOS builds, so accept any property whose value looks
    /// like VDO words: an array of numbers, or a raw little-endian data blob.
    private static func extractVDOs(from props: [String: Any]) -> [UInt32] {
        // Preferred: explicitly named identity properties.
        let preferredKeys = ["Identity", "Discover Identity", "VDOs", "Cable VDO"]
        for key in preferredKeys {
            if let words = vdoWords(from: props[key]) { return words }
        }
        // Fallback: first property that parses as a plausible VDO list
        // (ID Header has a nonzero 16-bit VID in its low bits).
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            guard !key.hasPrefix("IO") else { continue }
            if let words = vdoWords(from: value), words.count >= 1, words[0] & 0xFFFF != 0 {
                return words
            }
        }
        return []
    }

    private static func vdoWords(from value: Any?) -> [UInt32]? {
        switch value {
        case let nums as [NSNumber]:
            let words = nums.map { UInt32(truncatingIfNeeded: $0.uint64Value) }
            return words.isEmpty ? nil : words
        case let data as Data:
            guard data.count >= 4, data.count % 4 == 0 else { return nil }
            let bytes = Array(data) // normalize indices; Data slices don't start at 0
            var words: [UInt32] = []
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let w = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                    | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                words.append(w)
            }
            return words
        default:
            return nil
        }
    }

    // MARK: - Power sources

    private static func powerSource(named name: String, props: [String: Any]) -> PowerSourceInfo {
        func option(_ dict: [String: Any]) -> PowerSourceOption {
            PowerSourceOption(
                voltageMV: (dict["Voltage (mV)"] as? Int) ?? 0,
                maxCurrentMA: (dict["Max Current (mA)"] as? Int) ?? 0,
                maxPowerMW: (dict["Max Power (mW)"] as? Int) ?? 0,
                className: (dict["Class"] as? String) ?? ""
            )
        }
        // OSSet in the kernel: bridges to NSSet, not NSArray.
        let rawOptions = (props["PowerSourceOptions"] as? NSSet)?.allObjects
            ?? (props["PowerSourceOptions"] as? [Any])
            ?? []
        let options = rawOptions
            .compactMap { $0 as? [String: Any] }
            .map(option)
            .sorted { $0.voltageMV < $1.voltageMV }
        let winning = (props["WinningPowerSourceOption"] as? [String: Any]).map(option)
        return PowerSourceInfo(name: name, options: options, winning: winning)
    }

    // MARK: - IOKit helpers

    private static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func ioClassName(of entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    private static func entryName(of entry: io_registry_entry_t, plane: String) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(entry, plane, &buf) == KERN_SUCCESS else { return "" }
        let name = String(cString: buf)
        var loc = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetLocationInPlane(entry, plane, &loc) == KERN_SUCCESS {
            return "\(name)@\(String(cString: loc))"
        }
        return name
    }

    /// Depth-first walk. The closure returns whether to descend into the entry's children.
    private static func forEachDescendant(
        of entry: io_registry_entry_t,
        plane: String,
        _ visit: (io_registry_entry_t, String) -> Bool
    ) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            let name = entryName(of: child, plane: plane)
            if visit(child, name) {
                forEachDescendant(of: child, plane: plane, visit)
            }
        }
    }
}
