import Foundation

// usbcable — shows what the USB-C cable plugged into this Mac can do
// (power and data speed), read from its e-marker chip via the IORegistry.

let args = CommandLine.arguments.dropFirst()
let verbose = args.contains("--verbose") || args.contains("-v")
let watch = args.contains("--watch") || args.contains("-w")

if args.contains("--help") || args.contains("-h") {
    print("""
    usage: usbcable [--verbose] [--watch]
           usbcable --decode <hex VDO words...>

    Reads the e-marker of cables plugged into this Mac's USB-C ports and
    reports the power and data speed each cable supports. For best results,
    have a charger or device attached at the far end of the cable — the
    e-marker is only interrogated during USB-PD negotiation.

      -v, --verbose   also print raw VDOs and SOP' registry properties
      -w, --watch     stay running and re-report whenever a port changes;
                      ideal for testing a drawer of cables one by one
      --decode        decode given Discover Identity VDO words (e.g. from a
                      --verbose dump or a PD analyzer) instead of reading ports
    """)
    exit(0)
}

if let i = args.firstIndex(of: "--decode") {
    let words = args[args.index(after: i)...].compactMap {
        UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }
    guard let id = PDDecoder.decodeCableIdentity(words) else {
        print("Could not decode a cable identity from \(words.count) word(s).")
        print("Expected: ID Header, Cert Stat, Product, Cable VDO [, Cable VDO2]")
        exit(1)
    }
    print("Vendor:      \(Vendors.name(for: id.vendorID))")
    print("Cable type:  \(id.kind.rawValue), \(id.plugType) plug")
    print("Power:       \(String(format: "%g", Double(id.maxCurrentMA) / 1000)) A @ up to \(id.maxVoltageMV / 1000) V — \(id.maxWatts) W max  (EPR/240 W: \(id.eprCapable ? "yes" : "no"))")
    print("Data speed:  \(id.speed)")
    exit(0)
}

func formatWatts(_ mw: Int) -> String {
    String(format: "%.1f W", Double(mw) / 1000)
}

// MARK: - Rendering

private let labelWidth = 12

func row(_ label: String, _ value: String) -> String {
    let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
    return "  " + Style.dim(padded) + " " + value
}

func cont(_ value: String) -> String {
    String(repeating: " ", count: labelWidth + 3) + value
}

func score(_ source: PowerSourceInfo) -> Int {
    (source.winning != nil ? 1_000_000_000 : 0)
        + (source.options.map(\.maxPowerMW).max() ?? 0)
}

func renderPort(_ port: PortSnapshot) -> String {
    var out: [String] = []
    let identity = PDDecoder.decodeCableIdentity(port.cableIdentityVDOs)
    // Prefer the source that won negotiation, then the strongest offer —
    // the "Brick ID" 5 V stub must not shadow the real USB-PD source.
    let charger = port.powerSources
        .filter { $0.winning != nil || !$0.options.isEmpty }
        .max { score($0) < score($1) }
    let isMagSafe = port.name.contains("MagSafe")
    let deviceAttached = port.usbConnectString == "Device"

    if identity == nil && !port.connectionActive && charger == nil && !deviceAttached {
        return Style.dim("○ \(port.name) — nothing connected")
    }
    let status = identity != nil ? "cable connected" : "connection active"
    out.append(Style.green("●") + " " + Style.bold(port.name) + Style.dim(" — \(status)"))

    // Cable verdict. Marked = the e-marker answered, via full VDOs or VID/PID.
    let cableMarked = identity != nil || port.cableVendorID != nil
    // Only the negotiated contract proves what the cable actually carries.
    let negotiatedMA = charger?.winning?.maxCurrentMA

    if let id = identity {
        out.append(row("Vendor", Style.cyan(Vendors.name(for: id.vendorID))))
        var type = "\(id.kind.rawValue), e-marked, \(id.plugType) plug"
        if id.optical == true { type += ", optical" }
        if id.retimer == true { type += ", retimer" }
        out.append(row("Cable type", type))
        let amps = String(format: "%g A", Double(id.maxCurrentMA) / 1000)
        out.append(row("Power", Style.bold("\(amps) @ up to \(id.maxVoltageMV / 1000) V — \(id.maxWatts) W max")
            + Style.dim("  (EPR/240 W: \(id.eprCapable ? "yes" : "no"))")))
        var speedLine = id.speed
        if id.usb4 == true { speedLine += ", USB4" }
        out.append(row("Data speed", Style.bold(speedLine)))
        if verbose {
            let words = id.rawVDOs.map { String(format: "0x%08X", $0) }.joined(separator: " ")
            out.append(row("Raw VDOs", Style.dim(words)))
        }
    } else if let vid = port.cableVendorID {
        var line = "e-marked — " + Style.cyan(Vendors.name(for: vid))
        if let pid = port.cableProductID { line += Style.dim(String(format: ", PID 0x%04X", pid)) }
        out.append(row("Cable", line))
        if port.activeCable { out.append(cont("active cable")) }
        if let ma = negotiatedMA, ma > 3000 {
            out.append(cont(Style.bold("carrying \(String(format: "%g", Double(ma) / 1000)) A — proven 5 A class (100 W+)")))
        } else {
            out.append(cont("at least 3 A (60 W); e-marked cables are typically 5 A (100 W+)"))
        }
    } else if isMagSafe {
        out.append(row("Cable", "MagSafe (cable identity not published)"))
    } else if !port.sopPrimeProperties.isEmpty || !port.cableIdentityVDOs.isEmpty {
        out.append(row("Cable", Style.yellow("e-marker responded, but identity could not be decoded")))
        out.append(cont("run with --verbose and report the SOP' properties"))
    } else if deviceAttached {
        out.append(row("Cable", "e-marker not read (device link — Mac is supplying power)"))
    } else if charger != nil {
        out.append(row("Cable", Style.bold("no e-marker — passive USB 2.0-class cable")))
        out.append(cont("max 60 W (3 A @ 20 V), 480 Mbps"))
    } else {
        out.append(row("Cable", "e-marker not read — no USB-PD negotiation on this port"))
        out.append(cont("to test this cable, use it to charge the Mac"))
        out.append(cont("(charger \u{2192} this cable \u{2192} this port), then re-run"))
    }

    // Actual data link state. A macOS accessory-security block takes
    // precedence: the transport still signals a SuperSpeed rate, but no data
    // flows until the user approves the accessory, so don't report a healthy
    // link.
    if port.dataBlockedBySecurity {
        out.append(row("Link", Style.yellow("data blocked by macOS accessory security")))
        let wouldBe = port.linkSpeedDescription.flatMap { $0 == "None" ? nil : $0 }
        let prefix = wouldBe.map { "would run at USB SuperSpeed \($0) — " } ?? ""
        out.append(cont(prefix + "approve the \"Allow accessory to connect\" prompt to enable data"))
    } else if deviceAttached {
        if port.superSpeedActive {
            let gen = port.linkSpeedDescription.map { " \($0)" } ?? ""
            out.append(row("Link", "USB SuperSpeed\(gen)"))
        } else {
            out.append(row("Link", "USB 2.0 (480 Mbps)"))
        }
    }

    if !port.partnerDetails.isEmpty {
        let d = port.partnerDetails
        var headline = [d["Manufacturer"], d["Product"]].compactMap { $0 }.joined(separator: " ")
        if headline.isEmpty { headline = d["Model"] ?? "(unnamed device)" }
        out.append(row("Attached", Style.cyan(headline)))
        var extras: [String] = []
        if d["Product"] != nil, let model = d["Model"] { extras.append("model \(model)") }
        if let sn = d["Serial Number"] { extras.append("serial \(sn)") }
        if let hw = d["Hardware Version"] { extras.append("HW \(hw)") }
        if let fw = d["Firmware Version"] { extras.append("FW \(fw)") }
        if !extras.isEmpty { out.append(cont(Style.dim(extras.joined(separator: ", ")))) }
    }

    if let src = charger {
        if let win = src.winning {
            let v = Double(win.voltageMV) / 1000
            let a = Double(win.maxCurrentMA) / 1000
            out.append(row("Charger", "negotiated " + Style.bold("\(String(format: "%g", v)) V @ \(String(format: "%g", a)) A (\(formatWatts(win.maxPowerMW)))")))
        }
        if verbose, let best = src.options.max(by: { $0.maxPowerMW < $1.maxPowerMW }) {
            let list = src.options
                .map { String(format: "%g V/%g A", Double($0.voltageMV) / 1000, Double($0.maxCurrentMA) / 1000) }
                .joined(separator: ", ")
            out.append(row("PDOs", Style.dim("\(list) (max \(formatWatts(best.maxPowerMW)))")))
        }
    }

    // Verdicts: cross-reference what the charger offers against what was
    // actually negotiated — only blame the cable when power is being left
    // on the table at the 3 A/60 W boundary an unmarked cable imposes.
    if let src = charger, !isMagSafe, !deviceAttached,
       let negotiated = src.winning?.maxPowerMW {
        let offeredMW = src.options.map(\.maxPowerMW).max() ?? 0
        if !cableMarked && offeredMW > negotiated + 5_000 && negotiated <= 63_000 {
            out.append(Style.yellow("  ⚠ Verdict:   charger offers \(formatWatts(offeredMW)) but only \(formatWatts(negotiated)) negotiated —"))
            out.append(Style.yellow("               this unmarked cable (3 A limit) is likely the limiter"))
        }
    }
    if deviceAttached && !port.superSpeedActive && !cableMarked && !port.dataBlockedBySecurity {
        out.append(Style.yellow("  ⚠ Verdict:   data running at 480 Mbps; if this device supports more,"))
        out.append(Style.yellow("               try a known data-rated cable"))
    }

    if verbose && !port.sopPrimeProperties.isEmpty {
        out.append(row("SOP' props", ""))
        for key in port.sopPrimeProperties.keys.sorted() {
            let value = port.sopPrimeProperties[key]!
            let desc = (value as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
                ?? String(describing: value)
            out.append(Style.dim("    \(key) = \(desc)"))
        }
    }
    return out.joined(separator: "\n")
}

func renderAll() -> String {
    let ports = PortRegistry.snapshotPorts()
    guard !ports.isEmpty else {
        return "No USB-C port controllers found (IOPort plane). Apple Silicon required."
    }
    // MagSafe first, then USB-C ports in numeric order.
    let ordered = ports.sorted {
        let a = ($0.name.contains("MagSafe") ? 0 : 1, $0.name)
        let b = ($1.name.contains("MagSafe") ? 0 : 1, $1.name)
        return a < b
    }
    var text = ordered.map(renderPort).joined(separator: "\n\n")
    if let battery = Battery.read(), let watts = battery.watts,
       ports.contains(where: { !$0.powerSources.isEmpty }) {
        let pct = battery.percent.map { "\($0)%" } ?? "?"
        let flow: String
        let icon: String
        if abs(watts) < 0.5 {
            flow = "idle (on external power)"
            icon = "🔋"
        } else if watts >= 0 {
            flow = "charging at " + Style.bold(String(format: "%.1f W", watts))
            icon = "⚡"
        } else {
            flow = "discharging at " + Style.bold(String(format: "%.1f W", -watts))
            icon = "🔋"
        }
        text += "\n\n" + icon + " " + Style.dim("Battery:") + " \(Style.bold(pct)) — \(flow)"
    }
    return text
}

// MARK: - Run

if watch {
    setvbuf(stdout, nil, _IOLBF, 0)
    print("Watching USB-C ports — plug cables in to test them (Ctrl-C to quit)\n")
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    var last = ""
    while true {
        let text = renderAll()
        if text != last {
            print("[\(formatter.string(from: Date()))]")
            print(text + "\n")
            last = text
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
} else {
    print(renderAll())
}
