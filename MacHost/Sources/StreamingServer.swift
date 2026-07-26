import Foundation
import Network
import os

private enum WireMessage {
    static let legacyVideoFrame: UInt8 = 0
    static let displayConfig: UInt8 = 1
    static let touchEvent: UInt8 = 2
    static let ping: UInt8 = 4
    static let pong: UInt8 = 5
    static let videoFrameWithMetadata: UInt8 = 6
    static let keyframeRequest: UInt8 = 7
    static let clientSupportsFrameMetadata: UInt8 = 8
    static let displayRotationRequest: UInt8 = 9
}

private extension NWEndpoint {
    var isLoopback: Bool {
        switch self {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4): return v4.isLoopback
            case .ipv6(let v6): return v6.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?
    var onKeyframeRequested: ((Bool) -> Void)?
    var onRotationRequested: ((Int) -> Void)?
    // Whether host wants to receive touch events from client. Ping/pong is
    // handled regardless. When false, incoming touch frames are dropped
    // immediately without parsing or dispatching to main queue.
    var touchEnabled: Bool = true

    // Wireless auth: when non-nil, non-loopback connections must present this
    // 32-byte token before being allowed to proceed. nil means wireless mode
    // is inactive — non-loopback connections are rejected immediately.
    var expectedAuthToken: Data?
    var onWirelessClientPaired: ((String) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)
    // Frame-path flags. Written on networkQueue (connection lifecycle) and
    // receiveQueue (capability handshake), read on the encoder callback thread
    // for every frame — all three need to agree.
    private struct SendState {
        var connectionReady = false
        var waitingForSyncFrame = false
        var clientSupportsFrameMetadata = false
        // Guards the one-shot startup path on its own, so `connectionReady` can
        // stay false until the display config is actually on the wire.
        var startupClaimed = false
        var inFlightFrames = 0
    }
    private let sendLock = OSAllocatedUnfairLock(initialState: SendState())

    /// Frames handed to the socket but not yet drained before the capture side
    /// should stop feeding the encoder.
    private static let maxInFlightFrames = 2

    /// True while the socket is still working through what it was already given.
    ///
    /// The capture side consults this *before* encoding. Skipping a frame at that
    /// point simply makes the GOP sparser; dropping an already-encoded P-frame
    /// instead would break the client's reference chain and leave it decoding
    /// garbage until the next keyframe. Without this the send queue was unbounded —
    /// on a link slower than the encoder, latency grew until the picture ran
    /// seconds behind and never recovered.
    var isSendBacklogged: Bool {
        sendLock.withLock { $0.inFlightFrames >= Self.maxInFlightFrames }
    }

    // Stats counters. Incremented from the encoder thread and from send
    // completion handlers on networkQueue, drained on frameQueue.
    private struct StatsState {
        var bytesSent: UInt64 = 0
        var frameCount: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var totalFrameAgeNs: UInt64 = 0
        var profiledFrameCount: UInt64 = 0
        var lastStatsTime = DispatchTime.now()
    }
    private let statsLock = OSAllocatedUnfairLock(initialState: StatsState())

    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var isReceiving = false
    private var isStopped = false
    private var inputBuffer = Data()

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        isStopped = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
                tcpOptions.enableFastOpen = true
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    debugLog("TCP Server listening on port \(self.port)")
                case .failed(let error):
                    debugLog("Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.start(queue: networkQueue)
        } catch {
            debugLog("Failed to start server: \(error)")
        }
    }

    private func handleConnection(_ newConnection: NWConnection) {
        debugLog("New connection incoming...")

        // Clean up old connection properly
        if let oldConnection = connection {
            isReceiving = false
            oldConnection.cancel()
        }

        sendLock.withLock { state in
            state.connectionReady = false
            state.clientSupportsFrameMetadata = false
            state.waitingForSyncFrame = true
            state.startupClaimed = false
            state.inFlightFrames = 0
        }
        inputBuffer.removeAll(keepingCapacity: true)
        connection = newConnection
        statsLock.withLock { $0.droppedFrames = 0 }

        connection?.stateUpdateHandler = { [weak self] state in
            debugLog("Connection state: \(state)")
            switch state {
            case .ready:
                self?.onConnectionReady(newConnection)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
                self?.onClientDisconnected?()
            case .cancelled:
                debugLog("Connection cancelled")
                self?.onClientDisconnected?()
            default:
                break
            }
        }

        connection?.start(queue: networkQueue)
    }

    private func onConnectionReady(_ conn: NWConnection) {
        if conn.endpoint.isLoopback {
            debugLog("Client connected via loopback (USB) — skipping auth")
            beginExistingProtocol(on: conn)
            return
        }
        guard let expected = expectedAuthToken else {
            debugLog("Rejecting non-loopback client: wireless mode not active")
            conn.cancel()
            return
        }
        debugLog("Client connected via LAN — running auth handshake")
        runAuthHandshake(connection: conn, expectedToken: expected)
    }

    private func beginExistingProtocol(on conn: NWConnection) {
        startReceivingTouch()

        // Give new clients a short chance to opt in before the first frame.
        // Legacy clients send no capability message, so we continue shortly
        // after this window with the old frame type.
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.finishProtocolStartup(on: conn)
        }
    }

    private func finishProtocolStartup(on conn: NWConnection) {
        guard connection === conn, !isStopped else { return }
        // Claim startup atomically — the 100 ms fallback timer and the capability
        // handshake both race to call this.
        let alreadyStarted = sendLock.withLock { state -> Bool in
            guard !state.startupClaimed else { return true }
            state.startupClaimed = true
            return false
        }
        guard !alreadyStarted else { return }

        debugLog("Client connected - sending display config first")
        // Order matters: the client must have the display config before the first
        // video frame, so the gate only opens once the config is queued.
        sendDisplaySize()
        let metadata = sendLock.withLock { state -> Bool in
            state.connectionReady = true
            return state.clientSupportsFrameMetadata
        }
        debugLog("Connection ready for frames (metadata=\(metadata ? "on" : "off"))")
        onClientConnected?()
    }

    private func runAuthHandshake(connection conn: NWConnection, expectedToken: Data) {
        // Read fixed prefix [magic 4][token 32][name_len 1] = 37 bytes.
        conn.receive(minimumIncompleteLength: HandshakeCodec.fixedPrefixLen,
                     maximumLength: HandshakeCodec.fixedPrefixLen) { [weak self] prefixData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("Auth read error: \(error)")
                conn.cancel()
                return
            }
            guard let prefix = prefixData, prefix.count == HandshakeCodec.fixedPrefixLen else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let prefixBytes = Array(prefix)
            guard Array(prefixBytes[0..<4]) == HandshakeCodec.requestMagic else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let nameLen = Int(prefixBytes[36])
            guard (1...64).contains(nameLen) else {
                self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                return
            }
            // Read variable name.
            conn.receive(minimumIncompleteLength: nameLen, maximumLength: nameLen) { nameData, _, _, error in
                if let error = error {
                    debugLog("Auth name read error: \(error)")
                    conn.cancel()
                    return
                }
                guard let nameData = nameData, nameData.count == nameLen else {
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                    return
                }
                let full = prefix + nameData
                do {
                    let parsed = try HandshakeCodec.parseRequest(full)
                    if WirelessAuth.validate(parsed.token, expected: expectedToken) {
                        debugLog("Wireless auth OK — device: \(parsed.deviceName)")
                        self.sendAuthResponse(conn, status: .ok, thenClose: false)
                        self.onWirelessClientPaired?(parsed.deviceName)
                        self.beginExistingProtocol(on: conn)
                    } else {
                        debugLog("Wireless auth rejected: token mismatch")
                        self.sendAuthResponse(conn, status: .invalidToken, thenClose: true)
                    }
                } catch HandshakeError.invalidMagic {
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                } catch HandshakeError.invalidName {
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                } catch {
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                }
            }
        }
    }

    private func sendAuthResponse(_ conn: NWConnection, status: HandshakeStatus, thenClose: Bool) {
        let bytes = HandshakeCodec.encodeResponse(status: status)
        conn.send(content: bytes, completion: .contentProcessed { _ in
            if thenClose {
                debugLog("Auth rejected (\(status)), closing connection")
                conn.cancel()
            }
        })
    }

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
    }

    /// Update rotation and send to connected client
    func updateRotation(_ rotation: Int) {
        self.rotation = rotation
        sendDisplaySize() // Re-send display config with new rotation
    }

    func sendDisplaySize() {
        guard let connection = connection else { return }

        var data = Data()
        data.append(WireMessage.displayConfig) // Type: Display size + rotation
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(rotation).bigEndian) { Data($0) })

        connection.send(content: data, completion: .contentProcessed { _ in })
        debugLog("Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°")
    }

    private func startReceivingTouch() {
        guard !isReceiving else {
            debugLog("Already receiving touch events")
            return
        }
        isReceiving = true
        debugLog("Starting input receive loop... (touch=\(touchEnabled ? "on" : "off"))")

        // Use loop-based pattern instead of recursion to prevent stack overflow
        receiveQueue.async { [weak self] in
            self?.touchReceiveLoop()
        }
    }

    private func touchReceiveLoop() {
        guard let connection = connection, isReceiving, !isStopped else {
            isReceiving = false
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isReceiving, !self.isStopped else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                self.inputBuffer.removeAll(keepingCapacity: true)
                return
            }

            if let data = data, !data.isEmpty {
                self.inputBuffer.append(data)
                self.processInputBuffer(connection: connection)
            }

            self.receiveQueue.async {
                self.touchReceiveLoop()
            }
        }
    }

    private func processInputBuffer(connection: NWConnection) {
        while let msgType = inputBuffer.first {
            switch msgType {
            case WireMessage.touchEvent:
                // Touch event: 1 type + 1 pointerCount + N*(4x+4y) + 4 action.
                // 1 finger: 14 bytes, 2 fingers: 22 bytes.
                guard inputBuffer.count >= 2 else { return }

                let pointerCount = Int(inputByte(at: 1))
                guard pointerCount == 1 || pointerCount == 2 else {
                    debugLog("Invalid touch pointer count: \(pointerCount)")
                    consumeInputBytes(1)
                    continue
                }

                let expectedSize = 2 + pointerCount * 8 + 4
                guard inputBuffer.count >= expectedSize else { return }

                let message = Data(inputBuffer.prefix(expectedSize))
                consumeInputBytes(expectedSize)

                // Drop early if host has touch disabled, after consuming exactly
                // this touch frame so coalesced ping/keyframe messages survive.
                if touchEnabled {
                    handleTouchMessage(message, pointerCount: pointerCount)
                }

            case WireMessage.ping:
                // Ping from client: echo back as pong (type=5) with client's timestamp.
                guard inputBuffer.count >= 9 else { return }

                let clientTimestamp = Data(inputBuffer.dropFirst().prefix(8))
                consumeInputBytes(9)

                var pong = Data(capacity: 9)
                pong.append(WireMessage.pong) // Type: Pong
                pong.append(clientTimestamp)
                connection.send(content: pong, completion: .contentProcessed { _ in })

            case WireMessage.keyframeRequest:
                // Keyframe request from Android decoder. The client sends a
                // two-byte message: type + flags.
                guard inputBuffer.count >= 2 else { return }

                let flags = inputByte(at: 1)
                consumeInputBytes(2)
                onKeyframeRequested?((flags & 1) != 0)

            case WireMessage.clientSupportsFrameMetadata:
                // One-byte opt-in from newer clients. Keeping this payload-free
                // lets older hosts safely ignore it without misaligning input.
                consumeInputBytes(1)
                let wasAdvertised = sendLock.withLock { state -> Bool in
                    let previous = state.clientSupportsFrameMetadata
                    state.clientSupportsFrameMetadata = true
                    return previous
                }
                if !wasAdvertised {
                    debugLog("Client supports video frame metadata")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.displayRotationRequest:
                // Android client rotation request: type + Int32 little-endian degrees.
                guard inputBuffer.count >= 5 else { return }

                let requested = inputBuffer.withUnsafeBytes {
                    Int($0.loadUnaligned(fromByteOffset: 1, as: Int32.self))
                }
                consumeInputBytes(5)

                guard [0, 90, 180, 270].contains(requested) else {
                    debugLog("Invalid display rotation requested: \(requested)")
                    continue
                }
                debugLog("Display rotation requested by client: \(requested)°")
                DispatchQueue.main.async {
                    self.onRotationRequested?(requested)
                }

            default:
                debugLog("Unknown client input type: \(msgType)")
                consumeInputBytes(1)
            }
        }
    }

    private func handleTouchMessage(_ data: Data, pointerCount: Int) {
        let x1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Float.self) }
        let y1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: Float.self) }

        var x2: Float = 0
        var y2: Float = 0
        if pointerCount >= 2 {
            x2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Float.self) }
            y2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: Float.self) }
        }

        let actionOffset = 2 + pointerCount * 8
        let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self) }

        DispatchQueue.main.async {
            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
        }
    }

    private func inputByte(at offset: Int) -> UInt8 {
        inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: offset)]
    }

    private func consumeInputBytes(_ count: Int) {
        let endIndex = inputBuffer.index(inputBuffer.startIndex, offsetBy: count)
        inputBuffer.removeSubrange(inputBuffer.startIndex..<endIndex)
    }

    private enum FrameGate {
        case notReady
        case awaitingKeyframe
        case send(useMetadata: Bool, isFirstKeyframe: Bool)
    }

    /// Takes the encoded frame `inout` because the wire header is patched directly
    /// into the scratch room `VideoEncoder` reserved at the front. Passing by value
    /// would leave the buffer multiply-referenced and turn that patch into a
    /// full copy-on-write duplication of every frame.
    func sendFrame(_ data: inout Data, timestamp: UInt64, isKeyframe: Bool = false) {
        guard let connection = connection, !isStopped else { return }

        // With short-GOP encoding, a fresh client must start on a keyframe —
        // sending P-frames before the first IDR would feed garbage to its decoder.
        let gate: FrameGate = sendLock.withLock { state in
            guard state.connectionReady else { return .notReady }
            guard state.waitingForSyncFrame else {
                return .send(useMetadata: state.clientSupportsFrameMetadata, isFirstKeyframe: false)
            }
            guard isKeyframe else { return .awaitingKeyframe }
            state.waitingForSyncFrame = false
            return .send(useMetadata: state.clientSupportsFrameMetadata, isFirstKeyframe: true)
        }

        let useMetadata: Bool
        switch gate {
        case .notReady:
            return
        case .awaitingKeyframe:
            statsLock.withLock { $0.droppedFrames += 1 }
            return
        case let .send(metadata, isFirstKeyframe):
            if isFirstKeyframe { debugLog("First keyframe sent to new client") }
            useMetadata = metadata
        }

        let payloadCount = data.count - VideoEncoder.headerRoom
        let packet = makeFramePacket(&data, timestamp: timestamp, isKeyframe: isKeyframe, useMetadata: useMetadata)

        // No frame-age dropping or backpressure — send everything immediately.
        // The encode queue depth limit (2 pending) in ScreenCapture handles flow control.
        frameQueue.async { [weak self] in
            guard let self = self else { return }

            self.sendLock.withLock { $0.inFlightFrames += 1 }
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.sendLock.withLock { $0.inFlightFrames = max(0, $0.inFlightFrames - 1) }
                if error != nil {
                    self.statsLock.withLock { $0.droppedFrames += 1 }
                }
            })

            // Track frame age at send time for pipeline profiling
            let sendAge = DispatchTime.now().uptimeNanoseconds - timestamp
            self.updateStats(bytes: payloadCount, frameAgeNs: sendAge)
        }
    }

    /// Writes the wire header into the scratch room at the front of `data` and
    /// returns the slice to put on the wire. No payload bytes are moved.
    private func makeFramePacket(
        _ data: inout Data,
        timestamp: UInt64,
        isKeyframe: Bool,
        useMetadata: Bool
    ) -> Data {
        let room = VideoEncoder.headerRoom
        let payloadCount = UInt32(truncatingIfNeeded: data.count - room)

        if useMetadata {
            // [type 1][size 4][keyframe 1][capture timestamp 8] fills the room exactly.
            data.withUnsafeMutableBytes { raw in
                raw[0] = WireMessage.videoFrameWithMetadata
                Self.writeBigEndian(payloadCount, to: raw, at: 1)
                raw[5] = isKeyframe ? 1 : 0
                Self.writeBigEndian(timestamp, to: raw, at: 6)
            }
            return data
        }

        // Keep legacy frame type 0 for clients that do not advertise metadata
        // support; remove after legacy clients age out. Its shorter header goes at
        // the tail of the room so the unused leading bytes can be sliced off.
        let offset = room - 5
        data.withUnsafeMutableBytes { raw in
            raw[offset] = WireMessage.legacyVideoFrame
            Self.writeBigEndian(payloadCount, to: raw, at: offset + 1)
        }
        return data[(data.startIndex + offset)...]
    }

    // Byte-wise so the writes stay valid at unaligned offsets inside the header room.
    private static func writeBigEndian(_ value: UInt32, to raw: UnsafeMutableRawBufferPointer, at offset: Int) {
        raw[offset] = UInt8(truncatingIfNeeded: value >> 24)
        raw[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        raw[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        raw[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeBigEndian(_ value: UInt64, to raw: UnsafeMutableRawBufferPointer, at offset: Int) {
        for index in 0..<8 {
            raw[offset + index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index))
        }
    }

    private struct StatsSnapshot {
        let fps: Double
        let mbps: Double
        let avgAgeMs: Double?
        let dropped: UInt64
    }

    private func updateStats(bytes: Int, frameAgeNs: UInt64 = 0) {
        let now = DispatchTime.now()

        let snapshot: StatsSnapshot? = statsLock.withLock { state in
            state.bytesSent += UInt64(bytes)
            state.frameCount += 1
            if frameAgeNs > 0 {
                state.totalFrameAgeNs += frameAgeNs
                state.profiledFrameCount += 1
            }

            let elapsed = Double(now.uptimeNanoseconds - state.lastStatsTime.uptimeNanoseconds) / 1_000_000_000
            guard elapsed >= 1.0 else { return nil }

            let snapshot = StatsSnapshot(
                fps: Double(state.frameCount) / elapsed,
                mbps: Double(state.bytesSent * 8) / elapsed / 1_000_000,
                avgAgeMs: state.profiledFrameCount > 0
                    ? Double(state.totalFrameAgeNs) / Double(state.profiledFrameCount) / 1_000_000.0
                    : nil,
                dropped: state.droppedFrames
            )

            state.bytesSent = 0
            state.frameCount = 0
            state.droppedFrames = 0
            state.totalFrameAgeNs = 0
            state.profiledFrameCount = 0
            state.lastStatsTime = now
            return snapshot
        }

        // Publish outside the lock — onStats hops to the UI and must not block the frame path.
        guard let snapshot else { return }
        onStats?(snapshot.fps, snapshot.mbps)

        // Log pipeline latency profile
        if let avgAgeMs = snapshot.avgAgeMs {
            debugLog("Pipeline: \(String(format: "%.1f", snapshot.fps))fps, \(String(format: "%.1f", snapshot.mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(snapshot.dropped)")
        }
    }

    func stop() {
        isStopped = true
        isReceiving = false

        // Wait for pending operations before cancelling
        frameQueue.sync {}
        receiveQueue.sync {}

        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }
}
