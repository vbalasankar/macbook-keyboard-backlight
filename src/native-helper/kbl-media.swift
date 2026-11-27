import Foundation
import AppKit
import ApplicationServices

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("kbl-media: \(message)\n".utf8))
    exit(code)
}

// NX_KEYTYPE_ILLUMINATION_UP = 21, NX_KEYTYPE_ILLUMINATION_DOWN = 22

func postIlluminationKey(up: Bool) {
    let keyCode: Int32 = up ? 21 : 22
    for isDown in [true, false] {
        let state: Int32 = isDown ? 0xa : 0xb
        let data1 = Int((keyCode << 16) | (state << 8))
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

let args = CommandLine.arguments
guard args.count == 2, args[1] == "up" || args[1] == "down" else { fail("usage: kbl-media up|down", 2) }
guard AXIsProcessTrusted() else {
    fail("Accessibility permission missing (System Settings > Privacy & Security > Accessibility)", 78)
}
postIlluminationKey(up: args[1] == "up")
