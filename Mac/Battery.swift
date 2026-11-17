import Foundation
import IOKit.ps
import Observation

/// The Mac's battery level, for the notch. Event-driven: macOS tells us
/// when the level or charging state changes, so there's no polling.
@MainActor @Observable
final class Battery {
    private(set) var level: Int?
    private(set) var charging = false
    private(set) var pluggedIn = false

    // Live power figures (watts), read on demand while the Power page is open.
    /// Coming into the Mac from the charger.
    private(set) var powerIn: Double = 0
    /// What the Mac itself is using right now.
    private(set) var systemLoad: Double = 0
    /// Into the battery (positive) or out of it (negative).
    private(set) var batteryWatts: Double = 0
    /// The charger's rating, e.g. 65 W, and its name.
    private(set) var adapterWatts: Int?
    private(set) var adapterName: String?
    /// Each USB‑C port's negotiated USB Power Delivery contract.
    private(set) var ports: [PortPower] = []

    struct PortPower: Identifiable, Hashable {
        var id: Int
        var name: String
        /// true = this port is charging the Mac, false = the Mac powers a device on it.
        var into: Bool
        var volts: Double
        var amps: Double
        var watts: Double { volts * amps }
    }

    @ObservationIgnored private var source: CFRunLoopSource?

    var hasBattery: Bool { level != nil }

    var symbol: String {
        guard let level else { return "powerplug.fill" }
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    init() {
        read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let battery = Unmanaged<Battery>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { battery.read() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
    }

    /// Reads the battery controller's power telemetry (cheap; call every
    /// couple of seconds only while it's on screen).
    func readPower() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }

        let volts = Double(d["Voltage"] as? Int ?? 0) / 1000
        let amps = Double(d["InstantAmperage"] as? Int ?? d["Amperage"] as? Int ?? 0) / 1000
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            powerIn = Double(t["SystemPowerIn"] as? Int ?? 0) / 1000
            systemLoad = Double(t["SystemLoad"] as? Int ?? 0) / 1000
        } else {
            powerIn = 0
            systemLoad = max(0, -volts * amps)
        }
        batteryWatts = volts * amps
        let external = d["ExternalConnected"] as? Bool ?? false
        let adapter = d["AdapterDetails"] as? [String: Any]
        adapterWatts = external ? adapter?["Watts"] as? Int : nil
        let description = (adapter?["Description"] as? String) == "pd charger" ? "USB‑C PD charger" : adapter?["Description"] as? String
        adapterName = external ? (adapter?["Name"] as? String ?? description) : nil
        let adapterVolts = Double(adapter?["AdapterVoltage"] as? Int ?? 0) / 1000

        // Each USB‑C port's Power Delivery contract: the request (RDO) picks one
        // of the port's power offers (PDOs) and says how much current is agreed.
        var list: [PortPower] = []
        for (i, port) in ((d["PortControllerInfo"] as? [[String: Any]]) ?? []).enumerated() {
            let rdo = UInt32(truncatingIfNeeded: port["PortControllerActiveContractRdo"] as? Int ?? 0)
            let pdos = (port["PortControllerPortPDO"] as? [Int]) ?? []
            guard rdo != 0 else { continue }
            let position = Int((rdo >> 28) & 0x7)
            guard position >= 1, position <= pdos.count else { continue }
            let pdo = UInt32(truncatingIfNeeded: pdos[position - 1])
            guard pdo >> 30 == 0 else { continue }   // fixed-voltage offers only
            let v = Double((pdo >> 10) & 0x3FF) * 0.05
            let a = Double((rdo >> 10) & 0x3FF) * 0.01
            let charging = external && adapterVolts > 0 && abs(v - adapterVolts) < 0.5 && (port["PortControllerNPDOs"] as? Int ?? 0) > 1
            // macOS lists these controllers in a different order from the
            // physical ports, so name them by role rather than guess a socket.
            list.append(PortPower(id: i, name: charging ? "Charger" : "USB‑C device", into: charging, volts: v, amps: a))
        }
        ports = list
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            level = Int((Double(current) / Double(max) * 100).rounded())
            charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            pluggedIn = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return
        }
        level = nil
    }
}

import SwiftUI

/// The notch's Power page: watts in, watts used, battery flow and each USB‑C port.
struct NotchPower: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.battery
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                heading("RIGHT NOW")
                HStack(spacing: 10) {
                    stat("Into Mac", watts(b.powerIn), "bolt.fill", .green)
                    stat("Mac using", watts(b.systemLoad), "cpu", .white)
                    stat(b.batteryWatts >= 0 ? "Into battery" : "From battery",
                         watts(abs(b.batteryWatts)), b.batteryWatts >= 0 ? "battery.100percent.bolt" : "battery.50percent",
                         b.batteryWatts >= 0 ? .green : .orange)
                }
                if let w = b.adapterWatts {
                    Label("\(w) W \(b.adapterName ?? "charger") connected", systemImage: "powerplug.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                } else {
                    Label("Running on battery · \(b.level ?? 0)%", systemImage: "battery.75percent")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                heading("PORTS")
                if b.ports.isEmpty {
                    Text("Nothing is drawing or supplying power over USB‑C.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                ForEach(b.ports) { port in
                    HStack(spacing: 8) {
                        Image(systemName: port.into ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                            .foregroundStyle(port.into ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(port.into ? "Charger · into the Mac" : "USB‑C device · powered by the Mac")
                                .font(.system(size: 12, weight: .semibold))
                            Text(String(format: "up to %.1f W  (%.0f V × %.2f A)", port.watts, port.volts, port.amps))
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.dim)
                        }
                    }
                }
                Text("Per-port figures are the agreed USB‑C power limit; macOS doesn't measure each port's live draw.")
                    .font(.system(size: 9)).foregroundStyle(Theme.dim.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .task {
            // Live while this page is open; stops when it closes.
            while !Task.isCancelled {
                model.battery.readPower()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func watts(_ w: Double) -> String { String(format: w >= 10 ? "%.0f W" : "%.1f W", w) }

    private func stat(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .padding(10)
        .frame(width: 104, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).kerning(1.5).foregroundStyle(Theme.dim)
    }
}
