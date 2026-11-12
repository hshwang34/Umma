import AVFoundation
import Foundation
import Observation

/// One audio input of `AVAudioSession.currentRoute`, reduced to what the label needs.
struct AudioInputPort: Equatable, Sendable {
    let type: AVAudioSession.Port
    let name: String
}

/// CLAUDE.md "honest device state": the microphone is named from the verified route only.
/// "Glasses microphone" requires, in the glasses build, a Bluetooth HFP *input* that is the
/// glasses: its port name equals the connected DAT device's name, or (no device name known) it
/// carries a whole-word Meta glasses model name. An A2DP-only route (output, no input), any other
/// headset ("Metal Headset", AirPods renamed "Meta") and the public build never produce it.
enum AudioInputLabel {
    static let iPhone = "iPhone microphone"
    static let glasses = "Glasses microphone"

    /// Whole-word Meta glasses model names, used only when no DAT device name is known.
    static let glassesModelPattern = #"\b(ray-?ban meta|oakley meta)\b"#

    static func label(for inputs: [AudioInputPort], glassesBuild: Bool, glassesDeviceName: String? = nil) -> String {
        if let hfp = inputs.first(where: { $0.type == .bluetoothHFP }) {
            if glassesBuild, isGlassesPortName(hfp.name, deviceName: glassesDeviceName) {
                return glasses
            }
            return hfp.name.isEmpty ? "Bluetooth microphone" : "Bluetooth microphone (\(hfp.name))"
        }
        if let first = inputs.first {
            switch first.type {
            case .builtInMic: return iPhone
            case .headsetMic: return "Headset microphone"
            case .usbAudio, .carAudio, .lineIn: return first.name.isEmpty ? "External microphone" : first.name
            default: return first.name.isEmpty ? "External microphone" : first.name
            }
        }
        // No input listed: the session isn't recording, and SousLens records with the iPhone
        // microphone unless a Bluetooth HFP input is verified once listening starts.
        return iPhone
    }

    /// True only for a verified glasses HFP input.
    static func isGlassesMic(_ inputs: [AudioInputPort], glassesBuild: Bool, glassesDeviceName: String? = nil) -> Bool {
        label(for: inputs, glassesBuild: glassesBuild, glassesDeviceName: glassesDeviceName) == glasses
    }

    static func isGlassesPortName(_ portName: String, deviceName: String?) -> Bool {
        let port = portName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !port.isEmpty else { return false }
        if let deviceName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceName.isEmpty {
            // A DAT device is known: only its exact name counts.
            return port.caseInsensitiveCompare(deviceName) == .orderedSame
        }
        return port.range(of: glassesModelPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Reads `AVAudioSession.currentRoute` and re-reads it on every `routeChangeNotification`.
@MainActor
@Observable
final class AudioRouteMonitor {
    private(set) var inputs: [AudioInputPort] = []
    let glassesBuild: Bool
    private let read: @MainActor () -> [AudioInputPort]
    private let observers = NotificationObserverBag()

    /// Name of the connected DAT glasses (glasses build), for an exact port-name match.
    private let glassesDeviceName: @MainActor () -> String?

    var inputLabel: String {
        AudioInputLabel.label(for: inputs, glassesBuild: glassesBuild, glassesDeviceName: glassesDeviceName())
    }
    var isGlassesMic: Bool {
        AudioInputLabel.isGlassesMic(inputs, glassesBuild: glassesBuild, glassesDeviceName: glassesDeviceName())
    }

    init(glassesBuild: Bool,
         glassesDeviceName: @escaping @MainActor () -> String? = { nil },
         notificationCenter: NotificationCenter = .default,
         read: @escaping @MainActor () -> [AudioInputPort] = AudioRouteMonitor.currentInputs) {
        self.glassesBuild = glassesBuild
        self.glassesDeviceName = glassesDeviceName
        self.read = read
        inputs = read()
        observers.add(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    func refresh() {
        inputs = read()
    }

    static func currentInputs() -> [AudioInputPort] {
        AVAudioSession.sharedInstance().currentRoute.inputs.map {
            AudioInputPort(type: $0.portType, name: $0.portName)
        }
    }
}
