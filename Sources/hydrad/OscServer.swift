// Hydra Audio — GPL-3.0
// OSC remote control (receive-only UDP) — scenes and recordings from
// consoles, TouchOSC, Bitfocus Companion / Stream Deck, show automation.
// Address space documented in HydraCore/Osc.swift. Off by default
// (Settings → Control); restarted live when the config changes.

import Foundation
import Network
import HydraCore

final class OscServer {

    private let queue = DispatchQueue(label: "hydra.osc")
    private var listener: NWListener?
    private var port: Int = 0
    /// Dispatch target — called on `queue`.
    var onMessage: ((OSCMessage) -> Void)?

    func apply(enabled: Bool, port newPort: Int) {
        queue.sync {
            if !enabled || newPort != port {
                listener?.cancel()
                listener = nil
                port = 0
            }
            guard enabled, listener == nil,
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: newPort)) else { return }
            do {
                let listener = try NWListener(using: .udp, on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    connection.start(queue: self.queue)
                    self.receive(on: connection)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        log("OSC: listening on UDP \(newPort)")
                    case .failed(let error):
                        log("OSC: listener failed on \(newPort): \(error)")
                        EventCenter.shared.emit(.error, "OSC could not use port \(newPort) — is it taken?")
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
                self.port = newPort
            } catch {
                log("OSC: could not open UDP \(newPort): \(error)")
                EventCenter.shared.emit(.error, "OSC could not open port \(newPort).")
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content {
                for message in OSCParser.parse(content) {
                    self.onMessage?(message)
                }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }
}
