import Carbon
import AppKit

struct HotkeyBinding: Codable, Identifiable {
    var id: UInt32
    var name: String
    var key: UInt32
    var modifiers: UInt32
    static let defaults: [HotkeyBinding] = [
        .init(id: 1, name: "Panic bypass", key: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey)),
        .init(id: 2, name: "Boost up", key: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | shiftKey)),
        .init(id: 3, name: "Boost down", key: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | shiftKey)),
        .init(id: 4, name: "Visualizer", key: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey))
    ]
    var display: String {
        let prefix = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
        let names: [UInt32: String] = [UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_V): "V", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓"]
        return prefix + (names[key] ?? "Key \(key)")
    }
}
@MainActor
final class Hotkeys {
    weak var model: AppModel?
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    var bindings: [HotkeyBinding] {
        get { if let data = UserDefaults.standard.data(forKey: "hotkeys"), let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data) { return decoded }; return HotkeyBinding.defaults }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hotkeys"); register() }
    }
    init(model: AppModel) { self.model = model }
    func register() {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.perform(key.id) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        model?.hotkeyError = nil
        for binding in bindings {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: 0x464F464F, id: binding.id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) }
            else { model?.hotkeyError = "\(binding.name) (\(binding.display)) is already used by another app. Choose a different shortcut." }
        }
    }
    func perform(_ id: UInt32) {
        guard let model else { return }
        switch id {
        case 1: model.panic()
        case 2: model.setBoost(min(model.cap, model.profile.boost + 1))
        case 3: model.setBoost(max(0, model.profile.boost - 1))
        case 4: NotificationCenter.default.post(name: .showVisualizer, object: nil)
        default: break
        }
    }
}
extension Notification.Name { static let showVisualizer = Notification.Name("FoFoShowVisualizer") }
