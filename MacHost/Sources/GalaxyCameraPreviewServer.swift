import Foundation
import Network

final class GalaxyCameraPreviewServer {
    static let defaultPort: UInt16 = 54324

    private let port: UInt16
    private let frameProvider: () -> Data?
    private let queue = DispatchQueue(label: "galaxyCameraPreviewServer", qos: .userInteractive)
    private var listener: NWListener?
    private var streamTimers: [UUID: DispatchSourceTimer] = [:]

    init(port: UInt16 = GalaxyCameraPreviewServer.defaultPort, frameProvider: @escaping () -> Data?) {
        self.port = port
        self.frameProvider = frameProvider
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
                self?.handle(connection)
            }
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    debugLog("Galaxy camera preview available at http://127.0.0.1:\(self.port)/")
                case .failed(let error):
                    debugLog("Galaxy camera preview server failed: \(error)")
                default:
                    break
                }
            }
            listener?.start(queue: queue)
        } catch {
            debugLog("Failed to start Galaxy camera preview server: \(error)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for timer in self.streamTimers.values {
                timer.cancel()
            }
            self.streamTimers.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        var buffer = Data()
        let isLocalClient = isLoopback(connection.endpoint)
        connection.stateUpdateHandler = { [weak connection] state in
            if case .failed = state {
                connection?.cancel()
            } else if case .cancelled = state {
                connection?.cancel()
            }
        }
        connection.start(queue: queue)

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
                    self.route(connection, requestData: buffer, isLocalClient: isLocalClient)
                } else if buffer.count > 8192 {
                    self.sendText("Bad Request", status: "400 Bad Request", on: connection)
                } else {
                    receiveMore()
                }
            }
        }

        receiveMore()
    }

    private func route(_ connection: NWConnection, requestData: Data, isLocalClient: Bool) {
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

        guard isLocalClient || path == "/camera-pair" || path == "/health" else {
            sendText("Galaxy camera preview is only available on this Mac.", status: "403 Forbidden", on: connection)
            return
        }

        switch path {
        case "/":
            sendHTML(on: connection)
        case "/camera-pair":
            sendPairingHTML(components: components, on: connection)
        case "/stream.mjpg":
            startMJPEG(on: connection)
        case "/latest.jpg":
            guard let frame = frameProvider() else {
                sendText("No frame yet.", status: "404 Not Found", on: connection)
                return
            }
            sendBytes(frame, contentType: "image/jpeg", on: connection)
        case "/health":
            sendText(frameProvider() == nil ? "waiting" : "ok", contentType: "text/plain; charset=utf-8", on: connection)
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else {
                timer.cancel()
                return
            }
            guard let frame = self.frameProvider() else { return }
            self.sendJPEGChunk(frame, to: connection)
        }
        streamTimers[id] = timer
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.removeStream(id)
            } else if case .cancelled = state {
                self?.removeStream(id)
            }
        }
        timer.resume()
    }

    private func removeStream(_ id: UUID) {
        streamTimers[id]?.cancel()
        streamTimers[id] = nil
    }

    private func sendHTML(on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>SideScreen Galaxy Camera</title>
          <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
            img { display: block; width: 100vw; height: 100vh; object-fit: cover; background: #000; }
          </style>
        </head>
        <body>
          <img id="camera" src="/latest.jpg" alt="">
          <script>
            const camera = document.getElementById("camera");
            const frameIntervalMs = 33;
            function refresh() {
              camera.src = `/latest.jpg?t=${Date.now()}`;
            }
            camera.addEventListener("load", () => setTimeout(refresh, frameIntervalMs));
            camera.addEventListener("error", () => setTimeout(refresh, 250));
            refresh();
          </script>
        </body>
        </html>
        """
        sendBytes(Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func sendPairingHTML(components: URLComponents?, on connection: NWConnection) {
        let query = queryMap(components)
        let host = query["h"] ?? LANAddressResolver.primaryIPv4() ?? "127.0.0.1"
        let cameraPort = UInt16(query["p"] ?? "") ?? GalaxyCameraServer.defaultPort
        let appURL = PairingURL.buildCameraAppURL(host: host, port: cameraPort)
        let html = """
        <!doctype html>
        <html lang="ko">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>SideScreen Galaxy Camera</title>
          <style>
            html, body { margin: 0; min-height: 100%; background: #050608; color: #f4f6f8; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
            main { min-height: 100svh; display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
            section { width: min(420px, 100%); display: grid; gap: 14px; text-align: center; }
            h1 { margin: 0; font-size: 24px; line-height: 1.2; }
            p { margin: 0; color: #aab2bf; font-size: 14px; line-height: 1.5; }
            a.button { display: inline-flex; align-items: center; justify-content: center; min-height: 48px; border-radius: 8px; background: #38d996; color: #06120c; font-weight: 800; text-decoration: none; padding: 0 16px; }
            code { display: block; overflow-wrap: anywhere; padding: 10px; border-radius: 8px; background: rgba(255,255,255,.08); color: #dfe7ee; font-size: 12px; text-align: left; }
          </style>
        </head>
        <body>
          <main>
            <section>
              <h1>Galaxy Camera</h1>
              <p>같은 Wi-Fi에 연결된 상태에서 아래 버튼을 누르면 SideScreen 앱이 카메라 스트리밍을 시작합니다.</p>
              <a class="button" href="\(escapeHTML(appURL))">앱에서 카메라 시작</a>
              <code>\(escapeHTML(host)):\(cameraPort)</code>
            </section>
          </main>
          <script>
            setTimeout(() => { location.href = "\(escapeJavaScript(appURL))"; }, 350);
          </script>
        </body>
        </html>
        """
        sendBytes(Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func sendJPEGChunk(_ jpeg: Data, to connection: NWConnection) {
        var chunk = Data()
        chunk.append(Data("\r\n--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8))
        chunk.append(jpeg)
        connection.send(content: chunk, completion: .contentProcessed { _ in })
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

    private func queryMap(_ components: URLComponents?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
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

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if address.rawValue == IPv6Address.loopback.rawValue {
                return true
            }

            let isIPv4CompatibleLoopback = bytes[0..<12].allSatisfy { $0 == 0 } && bytes[12] == 127
            let isIPv4MappedLoopback =
                bytes[0..<10].allSatisfy { $0 == 0 } &&
                bytes[10] == 0xff &&
                bytes[11] == 0xff &&
                bytes[12] == 127
            return isIPv4CompatibleLoopback || isIPv4MappedLoopback
        case .name(let name, _):
            return name == "localhost"
        default:
            return false
        }
    }
}
