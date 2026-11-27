import Foundation
import ApplicationServices

let exitOK: Int32 = 0, exitError: Int32 = 1, exitUsage: Int32 = 2
let exitUnavailable: Int32 = 3, exitPermission: Int32 = 78

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("kbl-helper: \(message)\n".utf8))
    exit(code)
}

// MARK: - CoreBrightness (private) backend

final class CoreBrightnessBackend {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private let client: AnyObject
    private let getFn: GetFn
    private let setFn: SetFn
    private let getSel: Selector
    private let setSel: Selector
    let keyboardID: UInt64

    init?() {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let obj = cls.init()
        let gs = NSSelectorFromString("brightnessForKeyboard:")
        let ss = NSSelectorFromString("setBrightness:forKeyboard:")
        guard obj.responds(to: gs), obj.responds(to: ss),
              let objClass = object_getClass(obj),
              let gImp = class_getMethodImplementation(objClass, gs),
              let sImp = class_getMethodImplementation(objClass, ss) else { return nil }
        client = obj
        getSel = gs
        setSel = ss
        getFn = unsafeBitCast(gImp, to: GetFn.self)
        setFn = unsafeBitCast(sImp, to: SetFn.self)

        // Prefer the ID reported by the framework; fall back to 1 (the built-in keyboard).
        var id: UInt64 = 1
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if obj.responds(to: idsSel),
           let ids = obj.perform(idsSel)?.takeUnretainedValue() as? [NSNumber],
           let first = ids.first {
            id = first.uint64Value
        }
        keyboardID = id
    }

    /// Current level as permille 0...1000, or nil when the value is not usable.
    func brightnessPermille() -> Int? {
        let value = getFn(client, getSel, keyboardID)
        guard value.isFinite, value >= 0, value <= 1.0001 else { return nil }
        return Int((min(value, 1.0) * 1000).rounded())
    }

    func setBrightness(permille: Int) -> Bool {
        return setFn(client, setSel, Float(permille) / 1000.0, keyboardID)
    }
}

// MARK: - Hotkey daemon

final class HotkeyDaemon {
    static let keyO: Int64 = 31   // kVK_ANSI_O (physical key position, layout independent)
    static let keyP: Int64 = 35   // kVK_ANSI_P
    static let maxPending = 16    // bound the backlog if the user mashes the keys

    let controllerPath: String
    let disabledFlagPath: String
    var tap: CFMachPort?
    private let queue = DispatchQueue(label: "keyboard-light.spawn")   // serial: no concurrent controllers
    private let pendingLock = NSLock()
    private var pending = 0

    init(controllerPath: String, disabledFlagPath: String) {
        self.controllerPath = controllerPath
        self.disabledFlagPath = disabledFlagPath
    }

    func isDisabled() -> Bool { access(disabledFlagPath, F_OK) == 0 }

    /// The controller must be owned by this user and not group/world writable.
    private func controllerIsTrusted() -> Bool {
        var st = stat()
        guard lstat(controllerPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return st.st_uid == getuid() && (st.st_mode & 0o022) == 0
    }

    func enqueue(_ action: String) {
        pendingLock.lock()
        if pending >= HotkeyDaemon.maxPending { pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pending -= 1; pendingLock.unlock() }
            guard controllerIsTrusted() else {
                FileHandle.standardError.write(Data("controller failed trust check, ignoring hotkey\n".utf8))
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [controllerPath, action]          // fixed argv, no shell string building
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.standardError
            do { try proc.run(); proc.waitUntilExit() }
            catch { FileHandle.standardError.write(Data("failed to run controller: \(error)\n".utf8)) }
        }
    }

    func run() -> Never {
        guard AXIsProcessTrusted() else {
            fail("Accessibility permission missing. Add this helper in System Settings > Privacy & Security > Accessibility and Input Monitoring, then run scripts/restart.sh.", exitOK)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let daemon = Unmanaged<HotkeyDaemon>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = daemon.tap { CGEvent.tapEnable(tap: t, enable: true) }   // self-heal
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let flags = event.flags
            // Exactly Control+Option; Command or Shift present means a different shortcut.
            guard flags.contains(.maskControl), flags.contains(.maskAlternate),
                  !flags.contains(.maskCommand), !flags.contains(.maskShift) else {
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == HotkeyDaemon.keyO || code == HotkeyDaemon.keyP else {
                return Unmanaged.passUnretained(event)
            }
            if daemon.isDisabled() { return Unmanaged.passUnretained(event) }       // pass through when paused
            daemon.enqueue(code == HotkeyDaemon.keyO ? "up" : "down")
            return nil                                                                // swallow (avoids typing a stray character)
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: selfPtr) else {
            fail("could not create event tap. Grant Input Monitoring and Accessibility to this helper, then run scripts/restart.sh.", exitOK)
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Clean shutdown on SIGTERM/SIGINT (launchctl bootout sends SIGTERM).
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { CGEvent.tapEnable(tap: tap, enable: false); exit(0) }
            s.resume(); sources.append(s)
        }
        FileHandle.standardError.write(Data("hotkey daemon running (Ctrl+Opt+O up, Ctrl+Opt+P down)\n".utf8))
        CFRunLoopRun()
        exit(exitError)
    }
}

// MARK: - Entry point

func requireAbsolute(_ path: String, _ what: String) {
    guard path.hasPrefix("/"), !path.contains("\0") else { fail("\(what) must be an absolute path", exitUsage) }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: kbl-helper get|set <permille>|probe|listen <controller> <disabled-flag>", exitUsage) }

switch args[1] {
case "get":
    guard args.count == 2 else { fail("get takes no arguments", exitUsage) }
    guard let backend = CoreBrightnessBackend(), let v = backend.brightnessPermille() else {
        fail("CoreBrightness keyboard interface unavailable or returned an invalid value", exitUnavailable)
    }
    print(v)
case "set":
    guard args.count == 3, let v = Int(args[2]), (0...1000).contains(v) else { fail("set requires an integer 0...1000", exitUsage) }
    guard let backend = CoreBrightnessBackend() else { fail("CoreBrightness keyboard interface unavailable", exitUnavailable) }
    guard backend.setBrightness(permille: v) else { fail("CoreBrightness rejected the brightness change", exitError) }
case "probe":
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    print("macOS: \(os)")
    if let b = CoreBrightnessBackend() {
        print("CoreBrightness: available (keyboard id \(b.keyboardID), level permille \(b.brightnessPermille().map(String.init) ?? "unreadable"))")
    } else { print("CoreBrightness: UNAVAILABLE") }
    print("Accessibility trusted: \(AXIsProcessTrusted())")
case "listen":
    guard args.count == 4 else { fail("listen requires <controller> <disabled-flag>", exitUsage) }
    requireAbsolute(args[2], "controller"); requireAbsolute(args[3], "disabled-flag")
    HotkeyDaemon(controllerPath: args[2], disabledFlagPath: args[3]).run()
default:
    fail("unknown command", exitUsage)
}
