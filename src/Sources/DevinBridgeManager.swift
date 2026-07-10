import Foundation
import AppKit

/// Manages the Devin-to-OpenAI bridge Python process.
///
/// The bridge translates OpenAI-compatible /v1/chat/completions requests
/// into Devin ACP WebSocket (JSON-RPC 2.0) calls, allowing tools like
/// Factory Droids to use Devin models through VibeProxy.
///
/// The bridge reads credentials from ~/.devin/credentials.toml (populated
/// by `devin auth`) or the DEVIN_OUTPOSTS_TOKEN environment variable.
class DevinBridgeManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Not started"

    private var process: Process?
    private let port: UInt16 = 8419
    private let host = "127.0.0.1"

    /// Path to the bundled devin_bridge.py script
    private var bridgeScriptPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("devin-bridge/devin_bridge.py")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Path to the system python3
    private var pythonPath: String {
        // Prefer Homebrew python3, fall back to system
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
    }

    /// Check if the Devin bridge port is responding
    func checkHealth() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            return false
        }
        return false
    }

    /// Start the Devin bridge process
    func start() {
        guard !isRunning else { return }

        guard let scriptPath = bridgeScriptPath else {
            NSLog("[DevinBridge] Bridge script not found in app bundle")
            statusMessage = "Bridge script not found"
            return
        }

        // Check if port is already in use (bridge might already be running)
        if isPortInUse(port) {
            NSLog("[DevinBridge] Port %d already in use, assuming bridge is running", port)
            DispatchQueue.main.async {
                self.isRunning = true
                self.statusMessage = "Running (external)"
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath, "--port", String(port), "--host", host]

        // Inherit environment so the bridge can find DEVIN_OUTPOSTS_TOKEN
        proc.environment = ProcessInfo.processInfo.environment

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                NSLog("[DevinBridge] %@", output.trimmingCharacters(in: .whitespacesAndNewlines))
                if output.contains("Uvicorn running") {
                    DispatchQueue.main.async {
                        self?.isRunning = true
                        self?.statusMessage = "Running"
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                NSLog("[DevinBridge] ERROR: %@", output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] proc in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.statusMessage = "Stopped (exit \(proc.terminationStatus))"
                NSLog("[DevinBridge] Process exited with code %d", proc.terminationStatus)
            }
        }

        do {
            try proc.run()
            process = proc
            NSLog("[DevinBridge] Started bridge process (PID: %d) on port %d", proc.processIdentifier, port)
            statusMessage = "Starting..."

            // Check health after a delay
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.isRunning else { return }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let healthy = await self.checkHealth()
                    if healthy {
                        self.statusMessage = "Running"
                    }
                }
            }
        } catch {
            NSLog("[DevinBridge] Failed to start: %@", error.localizedDescription)
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// Stop the Devin bridge process
    func stop() {
        guard let proc = process else {
            DispatchQueue.main.async {
                self.isRunning = false
                self.statusMessage = "Stopped"
            }
            return
        }

        NSLog("[DevinBridge] Stopping bridge (PID: %d)", proc.processIdentifier)
        proc.terminate()

        let deadline = Date().addingTimeInterval(3.0)
        DispatchQueue.global(qos: .background).async {
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
        }
    }

    /// Check if a TCP port is in use
    private func isPortInUse(_ port: UInt16) -> Bool {
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        checkTask.arguments = ["-i", "TCP:\(port)", "-sTCP:LISTEN"]
        checkTask.standardOutput = Pipe()
        checkTask.standardError = Pipe()
        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            return checkTask.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Check if Devin credentials exist
    static func hasCredentials() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/share/devin/credentials.toml"),
            home.appendingPathComponent(".devin/credentials.toml"),
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path.path) {
                return true
            }
        }
        return ProcessInfo.processInfo.environment["DEVIN_OUTPOSTS_TOKEN"] != nil
    }

    /// Open the Devin auth page in browser
    static func openAuthPage() {
        let url = URL(string: "https://app.devin.ai/settings/devin-api")!
        NSWorkspace.shared.open(url)
    }

    deinit {
        stop()
    }
}
