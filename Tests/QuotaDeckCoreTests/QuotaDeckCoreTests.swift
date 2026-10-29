import XCTest
@testable import QuotaDeckCore

final class QuotaDeckCoreTests: XCTestCase {
    func testInMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore()
        let service = "test.service"
        let account = "user1"

        XCTAssertNil(store.load(service: service, account: account))

        try store.save(secret: "secret-token-123", service: service, account: account)
        XCTAssertEqual(store.load(service: service, account: account), "secret-token-123")

        try store.delete(service: service, account: account)
        XCTAssertNil(store.load(service: service, account: account))
    }

    func testAntigravitySubscriptionParsing() {
        let json: [String: Any] = [
            "tierName": "Antigravity Pro",
            "groups": [
                [
                    "displayName": "Claude 3.5 Sonnet",
                    "buckets": [
                        [
                            "window": "5h",
                            "remainingFraction": 0.45,
                            "resetTime": "2026-10-22T18:00:00Z"
                        ]
                    ]
                ]
            ]
        ]

        let sub = AntigravityProvider.parseSubscription(from: json)
        XCTAssertEqual(sub.tierName, "Antigravity Pro")
        XCTAssertEqual(sub.status, .active)
        XCTAssertEqual(sub.quotaWindows.count, 1)
        XCTAssertEqual(sub.quotaWindows.first?.label, "Claude 3.5 Sonnet (5-Hour)")
        XCTAssertEqual(sub.quotaWindows.first?.usedPercent ?? 0, 55.0, accuracy: 0.1)
        XCTAssertNotNil(sub.quotaWindows.first?.resetsAt)
    }

    func testAntigravityTokenParsing() {
        let rawJSON = "{\"access_token\":\"ya29.test12345\"}"
        let base64 = Data(rawJSON.utf8).base64EncodedString()
        let payload = "go-keyring-base64:\(base64)"

        let parsed = AntigravityProvider.parseTokenSecret(payload)
        XCTAssertEqual(parsed?.accessToken, "ya29.test12345")
        XCTAssertNil(parsed?.expiry)

        let jwtHeader = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let jwtPayload = Data("{\"email\":\"test@example.com\"}".utf8).base64EncodedString()
        let fakeJWT = "\(jwtHeader).\(jwtPayload).signature"
        let secretWithJWT = "{\"id_token\":\"\(fakeJWT)\"}"
        let base64Secret = Data(secretWithJWT.utf8).base64EncodedString()
        let extractedEmail = AntigravityProvider.extractEmailFromSecret("go-keyring-base64:\(base64Secret)")
        XCTAssertEqual(extractedEmail, "test@example.com")
    }

    func testOpenCodeSubscriptionParsing() {
        let json: [String: Any] = [
            "usage": [
                "rolling": [
                    "percent": "35%",
                    "resetsAt": "2026-10-22T20:00:00Z"
                ],
                "weekly": [
                    "percent": 80,
                    "resetsAt": "2026-10-25T00:00:00Z"
                ]
            ]
        ]

        let sub = OpenCodeProvider.parseSubscription(from: json)
        XCTAssertEqual(sub.tierName, "OpenCode Go Pro")
        XCTAssertEqual(sub.status, .active)
        XCTAssertEqual(sub.quotaWindows.count, 2)
        XCTAssertEqual(sub.quotaWindows[0].usedPercent, 35.0)
        XCTAssertEqual(sub.quotaWindows[1].usedPercent, 80.0)
    }

    func testCodexSubscriptionParsing() {
        let json: [String: Any] = [
            "planType": "Plus",
            "primary": [
                "usedPercent": 15.0,
                "windowDurationMins": 300,
                "resetsAt": 1729600000
            ],
            "secondary": [
                "usedPercent": 100.0,
                "resetsAt": 1730000000
            ]
        ]

        let sub = CodexProvider.parseSubscription(from: json)
        XCTAssertEqual(sub.tierName, "Plus")
        XCTAssertEqual(sub.status, .quotaExhausted)
        XCTAssertEqual(sub.quotaWindows.count, 2)
        XCTAssertEqual(sub.quotaWindows[0].label, "5h Session Window")
        XCTAssertEqual(sub.quotaWindows[0].usedPercent, 15.0)
        XCTAssertEqual(sub.quotaWindows[1].usedPercent, 100.0)
    }

    func testAccountProfileModel() {
        let profile = AccountProfile(
            providerID: .openCode,
            label: "Work Account",
            accountEmail: "dev@example.com",
            isActive: true
        )

        XCTAssertEqual(profile.providerID, .openCode)
        XCTAssertEqual(profile.label, "Work Account")
        XCTAssertTrue(profile.isActive)
        XCTAssertEqual(profile.providerID.displayName, "OpenCode Go")
    }

    func testWidgetSnapshotSerialization() throws {
        let item = WidgetQuotaItem(
            id: "test-codex",
            providerID: .codex,
            label: "Codex Plus",
            tierName: "Plus",
            usedPercent: 42.5,
            remainingUnits: "58% remaining",
            status: .active
        )
        let snapshot = WidgetSnapshot(updatedAt: Date(), items: [item])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items.first?.providerID, .codex)
        XCTAssertEqual(decoded.items.first?.usedPercent, 42.5)
        XCTAssertEqual(decoded.items.first?.label, "Codex Plus")
    }

    func testCodexAtomicWriteAndProfileSwitch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-switcher-\(UUID().uuidString)")
        let liveDir = tempDir.appendingPathComponent(".codex")
        let switcherDir = tempDir.appendingPathComponent(".codex-switcher")
        let devAuthStore = switcherDir.appendingPathComponent("dev-auth-store")

        try FileManager.default.createDirectory(at: devAuthStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)

        let auth1Data = Data("{\"profile\":\"1\"}".utf8)
        let auth2Data = Data("{\"profile\":\"2\"}".utf8)
        try auth1Data.write(to: devAuthStore.appendingPathComponent("1.json"))
        try auth2Data.write(to: devAuthStore.appendingPathComponent("2.json"))

        let configData = Data("{\"activeProfile\":\"1\",\"profiles\":[{\"id\":\"1\"},{\"id\":\"2\"}]}".utf8)
        try configData.write(to: switcherDir.appendingPathComponent("config.json"))

        let provider = CodexProvider(switcherDirectory: switcherDir, liveAuthDirectory: liveDir)
        try await provider.switchActiveProfile(to: "2")

        let targetAuth = liveDir.appendingPathComponent("auth.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetAuth.path))
        let writtenData = try Data(contentsOf: targetAuth)
        XCTAssertEqual(String(data: writtenData, encoding: .utf8), "{\"profile\":\"2\"}")

        let updatedConfigData = try Data(contentsOf: switcherDir.appendingPathComponent("config.json"))
        let updatedJson = try JSONSerialization.jsonObject(with: updatedConfigData) as? [String: Any]
        XCTAssertEqual(updatedJson?["activeProfile"] as? String, "2")

        try? FileManager.default.removeItem(at: tempDir)
    }
}
