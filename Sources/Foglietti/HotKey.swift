import Carbon

/// Global shortcuts (they work even when Foglietti is not in front):
/// 1 = new note, 2 = "Ask Foglietti"; both configurable in Settings → Shortcuts.
@MainActor
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    var askAction: (() -> Void)?
    private(set) var lastError: OSStatus?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private static let signature = OSType(0x464F_474C)   // 'FOGL'

    private static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z, "Space": kVK_Space, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    func apply(_ s: AppSettings) {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        lastError = nil
        installHandler()

        if s.hotKeyEnabled, let code = Self.keyCodes[s.hotKeyKey] {
            var mods = 0
            if s.hotKeyCommand { mods |= cmdKey }
            if s.hotKeyControl { mods |= controlKey }
            if s.hotKeyOption { mods |= optionKey }
            if s.hotKeyShift { mods |= shiftKey }
            // without modifiers it would steal an ordinary key
            if mods != 0, register(id: 1, code: code, mods: mods) != noErr { lastError = -1 }
        }
        if s.aiHotKeyEnabled, !s.hotKeysClash, let code = Self.keyCodes[s.askHotKeyKey] {
            var mods = 0
            if s.askHotKeyCommand { mods |= cmdKey }
            if s.askHotKeyControl { mods |= controlKey }
            if s.askHotKeyOption { mods |= optionKey }
            if s.askHotKeyShift { mods |= shiftKey }
            if mods != 0 { _ = register(id: 2, code: code, mods: mods) }
        }
    }

    private func register(id: UInt32, code: Int, mods: Int) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in
                if id == 2 { HotKey.shared.askAction?() } else { HotKey.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
