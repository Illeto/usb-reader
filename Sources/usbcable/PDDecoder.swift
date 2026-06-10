import Foundation

// Decodes USB Power Delivery Discover Identity VDOs from a cable's e-marker
// (SOP' response), per USB PD R3.1 §6.4.4.3.1.

enum CableKind: String {
    case passive = "Passive"
    case active = "Active"
    case vpd = "VCONN-powered device"
    case unknown = "Unknown"
}

struct CableIdentity {
    let vendorID: UInt16
    let kind: CableKind
    let usbProductID: UInt16?
    let bcdDevice: UInt16?
    let hwVersion: Int
    let fwVersion: Int
    let plugType: String
    let maxCurrentMA: Int       // 3000 or 5000
    let maxVoltageMV: Int       // 20_000...50_000
    let speed: String
    let speedGbps: Double
    // Active-cable extras (nil for passive)
    let optical: Bool?
    let retimer: Bool?
    let usb4: Bool?
    let rawVDOs: [UInt32]

    var maxWatts: Int { maxCurrentMA * maxVoltageMV / 1_000_000 }
    var eprCapable: Bool { maxVoltageMV >= 50_000 }
}

enum PDDecoder {

    /// Decode a SOP' Discover Identity response. `words` may or may not
    /// include the leading VDM header (SVID 0xFF00); it is skipped if present.
    static func decodeCableIdentity(_ words: [UInt32]) -> CableIdentity? {
        var vdos = words
        if let first = vdos.first, first >> 16 == 0xFF00 {
            vdos.removeFirst()
        }
        // Discover Identity ACK: ID Header, Cert Stat, Product, Product Type VDO(s)
        guard vdos.count >= 4 else { return nil }

        let idHeader = vdos[0]
        let product = vdos[2]
        let typeVDO1 = vdos[3]
        let typeVDO2 = vdos.count >= 5 ? vdos[4] : nil

        let kind: CableKind
        switch (idHeader >> 27) & 0x7 {  // Product Type (Cable Plug)
        case 0b011: kind = .passive
        case 0b100: kind = .active
        case 0b110: kind = .vpd
        default: kind = .unknown
        }
        guard kind == .passive || kind == .active else { return nil }

        let plugType: String
        switch (typeVDO1 >> 18) & 0x3 {
        case 0b10: plugType = "USB-C"
        case 0b11: plugType = "Captive"
        default: plugType = "Legacy/unspecified"
        }

        let maxCurrentMA: Int
        switch (typeVDO1 >> 5) & 0x3 {  // VBUS Current Handling Capability
        case 0b10: maxCurrentMA = 5000
        default: maxCurrentMA = 3000    // 01b = 3A; 00b/11b shouldn't occur
        }

        let maxVoltageMV = (20 + 10 * Int((typeVDO1 >> 9) & 0x3)) * 1000

        let speed: String
        let gbps: Double
        switch typeVDO1 & 0x7 {  // USB Highest Speed
        case 0b000: speed = "USB 2.0 (480 Mbps)"; gbps = 0.48
        case 0b001: speed = "USB 3.2 Gen 1 (5 Gbps)"; gbps = 5
        case 0b010: speed = "USB 3.2 Gen 2 / USB4 Gen 2 (10/20 Gbps)"; gbps = 20
        case 0b011: speed = "USB4 Gen 3 (40 Gbps)"; gbps = 40
        case 0b100: speed = "USB4 Gen 4 (80 Gbps)"; gbps = 80
        default: speed = "Unknown"; gbps = 0
        }

        var optical: Bool?
        var retimer: Bool?
        var usb4: Bool?
        if kind == .active, let vdo2 = typeVDO2 {
            optical = (vdo2 >> 10) & 1 == 1 || (vdo2 >> 2) & 1 == 1
            retimer = (vdo2 >> 9) & 1 == 1
            usb4 = (vdo2 >> 8) & 1 == 0  // 0b = USB4 supported
        }

        return CableIdentity(
            vendorID: UInt16(idHeader & 0xFFFF),
            kind: kind,
            usbProductID: UInt16(product >> 16),
            bcdDevice: UInt16(product & 0xFFFF),
            hwVersion: Int((typeVDO1 >> 28) & 0xF),
            fwVersion: Int((typeVDO1 >> 24) & 0xF),
            plugType: plugType,
            maxCurrentMA: maxCurrentMA,
            maxVoltageMV: maxVoltageMV,
            speed: speed,
            speedGbps: gbps,
            optical: optical,
            retimer: retimer,
            usb4: usb4,
            rawVDOs: words
        )
    }
}
