// Hydra Audio — GPL-3.0
// SyncedValue — optimistic, echo-safe wrapper around a single daemon-owned
// value (state-sync Layer 1). The daemon owns all state; the UI updates
// optimistically, debounces pushes, ignores echoes during interaction, and
// ignores a stale echo while a newer write is in flight (until `settle`). This
// kills the control echo-loop (e.g. the channel-volume oscillation).

import Foundation
import SwiftUI

@MainActor
final class SyncedValue<Value>: ObservableObject {

    /// Current value. Bind controls to `binding`; read it for display.
    @Published private(set) var value: Value

    /// Invoked (debounced) when the user changes the value. Set once — usually in
    /// `.onAppear` — capturing only refs/values (never the SyncedValue) to avoid
    /// a retain cycle.
    var onPush: (Value) -> Void = { _ in }

    /// True while the user is actively manipulating the control. Exposed so
    /// callers can gate side effects like haptics.
    private(set) var isEditing = false

    private let equal: (Value, Value) -> Bool
    private let debounce: TimeInterval
    private let settle:   TimeInterval
    private var inFlight:  Value?
    private var lastPush = Date.distantPast
    private var work: DispatchWorkItem?

    init(_ initial: Value,
         debounce: TimeInterval = 0.08,
         settle:   TimeInterval = 0.5,
         equal: @escaping (Value, Value) -> Bool) {
        self.value    = initial
        self.debounce = debounce
        self.settle   = settle
        self.equal    = equal
    }

    /// SwiftUI binding whose writes go through the optimistic path.
    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.userSet($0) })
    }

    // MARK: User edits

    func userSet(_ newValue: Value) {
        guard !equal(value, newValue) else { return }
        value = newValue
        schedulePush()
    }

    func beginEditing() { isEditing = true }

    /// End of interaction — flush an authoritative final push immediately.
    func endEditing() {
        isEditing = false
        flush()
    }

    // MARK: Remote echoes

    /// Feed a fresh value from the daemon. Reconciles against any in-flight local
    /// write and the current interaction.
    func remote(_ serverValue: Value) {
        if isEditing { return }                        // don't fight a live drag
        if let pending = inFlight {
            if equal(pending, serverValue) {            // daemon caught up to us
                inFlight = nil
                return
            }
            if Date().timeIntervalSince(lastPush) < settle { return }  // stale echo
            inFlight = nil                              // timed out → accept server
        }
        if !equal(value, serverValue) { value = serverValue }
    }

    /// Hard-set to a server value WITHOUT pushing — e.g. when the control is
    /// retargeted to a different object (selecting another grid cell).
    func adopt(_ serverValue: Value) {
        work?.cancel()
        inFlight = nil
        if !equal(value, serverValue) { value = serverValue }
    }

    // MARK: Push plumbing

    private func schedulePush() {
        work?.cancel()
        if Date().timeIntervalSince(lastPush) >= debounce {
            pushNow()
        } else {
            let w = DispatchWorkItem { [weak self] in self?.pushNow() }
            work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: w)
        }
    }

    private func flush() {
        work?.cancel()
        pushNow()
    }

    private func pushNow() {
        lastPush = Date()
        inFlight = value
        onPush(value)
    }
}

extension SyncedValue where Value: Equatable {
    /// Convenience for discrete values where exact equality is the right test.
    convenience init(_ initial: Value,
                     debounce: TimeInterval = 0.08,
                     settle:   TimeInterval = 0.5) {
        self.init(initial, debounce: debounce, settle: settle, equal: { $0 == $1 })
    }
}
