// Hydra Audio — GPL-3.0
// Local-only WebSocket server (Network.framework). The daemon is the source
// of truth; the app is a client. Bound strictly to 127.0.0.1.

import Foundation
import Network
import HydraCore

final class WebSocketServer: @unchecked Sendable {

    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hydra.ws.server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Called on the server queue when a client becomes ready.
    private let onConnect: (NWConnection) -> Void
    /// Called on the server queue for every decoded client message.
    private let onMessage: (WSMessage, NWConnection) -> Void

    init(port: UInt16,
         onConnect: @escaping (NWConnection) -> Void,
         onMessage: @escaping (WSMessage, NWConnection) -> Void) throws {
        self.port = port
        self.onConnect = onConnect
        self.onMessage = onMessage
        self.listener = try NWListener(using: WebSocketServer.makeParams(port: port))
    }

    /// Loopback-only TCP + WebSocket parameters (never exposed to the network).
    private static func makeParams(port: UInt16) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return params
    }

    func start() {
        startListener()
    }

    private func startListener() {
        guard let listener else { return }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log("WebSocket listening on \(Hydra.daemonHost):\(Hydra.daemonPort)")
            case .failed(let error):
                // The control socket failing must NOT take down the audio engine.
                // Keep audio alive AND retry binding — e.g. the port may be held
                // briefly by a previous daemon instance across a relaunch.
                log("Listener failed: \(error) — retrying in 2s (audio engine kept alive)")
                self?.scheduleListenerRestart()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func scheduleListenerRestart() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = try? NWListener(using: WebSocketServer.makeParams(port: self.port))
            self.startListener()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        log("Client connected (\(connections.count) total)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onConnect(connection)
            case .failed, .cancelled:
                self?.queue.async { [weak self] in
                    self?.connections.removeValue(forKey: key)
                    log("Client disconnected")
                }
            default:
                break
            }
        }
        receiveLoop(connection)
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                log("Receive error: \(error)")
                connection.cancel()
                return
            }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.handle(text, from: connection)
            }
            self.receiveLoop(connection)
        }
    }

    private func handle(_ text: String, from connection: NWConnection) {
        do {
            onMessage(try WSMessage.decode(from: text), connection)
        } catch {
            log("Bad message ignored: \(error)")
        }
    }

    // MARK: - Sending

    /// True if at least one client is connected (used to skip idle broadcasts).
    var hasClients: Bool {
        queue.sync { !connections.isEmpty }
    }

    func send(_ message: WSMessage, to connection: NWConnection) {
        guard let text = try? message.encodedString() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8),
                        contentContext: context,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            // A send failure means the peer is gone (half-open socket). Prune it
            // so broadcasts stop targeting a dead client and state can resync.
            guard let self, let error else { return }
            log("Send failed: \(error) — dropping client")
            connection.cancel()
            self.queue.async {
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        })
    }

    /// Broadcast to every connected client (used when state changes).
    func broadcast(_ message: WSMessage) {
        queue.async {
            for connection in self.connections.values {
                self.send(message, to: connection)
            }
        }
    }
}

/// Daemon-wide log entry point. Routes to Apple's unified logging (persistent,
/// queryable, survives a relaunch) under subsystem "audio.hydra" / category
/// "daemon". Also echoes to stdout so `hydrad` run in a terminal stays readable.
/// View later with:  log show --predicate 'subsystem == "audio.hydra"' --info
func log(_ message: String) {
    HydraLog.daemon.log("\(message, privacy: .public)")
    print("hydrad: \(message)")
}
