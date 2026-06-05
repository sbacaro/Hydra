// Hydra Audio — GPL-3.0
// Local-only WebSocket server (Network.framework). The daemon is the source
// of truth; the app is a client. Bound strictly to 127.0.0.1.

import Foundation
import Network
import HydraCore

final class WebSocketServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "hydra.ws.server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Called on the server queue when a client becomes ready.
    private let onConnect: (NWConnection) -> Void
    /// Called on the server queue for every decoded client message.
    private let onMessage: (WSMessage, NWConnection) -> Void

    init(port: UInt16,
         onConnect: @escaping (NWConnection) -> Void,
         onMessage: @escaping (WSMessage, NWConnection) -> Void) throws {
        self.onConnect = onConnect
        self.onMessage = onMessage

        let params = NWParameters.tcp
        // Loopback only — never exposed to the network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("WebSocket listening on \(Hydra.daemonHost):\(Hydra.daemonPort)")
            case .failed(let error):
                log("Listener failed: \(error) — exiting")
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
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
                self?.queue.async {
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
                        completion: .contentProcessed { _ in })
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

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] hydrad: \(message)")
}
