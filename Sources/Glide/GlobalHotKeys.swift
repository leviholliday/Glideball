import AppKit
import Carbon.HIToolbox
import Observation

/// Glide's system-wide keyboard shortcuts (`GlobalShortcuts`), registered
/// with Carbon's RegisterEventHotKey: no permissions needed, so they work even
/// when a mapping has made the trackball hard to use.
@Observable
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    /// Shortcuts macOS wouldn't register — usually another app already has them.
    private(set) var failed: Set<GlobalShortcuts.Action> = []

    @ObservationIgnored var onPress: ((GlobalShortcuts.Action) -> Void)?
    @ObservationIgnored private var shortcuts = GlobalShortcuts()
    @ObservationIgnored private var refs: [GlobalShortcuts.Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    /// While a shortcut is being recorded none are registered, so pressing
    /// one records it instead of firing it.
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var suspendCount = 0

    private static let signature = OSType(0x474C_4944)   // "GLID"

    private init() {}

    /// Installs the handler and registers `shortcuts`. Main thread.
    func start(_ shortcuts: GlobalShortcuts, onPress: @escaping (GlobalShortcuts.Action) -> Void) {
        self.onPress = onPress
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard err == noErr, id.signature == GlobalHotKeys.signature,
                      let action = GlobalShortcuts.Action(rawValue: Int(id.id)) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { GlobalHotKeys.shared.onPress?(action) }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        apply(shortcuts)
    }

    /// Re-registers after a change (settings, sync, import). Main thread.
    func apply(_ shortcuts: GlobalShortcuts) {
        self.shortcuts = shortcuts
        if !suspended { register() }
    }

    /// Unregisters everything while a shortcut is recorded. Whatever happens
    /// to the recorder, the shortcuts — Pause above all — come back within 20 s.
    func suspend() {
        suspendCount += 1
        let count = suspendCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.suspendCount == count { self?.resume() }
        }
        guard !suspended else { return }
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        register()
    }

    private func register() {
        unregisterAll()
        var failed = Set<GlobalShortcuts.Action>()
        for action in GlobalShortcuts.Action.allCases {
            guard let s = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(s.keyCode), Self.carbonModifiers(s.flags),
                                             EventHotKeyID(signature: Self.signature, id: UInt32(action.rawValue)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
            }
        }
        if failed != self.failed { self.failed = failed }
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var m = 0
        if flags.contains(.maskCommand) { m |= cmdKey }
        if flags.contains(.maskAlternate) { m |= optionKey }
        if flags.contains(.maskControl) { m |= controlKey }
        if flags.contains(.maskShift) { m |= shiftKey }
        return UInt32(m)
    }

    /// Whether one of macOS's own shortcuts (System Settings › Keyboard ›
    /// Keyboard Shortcuts) is the same — macOS then gets it first.
    static func systemUses(_ s: KeyShortcut) -> Bool {
        typealias Copy = @convention(c) (UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus
        // Not in the public headers, but exported by Carbon (which Glide links).
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CopySymbolicHotKeys") else { return false }
        var out: Unmanaged<CFArray>?
        guard unsafeBitCast(sym, to: Copy.self)(&out) == noErr,
              let hotKeys = out?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let mods = carbonModifiers(s.flags)
        return hotKeys.contains { h in
            (h["kHISymbolicHotKeyEnabled"] as? Bool) == true
                && (h["kHISymbolicHotKeyCode"] as? Int) == Int(s.keyCode)
                && ((h["kHISymbolicHotKeyModifiers"] as? Int).map { UInt32(truncatingIfNeeded: $0) & mask }) == mods
        }
    }
}
