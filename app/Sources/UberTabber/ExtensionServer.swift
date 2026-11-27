import Foundation
import Network

/// WebSocket server on 127.0.0.1 that the Chrome extension connects to.
/// Messages are JSON objects in both directions.
final class ExtensionServer {
    static let port: NWEndpoint.Port = 47821

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    var onMessage: (([String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onRejected: ((_ origin: String) -> Void)?
    var isConnected: Bool { !connections.isEmpty }

    func start() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Any web page can open a WebSocket to localhost, so only accept the
        // extension. Pages can't fake the Origin header.
        ws.setClientRequestHandler(.main) { [weak self] _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let ok = origin.hasPrefix("chrome-extension://")
            if !ok { self?.onRejected?(origin) }
            return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("Extension server failed: \(error)") }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        for c in connections {
            c.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    private func accept(_ c: NWConnection) {
        connections.append(c)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready: self.onConnectionChange?(true)
            case .failed, .cancelled: self.drop(c)
            default: break
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            // No WebSocket metadata means the stream ended (or the handshake
            // was rejected); receiving again would spin.
            if error != nil || meta == nil || meta?.opcode == .close {
                self.drop(c)
                return
            }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.onMessage?(obj)
            }
            self.receive(on: c)
        }
    }

    private func drop(_ c: NWConnection) {
        guard let i = connections.firstIndex(where: { $0 === c }) else { return }
        connections.remove(at: i)
        c.cancel()
        onConnectionChange?(isConnected)
    }
}
