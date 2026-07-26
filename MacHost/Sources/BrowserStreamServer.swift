import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Network
import os

final class BrowserStreamServer {
    /// Target gap between browser frames. The MJPEG viewer used to be pinned at a
    /// flat 10 fps because nothing stopped a slow client from queueing frames
    /// forever; with per-client backpressure below, a weak link now sheds frames on
    /// its own and the cap can sit much closer to the native path.
    private static let targetFrameIntervalNanos: UInt64 = 33_000_000  // ~30 fps
    /// Chunks allowed outstanding on one connection before it starts getting
    /// skipped. NWConnection buffers without bound, so without this a client on bad
    /// WiFi accumulates ever-growing latency instead of dropping frames.
    private static let maxInFlightChunks = 2
    /// `/latest.jpg` holds no persistent connection, so a recent request keeps the
    /// encoder warm briefly rather than letting the cached frame go stale forever.
    private static let stillRequestWindowNanos: UInt64 = 2_000_000_000

    private struct Client {
        let connection: NWConnection
        var inFlight: Int = 0
    }

    /// Read by the capture thread, which must not touch `clients` (networkQueue-confined).
    private struct DemandState {
        var clientCount = 0
        var lastStillRequestNanos: UInt64 = 0
    }

    private let port: UInt16
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let demandState = OSAllocatedUnfairLock(initialState: DemandState())
    private let networkQueue = DispatchQueue(label: "browserStream.network", qos: .userInteractive)
    private let jpegQueue = DispatchQueue(label: "browserStream.jpeg", qos: .userInitiated)
    private let ciContext = CIContext()
    private let jpegColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let maxJPEGDimension: CGFloat = 2400
    private var isStopped = false
    private var latestJPEG: Data?
    private var lastJPEGNanos: UInt64 = 0

    var expectedAuthToken: Data?
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?

    private struct RetainedPixelBuffer: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer

        init(_ pixelBuffer: CVPixelBuffer) {
            pointer = Unmanaged.passRetained(pixelBuffer).toOpaque()
        }

        func take() -> CVPixelBuffer {
            Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeRetainedValue()
        }
    }

    init(port: UInt16) {
        self.port = port
    }

    static func webPort(for streamPort: UInt16) -> UInt16 {
        streamPort < UInt16.max ? streamPort + 1 : streamPort - 1
    }

    static func buildURL(host: String, streamPort: UInt16, token: Data) -> String {
        let tokenString = PairingURL.base64URLEncode(token)
        return "http://\(host):\(webPort(for: streamPort))/?t=\(tokenString)"
    }

    func start() {
        isStopped = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener?.stateUpdateHandler = { state in
                if case .ready = state {
                    debugLog("Browser server listening on port \(self.port)")
                }
            }
            listener?.start(queue: networkQueue)
        } catch {
            debugLog("Browser server failed to start: \(error)")
        }
    }

    func updateFrame(pixelBuffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds

        // Nobody is watching: skip the whole JPEG pipeline. A USB-only session never
        // opens a browser client, and encoding for an empty broadcast is pure waste.
        let wanted = demandState.withLock { state in
            state.clientCount > 0 || now &- state.lastStillRequestNanos < Self.stillRequestWindowNanos
        }
        guard wanted else { return }

        guard now &- lastJPEGNanos >= Self.targetFrameIntervalNanos else { return }
        lastJPEGNanos = now

        let retainedPixelBuffer = RetainedPixelBuffer(pixelBuffer)
        jpegQueue.async { [weak self] in
            let pixelBuffer = retainedPixelBuffer.take()
            guard let self, !self.isStopped else { return }
            guard let jpeg = self.makeJPEG(from: pixelBuffer) else { return }

            self.networkQueue.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.latestJPEG = jpeg
                self.broadcast(jpeg)
            }
        }
    }

    func stop() {
        isStopped = true
        networkQueue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values {
                client.connection.cancel()
            }
            self.clients.removeAll()
            self.publishClientCount()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        var buffer = Data()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state {
                self.remove(connection)
            } else if case .cancelled = state {
                self.remove(connection)
            }
        }

        connection.start(queue: networkQueue)

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                if let data {
                    buffer.append(data)
                }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.route(connection, requestData: buffer)
                } else if buffer.count > 8192 {
                    self.sendText("Bad Request", status: "400 Bad Request", on: connection)
                } else {
                    receiveMore()
                }
            }
        }

        receiveMore()
    }

    private func route(_ connection: NWConnection, requestData: Data) {
        guard let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.split(separator: "\n", maxSplits: 1).first else {
            sendText("Bad Request", status: "400 Bad Request", on: connection)
            return
        }

        let parts = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2 else {
            sendText("Bad Request", status: "400 Bad Request", on: connection)
            return
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let components = URLComponents(string: "http://localhost\(rawPath)")
        let path = components?.path ?? rawPath

        guard method == "GET" else {
            sendText("Method Not Allowed", status: "405 Method Not Allowed", on: connection)
            return
        }

        switch path {
        case "/":
            guard isAuthorized(components) else {
                sendText("Pairing token required.", status: "403 Forbidden", on: connection)
                return
            }
            sendHTML(token: tokenQueryValue(components) ?? "", on: connection)
        case "/stream.mjpg":
            guard isAuthorized(components) else {
                sendText("Pairing token required.", status: "403 Forbidden", on: connection)
                return
            }
            startMJPEG(on: connection)
        case "/latest.jpg":
            guard isAuthorized(components) else {
                sendText("Pairing token required.", status: "403 Forbidden", on: connection)
                return
            }
            // This endpoint holds no connection, so record the interest explicitly —
            // otherwise the encoder stays idle and the cached frame never refreshes.
            let now = DispatchTime.now().uptimeNanoseconds
            demandState.withLock { $0.lastStillRequestNanos = now }
            guard let latestJPEG else {
                sendText("No frame yet.", status: "404 Not Found", on: connection)
                return
            }
            sendBytes(latestJPEG, contentType: "image/jpeg", on: connection)
        case "/touch":
            guard isAuthorized(components) else {
                sendText("Pairing token required.", status: "403 Forbidden", on: connection)
                return
            }
            handleTouch(components)
            sendText("", status: "204 No Content", on: connection)
        case "/health":
            sendText("ok", contentType: "text/plain; charset=utf-8", on: connection)
        default:
            sendText("Not Found", status: "404 Not Found", on: connection)
        }
    }

    private func startMJPEG(on connection: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: multipart/x-mixed-replace; boundary=frame\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        let id = UUID()
        clients[id] = Client(connection: connection)
        publishClientCount()
        if let latestJPEG {
            sendJPEGChunk(latestJPEG, toClientWith: id)
        }
    }

    /// `clients` is networkQueue-confined; the capture thread reads this mirror instead.
    private func publishClientCount() {
        let count = clients.count
        demandState.withLock { $0.clientCount = count }
    }

    private func sendHTML(token: String, on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html lang="ko">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>Side Screen Browser</title>
          <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #050608; color: #f4f6f8; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
            #stage { position: fixed; inset: 0; display: grid; place-items: center; background: #000; touch-action: none; }
            #screen { width: 100vw; height: 100svh; object-fit: contain; background: #000; touch-action: none; user-select: none; -webkit-user-select: none; }
            #bar { position: fixed; left: max(12px, env(safe-area-inset-left)); right: max(12px, env(safe-area-inset-right)); bottom: max(12px, env(safe-area-inset-bottom)); display: flex; gap: 8px; align-items: center; justify-content: space-between; padding: 10px 12px; border-radius: 8px; background: rgba(10,12,15,.72); backdrop-filter: blur(16px); font-size: 13px; transition: opacity .2s ease, transform .2s ease; }
            #bar.hidden { opacity: 0; pointer-events: none; transform: translateY(14px); }
            button { min-height: 36px; border: 0; border-radius: 8px; background: #38d996; color: #06120c; font-weight: 800; padding: 0 12px; }
            #app { background: #4aa3ff; color: #04111f; }
            .muted { color: #aab2bf; }
          </style>
        </head>
        <body>
          <main id="stage">
            <img id="screen" src="/stream.mjpg?t=\(escapeHTML(token))" alt="Side Screen stream">
          </main>
          <div id="bar">
            <span><strong>Side Screen</strong> <span class="muted">browser mode</span></span>
            <span>
              <button id="app">앱으로 연결</button>
              <button id="full">전체화면</button>
            </span>
          </div>
          <script>
            const token = new URLSearchParams(location.search).get("t") || "\(escapeJavaScript(token))";
            const img = document.getElementById("screen");
            const bar = document.getElementById("bar");
            const full = document.getElementById("full");
            const app = document.getElementById("app");
            let lastMove = 0;
            let hideBarTimer;
            function nativeAppURL() {
              const webPort = Number(location.port || "54322");
              const streamPort = webPort > 1 ? webPort - 1 : 54321;
              return `sidescreen://${location.hostname}:${streamPort}/pair?t=${encodeURIComponent(token)}&name=${encodeURIComponent("Side Screen")}`;
            }
            function scheduleBarHide(delay = 2500) {
              clearTimeout(hideBarTimer);
              hideBarTimer = setTimeout(() => bar.classList.add("hidden"), delay);
            }
            scheduleBarHide();
            function imageBounds() {
              const rect = img.getBoundingClientRect();
              const naturalWidth = img.naturalWidth || rect.width;
              const naturalHeight = img.naturalHeight || rect.height;
              const naturalRatio = naturalWidth / naturalHeight;
              const viewRatio = rect.width / rect.height;
              let left = rect.left, top = rect.top, width = rect.width, height = rect.height;
              if (viewRatio > naturalRatio) {
                width = height * naturalRatio;
                left += (rect.width - width) / 2;
              } else {
                height = width / naturalRatio;
                top += (rect.height - height) / 2;
              }
              return { left, top, width, height };
            }
            function sendTouch(event, action) {
              const now = performance.now();
              if (action === 1 && now - lastMove < 33) return;
              lastMove = now;
              const rect = imageBounds();
              const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
              const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
              fetch(`/touch?t=${encodeURIComponent(token)}&x=${x.toFixed(5)}&y=${y.toFixed(5)}&a=${action}&n=1`, { keepalive: true }).catch(() => {});
              event.preventDefault();
            }
            img.addEventListener("pointerdown", event => sendTouch(event, 0), { passive: false });
            img.addEventListener("pointermove", event => sendTouch(event, 1), { passive: false });
            img.addEventListener("pointerup", event => sendTouch(event, 2), { passive: false });
            img.addEventListener("pointercancel", event => sendTouch(event, 2), { passive: false });
            app.addEventListener("click", () => {
              location.href = nativeAppURL();
              scheduleBarHide(1000);
            });
            full.addEventListener("click", async () => {
              if (document.fullscreenElement) await document.exitFullscreen();
              else await document.documentElement.requestFullscreen();
              scheduleBarHide(500);
            });
            document.addEventListener("fullscreenchange", () => {
              full.textContent = document.fullscreenElement ? "전체화면 해제" : "전체화면";
              scheduleBarHide(document.fullscreenElement ? 300 : 1800);
            });
          </script>
        </body>
        </html>
        """
        sendBytes(Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func handleTouch(_ components: URLComponents?) {
        let query = queryMap(components)
        guard let x = Float(query["x"] ?? ""),
              let y = Float(query["y"] ?? ""),
              let action = Int(query["a"] ?? "") else {
            return
        }
        let pointerCount = Int(query["n"] ?? "1") ?? 1
        let x2 = Float(query["x2"] ?? "0") ?? 0
        let y2 = Float(query["y2"] ?? "0") ?? 0
        DispatchQueue.main.async { [weak self] in
            self?.onTouchEvent?(x, y, action, pointerCount, x2, y2)
        }
    }

    private func broadcast(_ jpeg: Data) {
        for (id, client) in clients where client.inFlight < Self.maxInFlightChunks {
            sendJPEGChunk(jpeg, toClientWith: id)
        }
    }

    private func sendJPEGChunk(_ jpeg: Data, toClientWith id: UUID) {
        guard var client = clients[id] else { return }

        var chunk = Data(capacity: 96 + jpeg.count)
        chunk.append(Data("\r\n--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8))
        chunk.append(jpeg)

        client.inFlight += 1
        clients[id] = client

        // Completion runs on the queue the connection was started on (networkQueue),
        // which is also where `clients` is mutated — no extra hop needed.
        client.connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            guard let self, var updated = self.clients[id] else { return }
            updated.inFlight = max(0, updated.inFlight - 1)
            self.clients[id] = updated
        })
    }

    private func sendBytes(_ data: Data, contentType: String, on connection: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendText(
        _ text: String,
        status: String = "200 OK",
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection
    ) {
        let data = Data(text.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        clients = clients.filter { $0.value.connection !== connection }
        publishClientCount()
    }

    private func isAuthorized(_ components: URLComponents?) -> Bool {
        guard let expectedAuthToken else { return true }
        guard let token = tokenData(components) else { return false }
        return WirelessAuth.validate(token, expected: expectedAuthToken)
    }

    private func tokenData(_ components: URLComponents?) -> Data? {
        guard let value = tokenQueryValue(components) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private func tokenQueryValue(_ components: URLComponents?) -> String? {
        components?.queryItems?.first(where: { $0.name == "t" })?.value
    }

    private func queryMap(_ components: URLComponents?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
    }

    private func makeJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let maxDimension = max(image.extent.width, image.extent.height)
        let scale = maxDimension > maxJPEGDimension ? maxJPEGDimension / maxDimension : 1
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        let output = scaled.cropped(to: scaled.extent.integral)
        // Single pass: CIContext renders and JPEG-encodes in one go. The previous
        // createCGImage -> NSBitmapImageRep -> representation(using:) chain walked the
        // full image three times, including a GPU readback and an extra buffer copy.
        return ciContext.jpegRepresentation(
            of: output,
            colorSpace: jpegColorSpace,
            options: [
                CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                ): 0.65
            ]
        )
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeJavaScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
