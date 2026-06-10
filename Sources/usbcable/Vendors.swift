import Foundation

// USB-IF vendor IDs commonly seen in cable e-markers.
// Only IDs verifiable against the public usb.ids database are listed —
// unknown VIDs are shown as hex rather than risking a wrong name.
enum Vendors {
    private static let table: [UInt16: String] = [
        0x05AC: "Apple Inc.",
        0x050D: "Belkin",
        0x291A: "Anker Innovations",
        0x17EF: "Lenovo",
        0x04E8: "Samsung",
        0x18D1: "Google",
        0x0451: "Texas Instruments",
        0x2109: "VIA Labs",
        0x1FC9: "NXP Semiconductors",
        0x04B4: "Cypress Semiconductor",
        0x0BDA: "Realtek",
        0x0BB4: "HTC",
        0x22D9: "Oppo",
        0x2717: "Xiaomi",
        0x045E: "Microsoft",
        0x03F0: "HP",
        0x413C: "Dell",
        0x0489: "Foxconn / Hon Hai",
        0x1532: "Razer",
    ]

    static func name(for vid: UInt16) -> String {
        let hex = String(format: "0x%04X", vid)
        if let known = table[vid] { return "\(known) (VID \(hex))" }
        return "Unknown vendor (VID \(hex))"
    }
}
