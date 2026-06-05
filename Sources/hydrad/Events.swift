// Hydra Audio — GPL-3.0
// Event center: managers emit user-relevant events (drops, blocks, failures);
// the daemon keeps a short ring and pushes them live to clients (Section 6,
// "event log" — discreet notices, never modal interruptions).

import Foundation
import HydraCore

final class EventCenter {
    static let shared = EventCenter()

    private let queue = DispatchQueue(label: "hydra.events")
    private var buffer: [HydraEvent] = []
    private let capacity = 50
    /// Wired by main to broadcast each new event.
    var onEvent: ((HydraEvent) -> Void)?

    func emit(_ kind: HydraEvent.Kind, _ message: String) {
        let event = HydraEvent(kind: kind, message: message)
        queue.sync {
            buffer.append(event)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }
        log("Event [\(kind.rawValue)]: \(message)")
        onEvent?(event)
    }

    func recent() -> [HydraEvent] {
        queue.sync { buffer }
    }
}
