// Owner: FOUNDATION (SPEC §D.3, §D.4, §D.10).
//
// The single source of truth for user settings. `AppSettings` (Core) is stored as one JSON blob in
// UserDefaults under `AppSettings.userDefaultsKey` and decoded tolerantly (missing/malformed keys take their
// defaults). Every set is normalized, saved immediately and reported to observers.
//
// Views:   @Environment(SettingsStore.self) private var store
//          @Bindable var store = store;  Toggle("Haptics", isOn: $store.settings.hapticsEnabled)
// AppKit:  token = store.observe { old, new in if old.showMenuBarIcon != new.showMenuBarIcon { … } }
import Foundation
import Observation
import SuperNotchCore

@Observable
final class SettingsStore {

    /// Returned by `observe(_:)`. The observation ends when the token is cancelled or deallocated,
    /// so keep it (e.g. in an `@ObservationIgnored` property).
    final class ObserverToken {
        private var onCancel: (() -> Void)?

        fileprivate init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            let action = onCancel
            onCancel = nil
            action?()
        }
    }

    private struct Observer {
        weak var token: ObserverToken?
        let handler: (_ old: AppSettings, _ new: AppSettings) -> Void
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var storage: AppSettings
    @ObservationIgnored private var observers: [UUID: Observer] = [:]

    /// - Parameter defaults: `.standard` in the app; the smoke test passes an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: AppSettings.userDefaultsKey)
        storage = AppSettings.decode(from: data)
        if data == nil {
            Log.settings.info("No saved settings; using defaults")
        }
    }

    /// Current settings. Setting a new value normalizes it, saves it and notifies observers
    /// (only if it actually changed). Bindable: `$store.settings.hoverOpenDelay`.
    var settings: AppSettings {
        get {
            access(keyPath: \.settings)
            return storage
        }
        set {
            var value = newValue
            value.normalize()
            guard value != storage else { return }
            let old = storage
            withMutation(keyPath: \.settings) {
                storage = value
            }
            persist(value)
            notifyObservers(old: old, new: value)
        }
    }

    /// Changes several fields with a single save and a single notification.
    func update(_ change: (inout AppSettings) -> Void) {
        var copy = storage
        change(&copy)
        settings = copy
    }

    /// Everything back to defaults, except onboarding state and launch at login (they mirror history and the
    /// system rather than a preference; see `AppSettings.resetToDefaults()`).
    func reset() {
        Log.settings.info("Resetting settings to defaults")
        settings = storage.resetToDefaults()
    }

    /// Calls `handler(old, new)` synchronously on the main actor after every real change.
    /// Do not set `settings` synchronously from inside the handler.
    func observe(_ handler: @escaping (_ old: AppSettings, _ new: AppSettings) -> Void) -> ObserverToken {
        pruneObservers()
        let id = UUID()
        let token = ObserverToken(onCancel: { [weak self] in
            self?.observers[id] = nil
        })
        observers[id] = Observer(token: token, handler: handler)
        return token
    }

    // MARK: Private

    private func persist(_ value: AppSettings) {
        guard let data = value.encoded() else {
            Log.settings.error("Could not encode settings; keeping the previous saved value")
            return
        }
        defaults.set(data, forKey: AppSettings.userDefaultsKey)
    }

    private func notifyObservers(old: AppSettings, new: AppSettings) {
        pruneObservers()
        // Snapshot: a handler may cancel tokens while we iterate.
        let handlers = observers.values.map(\.handler)
        for handler in handlers {
            handler(old, new)
        }
    }

    private func pruneObservers() {
        observers = observers.filter { $0.value.token != nil }
    }
}
