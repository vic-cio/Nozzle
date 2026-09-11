import Darwin
import Foundation

public enum NozzleControlTransportError: Error, LocalizedError, Sendable {
    case appUnavailable(String)
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .appUnavailable(let message), .invalidMessage(let message): return message
        }
    }
}

private let maximumControlMessageSize = 1_048_576

private func socketAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw NozzleControlTransportError.appUnavailable("Control socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
    }
}

private func closeSocket(_ descriptor: Int32) { _ = Darwin.close(descriptor) }

private func suppressBrokenPipeSignal(on descriptor: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}

private func writeMessage(_ data: Data, to descriptor: Int32) throws {
    var message = data
    message.append(10)
    try message.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let count = Darwin.write(descriptor, base.advanced(by: sent), raw.count - sent)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NozzleControlTransportError.appUnavailable("The Nozzle app closed the control connection.") }
            sent += count
        }
    }
}

private func readMessage(from descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while result.count <= maximumControlMessageSize {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        if let newline = buffer[..<count].firstIndex(of: 10) {
            result.append(contentsOf: buffer[..<newline])
            return result
        }
        result.append(contentsOf: buffer[..<count])
    }
    guard result.count <= maximumControlMessageSize else {
        throw NozzleControlTransportError.invalidMessage("Control message exceeded 1 MiB.")
    }
    guard !result.isEmpty else {
        throw NozzleControlTransportError.appUnavailable("The Nozzle app returned no control response.")
    }
    return result
}

public struct NozzleControlClient: Sendable {
    public let socketURL: URL
    public init(socketURL: URL = NozzleControlEndpoint.defaultSocketURL) { self.socketURL = socketURL }

    public func send(_ action: NozzleControlAction) throws -> NozzleControlResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NozzleControlTransportError.appUnavailable("Cannot create a local control socket.") }
        defer { closeSocket(descriptor) }
        suppressBrokenPipeSignal(on: descriptor)
        let connected = try socketAddress(path: socketURL.path) { Darwin.connect(descriptor, $0, $1) }
        guard connected == 0 else {
            throw NozzleControlTransportError.appUnavailable("Nozzle is not running at \(socketURL.path). Open the app and try again.")
        }
        let request = NozzleControlRequest(action: action)
        try writeMessage(try JSONEncoder().encode(request), to: descriptor)
        let response = try JSONDecoder().decode(NozzleControlResponse.self, from: readMessage(from: descriptor))
        guard response.schemaVersion == 1, response.requestID == request.id else {
            throw NozzleControlTransportError.invalidMessage("The Nozzle app returned an incompatible control response.")
        }
        return response
    }
}

public final class NozzleControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (NozzleControlRequest) async -> NozzleControlResponse

    private let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "Nozzle.ControlSocket")
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(socketURL: URL = NozzleControlEndpoint.defaultSocketURL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = chmod(socketURL.deletingLastPathComponent().path, 0o700)
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                defer { closeSocket(probe) }
                let active = (try? socketAddress(path: socketURL.path) { Darwin.connect(probe, $0, $1) }) == 0
                guard !active else {
                    throw NozzleControlTransportError.appUnavailable("Another Nozzle app already owns the control socket.")
                }
            }
            _ = unlink(socketURL.path)
        }
        let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw NozzleControlTransportError.appUnavailable("Cannot create the Nozzle control socket.") }
        suppressBrokenPipeSignal(on: server)
        do {
            let result = try socketAddress(path: socketURL.path) { Darwin.bind(server, $0, $1) }
            guard result == 0, Darwin.listen(server, 8) == 0 else {
                throw NozzleControlTransportError.appUnavailable("Cannot listen on \(socketURL.path): \(String(cString: strerror(errno)))")
            }
            _ = chmod(socketURL.path, 0o600)
            lock.withLock { descriptor = server }
            queue.async { [weak self] in self?.acceptLoop(server: server) }
        } catch {
            closeSocket(server)
            throw error
        }
    }

    public func stop() {
        let open = lock.withLock { () -> Int32 in let value = descriptor; descriptor = -1; return value }
        if open >= 0 { closeSocket(open) }
        _ = unlink(socketURL.path)
    }

    deinit { stop() }

    private func acceptLoop(server: Int32) {
        while lock.withLock({ descriptor == server }) {
            let client = Darwin.accept(server, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            suppressBrokenPipeSignal(on: client)
            Task { [handler] in
                defer { closeSocket(client) }
                var response: NozzleControlResponse
                do {
                    let request = try JSONDecoder().decode(NozzleControlRequest.self, from: readMessage(from: client))
                    guard request.schemaVersion == 1 else {
                        response = .failure(requestID: request.id, code: "incompatible_schema", message: "Control schema version \(request.schemaVersion) is unsupported.")
                        try writeMessage(JSONEncoder().encode(response), to: client)
                        return
                    }
                    response = await handler(request)
                } catch {
                    response = .failure(requestID: nil, code: "invalid_request", message: error.localizedDescription)
                }
                try? writeMessage(JSONEncoder().encode(response), to: client)
            }
        }
    }
}
