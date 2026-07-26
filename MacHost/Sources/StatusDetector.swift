import Foundation
import SystemConfiguration

enum StatusDetector {
    struct AndroidDisplaySize: Equatable {
        let width: Int
        let height: Int

        var resolution: String {
            "\(width)x\(height)"
        }
    }

    static func adbInstalled() -> Bool {
        return adbExecutablePath() != nil
    }

    static func wifiReachable() -> Bool {
        guard let reach = SCNetworkReachabilityCreateWithName(nil, "1.1.1.1") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    /// Run `adb devices`, return list of device serials in `device` state.
    static func usbDevices() -> [String] {
        guard let adbPath = adbExecutablePath() else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Heuristic: parse `adb reverse --list` for the stream port and browser health port.
    static func adbReverseConfigured(port: Int) -> Bool {
        guard let adbPath = adbExecutablePath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["reverse", "--list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let healthPort = port < Int(UInt16.max) ? port + 1 : port - 1
        return [port, healthPort].allSatisfy { output.contains("tcp:\($0) tcp:\($0)") }
    }

    /// Read the active Android display size reported by the connected USB device.
    static func activeAndroidDisplaySize() async -> AndroidDisplaySize? {
        await Task.detached(priority: .utility) {
            activeAndroidDisplaySizeSync()
        }.value
    }

    private static func activeAndroidDisplaySizeSync() -> AndroidDisplaySize? {
        guard !usbDevices().isEmpty else { return nil }
        guard let adbPath = adbExecutablePath() else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["shell", "wm", "size"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseAndroidDisplaySize(output)
    }

    private static func parseAndroidDisplaySize(_ output: String) -> AndroidDisplaySize? {
        let pattern = #"Physical size:\s*([0-9]+)x([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges == 3,
              let widthRange = Range(match.range(at: 1), in: output),
              let heightRange = Range(match.range(at: 2), in: output),
              let width = Int(output[widthRange]),
              let height = Int(output[heightRange]),
              (640...7680).contains(width),
              (480...4320).contains(height) else {
            return nil
        }

        return AndroidDisplaySize(width: width, height: height)
    }

    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast

    static func adbExecutablePath() -> String? {
        // Re-resolve every 5 s so install/uninstall is reflected.
        if let cached = cachedAdbPath, Date().timeIntervalSince(lastAdbCacheCheck) < 5.0 {
            return cached
        }
        let candidatePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedAdbPath = path
            lastAdbCacheCheck = Date()
            return path
        }
        // Fallback: ask `which adb` (covers PATH-installed setups).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !out.isEmpty,
               FileManager.default.isExecutableFile(atPath: out) {
                cachedAdbPath = out
                lastAdbCacheCheck = Date()
                return out
            }
        } catch {
            // ignore
        }
        cachedAdbPath = nil
        lastAdbCacheCheck = Date()
        return nil
    }
}
