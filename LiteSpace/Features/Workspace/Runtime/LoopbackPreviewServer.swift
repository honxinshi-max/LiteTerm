import Foundation
import NIOCore
import NIOHTTP1
import NIOTransportServices

public struct LoopbackServerLease: Sendable {
    public let generation: UInt64
    public let host: String
    public let port: Int
    public let listenerID: UUID
    public let runtimeID: UUID
    public let secretHandle: UUID
    private let secret: Data

    init(
        generation: UInt64,
        port: Int,
        listenerID: UUID,
        runtimeID: UUID,
        secretHandle: UUID,
        secret: Data
    ) {
        self.generation = generation
        host = "127.0.0.1"
        self.port = port
        self.listenerID = listenerID
        self.runtimeID = runtimeID
        self.secretHandle = secretHandle
        self.secret = secret
    }

    public var secretBitCount: Int { secret.count * 8 }

    var authenticationHeaderValue: String {
        secret.map { String(format: "%02x", $0) }.joined()
    }

    public func authenticatedBootstrapURL(relativePath: String) throws -> URL {
        try PreviewPathPolicy.validate(relativePath, allowEmpty: true)
        var url = URL(string: "http://127.0.0.1:\(port)/")!
        url.appendPathComponent("__litespace")
        url.appendPathComponent(authenticationHeaderValue)
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    func authenticatedHealthURL(relativePath: String) throws -> URL {
        try PreviewPathPolicy.validate(relativePath, allowEmpty: true)
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = relativePath.isEmpty ? "/" : "/\(relativePath)"
        guard let url = components.url else { throw PreviewRuntimeError.invalidPath }
        return url
    }
}

public actor LoopbackPreviewServer {
    private var group: NIOTSEventLoopGroup?
    private var listeningChannel: (any Channel)?

    public init() {}

    public var isRunning: Bool {
        listeningChannel?.isActive == true
    }

    public func start(
        generation: UInt64,
        runtimeID: UUID,
        source: PreviewResponseSource
    ) throws -> LoopbackServerLease {
        guard listeningChannel == nil, group == nil else {
            throw PreviewRuntimeError.alreadyRunning
        }

        var random = SystemRandomNumberGenerator()
        let secret = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        let serverContext = LoopbackServerContext(
            generation: generation,
            secretHex: secretHex,
            source: source
        )
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
        do {
            let channel = try NIOTSListenerBootstrap(group: eventLoopGroup)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(LoopbackHTTPHandler(serverContext: serverContext))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            guard let port = channel.localAddress?.port, (1...65_535).contains(port) else {
                try channel.close().wait()
                try eventLoopGroup.syncShutdownGracefully()
                throw PreviewRuntimeError.invalidPort
            }
            serverContext.setBoundPort(port)
            group = eventLoopGroup
            listeningChannel = channel
            return LoopbackServerLease(
                generation: generation,
                port: port,
                listenerID: UUID(),
                runtimeID: runtimeID,
                secretHandle: UUID(),
                secret: secret
            )
        } catch {
            if group == nil {
                try? eventLoopGroup.syncShutdownGracefully()
            }
            throw error
        }
    }

    public func stop() {
        let channel = listeningChannel
        let eventLoopGroup = group
        listeningChannel = nil
        group = nil
        try? channel?.close().wait()
        try? eventLoopGroup?.syncShutdownGracefully()
    }
}
