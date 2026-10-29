import Foundation
import AppKit

public struct CodexProvider: QuotaProvider, Sendable {
    public let id: ProviderID = .codex
    public let displayName: String = "OpenAI Codex"
    public let capabilities: ProviderCapabilities = [.profileSwitching, .quotaWindows, .subscriptionCycle]

    private let switcherDirectory: URL
    private let liveAuthDirectory: URL

    private static let activeLoginLock = NSLock()
    private static var activeLoginProcess: Process?

    public init(
        switcherDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-switcher"),
        liveAuthDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    ) {
        self.switcherDirectory = switcherDirectory
        self.liveAuthDirectory = liveAuthDirectory
    }

    public func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo {
        // 1. Try to fetch live rate limits via Codex CLI RPC
        let authCandidates = [
            switcherDirectory.appendingPathComponent("dev-auth-store/\(account.id).json"),
            switcherDirectory.appendingPathComponent("profiles/\(account.id)/auth.json")
        ]
        var authData: Data? = authCandidates.compactMap { try? Data(contentsOf: $0) }.first
        if authData == nil && account.isActive {
            let liveAuth = liveAuthDirectory.appendingPathComponent("auth.json")
            authData = try? Data(contentsOf: liveAuth)
        }

        if let data = authData,
           let live = await Self.fetchLiveRateLimits(authData: data) {
            // If the token was refreshed during the RPC check, preserve it back to store
            if let newAuth = live.updatedAuthData {
                let targetStore = authCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
                    ?? switcherDirectory.appendingPathComponent("dev-auth-store/\(account.id).json")
                try? FileManager.default.createDirectory(at: targetStore.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? newAuth.write(to: targetStore, options: .atomic)
                if account.isActive {
                    let liveAuth = liveAuthDirectory.appendingPathComponent("auth.json")
                    try? newAuth.write(to: liveAuth, options: .atomic)
                }
            }

            // Update cache.json so snapshot cache is kept fresh
            Self.updateCacheSnapshot(
                switcherDirectory: switcherDirectory,
                profileID: account.id,
                planType: live.planType,
                primaryUsed: live.primaryUsed,
                primaryReset: live.primaryReset,
                primaryDurationMins: live.primaryDurationMins,
                secondaryUsed: live.secondaryUsed,
                secondaryReset: live.secondaryReset,
                secondaryDurationMins: live.secondaryDurationMins
            )

            var windows: [QuotaWindow] = []
            if let primaryUsed = live.primaryUsed {
                let duration = (live.primaryDurationMins ?? 300) / 60
                windows.append(QuotaWindow(
                    label: "\(duration)h Session Window",
                    usedPercent: primaryUsed,
                    resetsAt: live.primaryReset
                ))
            }
            if let secondaryUsed = live.secondaryUsed {
                windows.append(QuotaWindow(
                    label: "Weekly Quota",
                    usedPercent: secondaryUsed,
                    resetsAt: live.secondaryReset
                ))
            }

            let isExhausted = windows.contains { $0.usedPercent >= 100.0 }
            return SubscriptionInfo(
                tierName: "ChatGPT \(live.planType.capitalized)",
                tier: .team,
                status: isExhausted ? .quotaExhausted : .active,
                quotaWindows: windows
            )
        }

        // 2. Fallback: check ~/.codex-switcher/cache.json for cached usage snapshots
        let cacheURL = switcherDirectory.appendingPathComponent("cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let snapshots = json["snapshots"] as? [String: Any],
           let snapshot = snapshots[account.id] as? [String: Any] {
            return Self.parseCacheSnapshot(from: snapshot)
        }

        // 3. Fallback: check live auth file status
        let liveAuthFile = liveAuthDirectory.appendingPathComponent("auth.json")
        let isLoggedIn = FileManager.default.fileExists(atPath: liveAuthFile.path)

        return SubscriptionInfo(
            tierName: isLoggedIn ? "ChatGPT Team / Pro" : "Not Logged In",
            tier: .pro,
            status: isLoggedIn ? .active : .paymentRequired,
            quotaWindows: []
        )
    }

    public static func fetchLiveRateLimits(
        authData: Data,
        cliPath: String? = nil
    ) async -> (planType: String, primaryUsed: Double?, primaryReset: Date?, primaryDurationMins: Int?, secondaryUsed: Double?, secondaryReset: Date?, secondaryDurationMins: Int?, updatedAuthData: Data?)? {
        let resolvedCLI = cliPath ?? resolveCodexCLI() ?? "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: resolvedCLI) else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotadeck-codex-\(UUID().uuidString)", isDirectory: true)
        let authFile = tempDir.appendingPathComponent("auth.json")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try authData.write(to: authFile, options: .atomic)
            let liveConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
            if FileManager.default.fileExists(atPath: liveConfig.path) {
                try? FileManager.default.copyItem(at: liveConfig, to: tempDir.appendingPathComponent("config.toml"))
            }
        } catch {
            return nil
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: resolvedCLI)
                process.arguments = ["-s", "read-only", "app-server"]
                var env = ProcessInfo.processInfo.environment
                env["CODEX_HOME"] = tempDir.path
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                process.environment = env
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    try? FileManager.default.removeItem(at: tempDir)
                    continuation.resume(returning: nil)
                    return
                }

                let initPayload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"QuotaDeck\",\"version\":\"0.1.0\"}}}\n"
                let initializedPayload = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n"
                let rateLimitsPayload = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\"}\n"

                stdinPipe.fileHandleForWriting.write(Data(initPayload.utf8))

                let lock = NSLock()
                var continuationDone = false
                var buffer = Data()
                var sentRateLimits = false

                func finish(with result: (planType: String, primaryUsed: Double?, primaryReset: Date?, primaryDurationMins: Int?, secondaryUsed: Double?, secondaryReset: Date?, secondaryDurationMins: Int?, updatedAuthData: Data?)?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !continuationDone else { return }
                    continuationDone = true
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    var finalResult = result
                    if let res = result {
                        let updatedAuth = (try? Data(contentsOf: authFile)).flatMap { $0 != authData ? $0 : nil }
                        finalResult = (res.planType, res.primaryUsed, res.primaryReset, res.primaryDurationMins, res.secondaryUsed, res.secondaryReset, res.secondaryDurationMins, updatedAuth)
                    }
                    try? FileManager.default.removeItem(at: tempDir)
                    continuation.resume(returning: finalResult)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6.0) {
                    finish(with: nil)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }

                    lock.lock()
                    buffer.append(chunk)

                    var parsedResult: (planType: String, primaryUsed: Double?, primaryReset: Date?, primaryDurationMins: Int?, secondaryUsed: Double?, secondaryReset: Date?, secondaryDurationMins: Int?, updatedAuthData: Data?)? = nil

                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newlineIndex)
                        buffer.removeSubrange(0...newlineIndex)

                        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                            continue
                        }

                        if let id = json["id"] as? Int {
                            if id == 1 && !sentRateLimits {
                                sentRateLimits = true
                                stdinPipe.fileHandleForWriting.write(Data(initializedPayload.utf8))
                                stdinPipe.fileHandleForWriting.write(Data(rateLimitsPayload.utf8))
                            } else if id == 2 {
                                if let res = json["result"] as? [String: Any],
                                   let rateLimits = res["rateLimits"] as? [String: Any] {
                                    let plan = (rateLimits["planType"] as? String) ?? "team"
                                    var pUsed: Double? = nil
                                    var pReset: Date? = nil
                                    var pDur: Int? = nil
                                    if let primary = rateLimits["primary"] as? [String: Any] {
                                        pUsed = (primary["usedPercent"] as? NSNumber)?.doubleValue
                                        pDur = (primary["windowDurationMins"] as? NSNumber)?.intValue
                                        if let epoch = (primary["resetsAt"] as? NSNumber)?.doubleValue {
                                            pReset = Date(timeIntervalSince1970: epoch)
                                        }
                                    }
                                    var sUsed: Double? = nil
                                    var sReset: Date? = nil
                                    var sDur: Int? = nil
                                    if let secondary = rateLimits["secondary"] as? [String: Any] {
                                        sUsed = (secondary["usedPercent"] as? NSNumber)?.doubleValue
                                        sDur = (secondary["windowDurationMins"] as? NSNumber)?.intValue
                                        if let epoch = (secondary["resetsAt"] as? NSNumber)?.doubleValue {
                                            sReset = Date(timeIntervalSince1970: epoch)
                                        }
                                    }
                                    parsedResult = (plan, pUsed, pReset, pDur, sUsed, sReset, sDur, nil)
                                }
                                break
                            }
                        }
                    }
                    lock.unlock()

                    if let res = parsedResult {
                        finish(with: res)
                    }
                }
            }
        }
    }

    public static func updateCacheSnapshot(
        switcherDirectory: URL,
        profileID: String,
        planType: String,
        primaryUsed: Double?,
        primaryReset: Date?,
        primaryDurationMins: Int?,
        secondaryUsed: Double?,
        secondaryReset: Date?,
        secondaryDurationMins: Int?
    ) {
        let cacheURL = switcherDirectory.appendingPathComponent("cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var snapshots = (json["snapshots"] as? [String: Any]) ?? [:]
        var snapshot: [String: Any] = [
            "fetchedAt": ISO8601DateFormatter().string(from: Date()),
            "planType": planType
        ]
        if let pUsed = primaryUsed {
            snapshot["primaryUsedPercent"] = Int(pUsed.rounded())
        }
        if let pReset = primaryReset {
            snapshot["primaryResetAt"] = ISO8601DateFormatter().string(from: pReset)
        }
        if let pDur = primaryDurationMins {
            snapshot["primaryWindowDurationMins"] = pDur
        }
        if let sUsed = secondaryUsed {
            snapshot["secondaryUsedPercent"] = Int(sUsed.rounded())
        }
        if let sReset = secondaryReset {
            snapshot["secondaryResetAt"] = ISO8601DateFormatter().string(from: sReset)
        }
        if let sDur = secondaryDurationMins {
            snapshot["secondaryWindowDurationMins"] = sDur
        }

        snapshots[profileID] = snapshot
        json["snapshots"] = snapshots

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: cacheURL, options: .atomic)
        }
    }

    public static func atomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tempURL)
        if rename(tempURL.path, destination.path) != 0 {
            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
    }

    public func switchActiveProfile(to accountID: String) async throws {
        let authCandidates = [
            switcherDirectory.appendingPathComponent("dev-auth-store/\(accountID).json"),
            switcherDirectory.appendingPathComponent("profiles/\(accountID)/auth.json")
        ]

        guard let sourceAuth = authCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let targetData = try? Data(contentsOf: sourceAuth) else {
            throw CocoaError(.fileNoSuchFile)
        }

        // 1. Preserve current live auth back to outgoing profile's store if possible
        let configURL = switcherDirectory.appendingPathComponent("config.json")
        var currentActiveID: String? = nil
        if let configData = try? Data(contentsOf: configURL),
           let configJson = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            currentActiveID = configJson["activeProfile"] as? String
        }

        let targetAuth = liveAuthDirectory.appendingPathComponent("auth.json")
        if let outgoingID = currentActiveID, outgoingID != accountID,
           let currentLiveData = try? Data(contentsOf: targetAuth) {
            let outgoingStore = switcherDirectory.appendingPathComponent("dev-auth-store/\(outgoingID).json")
            try? Self.atomicWrite(currentLiveData, to: outgoingStore)
        }

        let wasRunning = Self.isCodexDesktopRunning()
        let workspace = wasRunning ? relaunchWorkspacePath() : nil
        let interruptedTask = wasRunning ? Self.latestInterruptedTask(codexHome: liveAuthDirectory) : nil

        if wasRunning {
            Self.stopCodexDesktop()
        }

        // 2. Atomically write the incoming profile auth
        try Self.atomicWrite(targetData, to: targetAuth)

        // 3. Update activeProfile in config.json
        if let data = try? Data(contentsOf: configURL),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["activeProfile"] = accountID
            if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? updatedData.write(to: configURL, options: .atomic)
            }
        }

        // 4. Relaunch or launch desktop with the selected profile
        Self.relaunchCodexDesktop(workspacePath: workspace)

        // 5. Continue interrupted task asynchronously so desktop relaunch is immediate
        if let task = interruptedTask {
            let codexHome = liveAuthDirectory
            Task.detached(priority: .userInitiated) {
                _ = await Self.resumeInterruptedTask(task, codexHome: codexHome)
            }
        }
    }

    public func relaunchWorkspacePath() -> String? {
        let globalStateURL = liveAuthDirectory.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: globalStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for key in ["active-workspace-roots", "electron-saved-workspace-roots"] {
            guard let values = json[key] as? [String] else { continue }
            for value in values {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: value, isDirectory: &isDir), isDir.boolValue {
                    return value
                }
            }
        }

        return nil
    }

    public static func ownedCodexDesktopPIDs() -> [Int32] {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,command="]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var pids: [Int32] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = Int32(pidStr) else { continue }
            let cmd = parts.count > 1 ? String(parts[1]) : ""

            if cmd.contains("grep") || cmd.contains("vscode") || cmd.contains("ps -axo") {
                continue
            }

            if cmd.contains("/Applications/ChatGPT.app/") || cmd.contains("/Applications/Codex.app/") {
                pids.append(pid)
            } else if cmd.contains("app-server") && (cmd.contains("codex-cli") || cmd.contains("/bin/codex")) {
                pids.append(pid)
            }
        }
        return pids
    }

    public static func isCodexDesktopRunning() -> Bool {
        return !ownedCodexDesktopPIDs().isEmpty
    }

    public static func stopCodexDesktop() {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application id \"com.openai.codex\" to quit"]
        try? script.run()
        script.waitUntilExit()

        for _ in 0..<30 {
            if !isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for pid in ownedCodexDesktopPIDs() {
            kill(pid, SIGTERM)
        }

        for _ in 0..<20 {
            if !isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for pid in ownedCodexDesktopPIDs() {
            kill(pid, SIGKILL)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    public static func relaunchCodexDesktop(workspacePath: String? = nil) {
        let appPath: String? = {
            if FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") {
                return "/Applications/ChatGPT.app"
            } else if FileManager.default.fileExists(atPath: "/Applications/Codex.app") {
                return "/Applications/Codex.app"
            }
            return nil
        }()

        guard let app = appPath else { return }

        var args = ["-n", "-a", app]
        if let workspace = workspacePath,
           let encoded = workspace.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) {
            args.append("codex://threads/new?path=\(encoded)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()

        for _ in 0..<50 {
            if isCodexDesktopRunning() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Interrupted Task Detection & Continuation

    public struct InterruptedTask: Equatable, Sendable {
        public let threadID: String
        public let turnID: String
        public let completedAt: Date

        public init(threadID: String, turnID: String, completedAt: Date) {
            self.threadID = threadID
            self.turnID = turnID
            self.completedAt = completedAt
        }
    }

    public static let autoContinuePrompt = """
    Continue the interrupted task from where it stopped. The previous turn ended because the account reached its usage limit. Do not restart completed work or repeat successful tool calls.
    """

    public static func latestInterruptedTask(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        now: Date = Date(),
        lookback: TimeInterval = 15 * 60
    ) -> InterruptedTask? {
        guard let history = latestDatabase(in: codexHome, prefix: "thread_history_"),
              let state = latestDatabase(in: codexHome, prefix: "state_") else {
            return nil
        }

        let cutoff = Int64(now.timeIntervalSince1970 - lookback)
        let sql = """
        ATTACH DATABASE \(sqlLiteral(readOnlyURI(for: state))) AS state;
        SELECT tt.thread_id, tt.turn_id, tt.completed_at
        FROM main.thread_turns AS tt
        JOIN state.threads AS t ON t.id = tt.thread_id
        WHERE tt.status = 'failed'
          AND json_valid(tt.error_json)
          AND (
            json_extract(tt.error_json, '$.codexErrorInfo') = 'usageLimitExceeded'
            OR json_extract(tt.error_json, '$.codexErrorInfo.type') = 'usageLimitExceeded'
          )
          AND t.archived = 0
          AND t.source NOT LIKE '{"subagent%'
          AND tt.completed_at >= \(cutoff)
          AND NOT EXISTS (
            SELECT 1 FROM main.thread_turns AS newer
            WHERE newer.thread_id = tt.thread_id
              AND newer.rollout_ordinal > tt.rollout_ordinal
          )
        ORDER BY tt.completed_at DESC
        LIMIT 1;
        """

        guard let data = runSQLite(database: history, sql: sql),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rows = try? JSONDecoder().decode([InterruptedRow].self, from: Data(text.utf8)),
              let row = rows.first,
              let threadID = row.thread_id,
              let turnID = row.turn_id,
              let completedAt = row.completed_at,
              UUID(uuidString: threadID) != nil,
              UUID(uuidString: turnID) != nil else {
            return nil
        }

        return InterruptedTask(
            threadID: threadID,
            turnID: turnID,
            completedAt: Date(timeIntervalSince1970: TimeInterval(completedAt))
        )
    }

    public static func resumeInterruptedTask(
        _ task: InterruptedTask,
        cliPath: String? = nil,
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    ) async -> Bool {
        let resolvedCLI = cliPath ?? resolveCodexCLI() ?? "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: resolvedCLI) else {
            return false
        }

        let logDir = codexHome.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("auto-continue.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: resolvedCLI)
                process.arguments = [
                    "exec", "resume", "--skip-git-repo-check", task.threadID, autoContinuePrompt
                ]
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = codexHome.path
                process.environment = environment
                process.currentDirectoryURL = codexHome
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = logHandle ?? FileHandle.nullDevice
                process.standardError = logHandle ?? FileHandle.nullDevice

                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1800, execute: watchdog)
                    process.waitUntilExit()
                    watchdog.cancel()
                    try? logHandle?.close()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    watchdog.cancel()
                    try? logHandle?.close()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private struct InterruptedRow: Decodable {
        let thread_id: String?
        let turn_id: String?
        let completed_at: Int64?
    }

    private static func latestDatabase(in directory: URL, prefix: String) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil) else {
            return nil
        }
        return urls
            .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { url -> (Int, URL)? in
                let stem = url.deletingPathExtension().lastPathComponent
                guard let version = Int(stem.dropFirst(prefix.count)) else { return nil }
                return (version, url)
            }
            .max { $0.0 < $1.0 }?
            .1
    }

    private static func readOnlyURI(for url: URL) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file:\(path)?mode=ro"
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func runSQLite(database: URL, sql: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", readOnlyURI(for: database), sql]
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    // MARK: - Isolated Browser Login

    public static func resolveCodexCLI() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try environment PATH search
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path
            }
        }
        return nil
    }

    public static func startIsolatedLogin() async throws -> (authData: Data, email: String?) {
        guard let codexCLI = resolveCodexCLI() else {
            throw NSError(domain: "CodexProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex CLI not found in /opt/homebrew/bin/codex or PATH."])
        }

        let tempID = UUID().uuidString
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("quotadeck-codex-\(tempID)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempHome)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexCLI)
        process.arguments = ["login"]
        process.environment = [
            "CODEX_HOME": tempHome.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        ]

        activeLoginLock.lock()
        activeLoginProcess = process
        activeLoginLock.unlock()

        defer {
            activeLoginLock.lock()
            activeLoginProcess = nil
            activeLoginLock.unlock()
        }

        let exitStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard exitStatus == 0 else {
            throw NSError(domain: "CodexProvider", code: Int(exitStatus), userInfo: [NSLocalizedDescriptionKey: "Codex login was cancelled or failed with exit status \(exitStatus)."])
        }

        let tempAuthURL = tempHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: tempAuthURL.path) else {
            throw NSError(domain: "CodexProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Login completed but no auth.json was written."])
        }

        let data = try Data(contentsOf: tempAuthURL)
        let email = emailFromAuthData(data)
        return (data, email)
    }

    public static func cancelActiveLogin() {
        activeLoginLock.lock()
        defer { activeLoginLock.unlock() }
        activeLoginProcess?.terminate()
        activeLoginProcess = nil
    }

    public func saveNewProfile(id: String, label: String, authData: Data, makeActive: Bool) throws {
        // Save to ~/.codex-switcher/dev-auth-store/<id>.json
        let storeDir = switcherDirectory.appendingPathComponent("dev-auth-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let profileAuthURL = storeDir.appendingPathComponent("\(id).json")
        try authData.write(to: profileAuthURL, options: .atomic)

        // Update ~/.codex-switcher/config.json
        let configURL = switcherDirectory.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }

        var profiles = config["profiles"] as? [[String: Any]] ?? []
        profiles.removeAll { ($0["id"] as? String) == id }
        profiles.append([
            "id": id,
            "label": label
        ])
        config["profiles"] = profiles
        if makeActive || config["activeProfile"] == nil {
            config["activeProfile"] = id
        }

        let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: configURL, options: .atomic)

        // If active, also copy to ~/.codex/auth.json
        if makeActive {
            try? FileManager.default.createDirectory(at: liveAuthDirectory, withIntermediateDirectories: true)
            let liveTarget = liveAuthDirectory.appendingPathComponent("auth.json")
            try? FileManager.default.removeItem(at: liveTarget)
            try authData.write(to: liveTarget, options: .atomic)
        }
    }

    public static func emailFromAuthData(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = (tokens["id_token"] as? String) ?? (tokens["idToken"] as? String) else {
            return nil
        }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))

        guard let payloadData = Data(base64Encoded: base64),
              let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        return payloadJSON["email"] as? String
    }

    // MARK: - Snapshot & Models

    public static func parseSubscription(from json: [String: Any]) -> SubscriptionInfo {
        if json["primary"] != nil || json["secondary"] != nil {
            var windows: [QuotaWindow] = []
            let planType = (json["planType"] as? String)?.capitalized ?? "Plus"

            if let primary = json["primary"] as? [String: Any],
               let usedPercent = (primary["usedPercent"] as? NSNumber)?.doubleValue {
                let durationMins = (primary["windowDurationMins"] as? NSNumber)?.intValue ?? 300
                let resetDate = (primary["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(QuotaWindow(
                    label: "\(durationMins / 60)h Session Window",
                    usedPercent: usedPercent,
                    resetsAt: resetDate
                ))
            }

            if let secondary = json["secondary"] as? [String: Any],
               let usedPercent = (secondary["usedPercent"] as? NSNumber)?.doubleValue {
                let resetDate = (secondary["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(QuotaWindow(
                    label: "Weekly Quota",
                    usedPercent: usedPercent,
                    resetsAt: resetDate
                ))
            }

            let isExhausted = windows.contains { $0.usedPercent >= 100.0 }
            return SubscriptionInfo(
                tierName: planType,
                tier: .pro,
                status: isExhausted ? .quotaExhausted : .active,
                quotaWindows: windows
            )
        }

        return parseCacheSnapshot(from: json)
    }

    public static func parseCacheSnapshot(from json: [String: Any]) -> SubscriptionInfo {
        var windows: [QuotaWindow] = []
        let planType = (json["planType"] as? String)?.capitalized ?? "ChatGPT Team"

        if let usedPercent = (json["primaryUsedPercent"] as? NSNumber)?.doubleValue {
            let durationMins = (json["primaryWindowDurationMins"] as? NSNumber)?.intValue ?? 300
            let resetDate = (json["primaryResetAt"] as? String).flatMap(parseISO8601Date)
            windows.append(QuotaWindow(
                label: "\(durationMins / 60)h Session Window",
                usedPercent: usedPercent,
                resetsAt: resetDate
            ))
        }

        if let usedPercent = (json["secondaryUsedPercent"] as? NSNumber)?.doubleValue {
            let resetDate = (json["secondaryResetAt"] as? String).flatMap(parseISO8601Date)
            windows.append(QuotaWindow(
                label: "Weekly Quota",
                usedPercent: usedPercent,
                resetsAt: resetDate
            ))
        }

        let isExhausted = windows.contains { $0.usedPercent >= 100.0 }

        return SubscriptionInfo(
            tierName: "ChatGPT \(planType)",
            tier: .team,
            status: isExhausted ? .quotaExhausted : .active,
            quotaWindows: windows
        )
    }

    public static func discoverProfiles(switcherDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-switcher")) -> [AccountProfile] {
        let configURL = switcherDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profilesArray = json["profiles"] as? [[String: Any]] else {
            return []
        }

        let activeProfileID = json["activeProfile"] as? String

        return profilesArray.compactMap { dict -> AccountProfile? in
            guard let id = dict["id"] as? String else { return nil }
            let label = (dict["label"] as? String) ?? "Profile \(id)"
            let isActive = (id == activeProfileID)
            return AccountProfile(
                id: id,
                providerID: .codex,
                label: label,
                accountEmail: label.contains("@") ? label : nil,
                isActive: isActive
            )
        }
    }

    private static func parseISO8601Date(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }
}
