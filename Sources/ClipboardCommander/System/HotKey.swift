import Carbon

/// Глобальная горячая клавиша через Carbon `RegisterEventHotKey`.
///
/// В отличие от перехвата клавиатуры (event tap, pynput), не требует доступа
/// к «Универсальному доступу» / «Мониторингу ввода» и не видит остальные нажатия.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4343_4D44 // 'CCMD'

    private var ref: EventHotKeyRef?

    /// - Parameters:
    ///   - keyCode: виртуальный код клавиши, например `kVK_ANSI_V`.
    ///   - modifiers: Carbon-модификаторы, например `cmdKey | shiftKey`.
    init?(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else { return nil }
        Self.actions[id] = action
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKey.signature else { return status }
                let id = hotKeyID.id
                // Carbon доставляет события в главном потоке.
                MainActor.assumeIsolated {
                    HotKey.actions[id]?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}
