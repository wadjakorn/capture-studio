import AVFoundation

/// One selectable entry in a camera/mic picker: a local `AVCaptureDevice` or a
/// Wi-Fi phone (`phone:<id>` / `phone-mic:<id>`), plus the phone group's
/// placeholder rows ("Find phones…", "Searching…").
struct PickerRow: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: DeviceKind
    var enabled: Bool = true
    var hint: String? = nil

    /// Placeholder row id: starts the Bonjour browser, selects nothing.
    static let findPhonesID = "phone-find"
    /// Placeholder row id: browsing, nothing found yet (disabled).
    static let searchingID = "phone-searching"
}

extension DeviceDiscovery {
    /// Local cameras grouped as in `grouped(_:)`, then the "Phone (Wi-Fi)" group.
    static func cameraRows(local: [AVCaptureDevice], phones: [PhoneDevice],
                           browsing: Bool) -> [(kind: DeviceKind, rows: [PickerRow])] {
        localRows(local) + [(kind: .phoneWiFi, rows: phoneRows(phones, browsing: browsing, id: PhoneDeviceID.camera))]
    }

    /// Local microphones grouped as in `grouped(_:)`, then the "Phone (Wi-Fi)" group.
    static func micRows(local: [AVCaptureDevice], phones: [PhoneDevice],
                        browsing: Bool) -> [(kind: DeviceKind, rows: [PickerRow])] {
        localRows(local) + [(kind: .phoneWiFi, rows: phoneRows(phones, browsing: browsing, id: PhoneDeviceID.mic))]
    }

    private static func localRows(_ devices: [AVCaptureDevice]) -> [(kind: DeviceKind, rows: [PickerRow])] {
        grouped(devices).map { group in
            (kind: group.kind, rows: group.devices.map {
                PickerRow(id: $0.uniqueID, name: $0.localizedName, kind: group.kind)
            })
        }
    }

    /// Pure: the Wi-Fi phone group's rows. Never empty.
    static func phoneRows(_ phones: [PhoneDevice], browsing: Bool,
                          id: (String) -> String) -> [PickerRow] {
        if phones.isEmpty {
            return browsing
                ? [PickerRow(id: PickerRow.searchingID, name: "Searching…", kind: .phoneWiFi,
                             enabled: false, hint: "Open Capture Studio Phone on your Android device")]
                : [PickerRow(id: PickerRow.findPhonesID, name: "Find phones…", kind: .phoneWiFi)]
        }
        return phones.map { p in
            let supported = p.protocolMajor == 1
            return PickerRow(id: id(p.id), name: p.name, kind: .phoneWiFi,
                             enabled: supported, hint: supported ? nil : "Update required")
        }
    }
}
