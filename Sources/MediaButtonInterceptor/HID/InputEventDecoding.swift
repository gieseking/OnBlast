import AppKit
import Foundation

enum InputEventDecoding {
    static func decodeSystemDefined(_ event: NSEvent) -> ButtonEvent? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
            return nil
        }

        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let flags = Int(data1 & 0x0000_FFFF)
        let keyState = (flags & 0xFF00) >> 8
        let isDown = keyState == 0xA
        let isRepeat = (flags & 0x1) != 0

        guard let button = decodeSystemKeyCode(keyCode) else {
            return nil
        }

        return ButtonEvent(
            button: button,
            isDown: isDown,
            isRepeat: isRepeat,
            source: .systemDefined,
            deviceName: nil,
            rawDescription: "keyCode=\(keyCode) flags=\(flags)"
        )
    }

    static func rawSystemDefinedDescription(_ event: NSEvent) -> String? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
            return nil
        }

        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let flags = Int(data1 & 0x0000_FFFF)
        let keyState = (flags & 0xFF00) >> 8
        return "subtype=\(event.subtype.rawValue) keyCode=\(keyCode) flags=\(flags) keyState=0x\(String(keyState, radix: 16))"
    }

    static func decodeHID(
        usagePage: Int,
        usage: Int,
        value: Int,
        deviceName: String?,
        route: InputSourceRoute
    ) -> ButtonEvent? {
        guard let button = decodeUsage(page: usagePage, usage: usage) else {
            return nil
        }

        return ButtonEvent(
            button: button,
            isDown: value != 0,
            isRepeat: false,
            source: route,
            deviceName: deviceName,
            rawDescription: "usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(value)"
        )
    }

    private static func decodeSystemKeyCode(_ keyCode: Int) -> ButtonIdentifier? {
        switch keyCode {
        case 16:
            return .playPause
        case 17:
            return .nextTrack
        case 18:
            return .previousTrack
        case 0:
            return .volumeUp
        case 1:
            return .volumeDown
        case 7:
            return .mute
        default:
            return nil
        }
    }

    private static func decodeUsage(page: Int, usage: Int) -> ButtonIdentifier? {
        switch (page, usage) {
        case (0x0C, 0xCF):
            return .voiceCommand
        case (0x0B, 0x20), (0x0B, 0x21), (0x0B, 0x22), (0x0B, 0x24):
            return .voiceCommand
        case (0x0C, 0xCD), (0x0C, 0xB0), (0x0C, 0xB1):
            return .playPause
        case (0x0C, 0xB5):
            return .nextTrack
        case (0x0C, 0xB6):
            return .previousTrack
        case (0x0C, 0xE9):
            return .volumeUp
        case (0x0C, 0xEA):
            return .volumeDown
        case (0x0C, 0xE2), (0x01, 0xA7), (0x0B, 0x2F):
            return .mute
        case (0x01, 0xA9):
            return .systemMicMute
        case (0x01, 0xE1):
            return .callMuteToggle
        default:
            return nil
        }
    }
}
