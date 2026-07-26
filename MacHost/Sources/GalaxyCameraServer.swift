import Foundation
import Network

final class GalaxyCameraServer {
    static let defaultPort: UInt16 = 54323
    static let latestFrameURL = URL(fileURLWithPath: "/tmp/sidescreen-galaxy-camera.jpg")

    private let port: UInt16
    private let queue = DispatchQueue(label: "galaxyCameraServer", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var inputBuffer = Data()
    private var framesReceived: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var lastFrameWriteTime = DispatchTime.now()
    private let frameLock = NSLock()
    private var latestFrame: Data?

    init(port: UInt16 = GalaxyCameraServer.defaultPort) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener?.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    debugLog("Galaxy camera server listening on port \(self.port)")
                case .failed(let error):
                    debugLog("Galaxy camera server failed: \(error)")
                default:
                    break
                }
            }
            listener?.start(queue: queue)
        } catch {
            debugLog("Failed to start Galaxy camera server: \(error)")
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        inputBuffer.removeAll(keepingCapacity: false)
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    func latestFrameData() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    private func accept(_ newConnection: NWConnection) {
        debugLog("Galaxy camera connection incoming")
        connection?.cancel()
        inputBuffer.removeAll(keepingCapacity: true)
        framesReceived = 0
        bytesReceived = 0
        lastStatsTime = DispatchTime.now()

        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                debugLog("Galaxy camera connected")
                self?.receiveLoop()
            case .failed(let error):
                debugLog("Galaxy camera connection failed: \(error)")
            case .cancelled:
                debugLog("Galaxy camera disconnected")
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inputBuffer.append(data)
                self.processInputBuffer()
            }
            if let error {
                debugLog("Galaxy camera receive error: \(error)")
                return
            }
            if isComplete {
                debugLog("Galaxy camera stream completed")
                return
            }
            self.receiveLoop()
        }
    }

    private func processInputBuffer() {
        while inputBuffer.count >= 4 {
            let length = inputBuffer.withUnsafeBytes { rawBuffer -> UInt32 in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                return (UInt32(bytes[0]) << 24) |
                    (UInt32(bytes[1]) << 16) |
                    (UInt32(bytes[2]) << 8) |
                    UInt32(bytes[3])
            }

            guard length > 0, length <= 8 * 1024 * 1024 else {
                debugLog("Galaxy camera invalid frame length: \(length)")
                connection?.cancel()
                return
            }

            let frameLength = Int(length)
            guard inputBuffer.count >= 4 + frameLength else { return }

            let frame = inputBuffer.subdata(in: 4..<(4 + frameLength))
            inputBuffer.removeSubrange(0..<(4 + frameLength))
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: Data) {
        framesReceived += 1
        bytesReceived += UInt64(frame.count)
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()

        let now = DispatchTime.now()
        let writeElapsed = Double(now.uptimeNanoseconds - lastFrameWriteTime.uptimeNanoseconds) / 1_000_000_000
        if writeElapsed >= 0.2 {
            lastFrameWriteTime = now
            do {
                try frame.write(to: GalaxyCameraServer.latestFrameURL, options: .atomic)
            } catch {
                debugLog("Galaxy camera latest frame write failed: \(error)")
            }
        }

        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed >= 1.0 {
            let fps = Double(framesReceived) / elapsed
            let mbps = (Double(bytesReceived) * 8.0 / 1_000_000.0) / elapsed
            debugLog(String(format: "Galaxy camera: %.1ffps, %.1fMbps", fps, mbps))
            framesReceived = 0
            bytesReceived = 0
            lastStatsTime = now
        }
    }
}
