import XCTest
@testable import OpenUsage

@MainActor
final class CLIProxyAPIPrimaryStoreTests: XCTestCase {
    private let amy = CLIProxyAPIClaudeAccountRef(path: "/proxy/auth/claude-1-amy@x.nl.json", email: "amy@x.nl", accountUUID: "u-amy")
    private let zed = CLIProxyAPIClaudeAccountRef(path: "/proxy/auth/claude-2-zed@x.nl.json", email: "zed@x.nl", accountUUID: "u-zed")

    private func files(amy amyPriority: String, zed zedPriority: String) -> FakeFiles {
        FakeFiles([
            amy.path: #"{"type":"claude","email":"amy@x.nl","account_uuid":"u-amy","refresh_token":"KEEP","priority":\#(amyPriority)}"#,
            zed.path: #"{"type":"claude","email":"zed@x.nl","account_uuid":"u-zed","priority":\#(zedPriority)}"#
        ])
    }

    private func priority(_ files: FakeFiles, _ ref: CLIProxyAPIClaudeAccountRef) -> Any? {
        ProviderParse.jsonObject(Data(files.files[ref.path]!.utf8))?["priority"]
    }

    func testPrimaryIsTheSingleAccountWithTheTopPriority() async {
        let store = CLIProxyAPIPrimaryStore(accounts: [amy, zed], authStore: CLIProxyAPIAuthStore(files: files(amy: "200", zed: #""100""#)))
        await store.reload()
        XCTAssertEqual(store.primaryID, amy.providerID)

        XCTAssertNil(CLIProxyAPIPrimaryStore.primary(in: ["a": 100, "b": 100]))
        XCTAssertNil(CLIProxyAPIPrimaryStore.primary(in: [:]))
    }

    func testMakingAnAccountPrimarySetsItTo100AndTheOthersTo0AndKeepsOtherFields() async {
        let files = files(amy: "200", zed: "100")
        let store = CLIProxyAPIPrimaryStore(accounts: [amy, zed], authStore: CLIProxyAPIAuthStore(files: files))

        await store.setPrimary(zed.providerID, true)

        XCTAssertEqual(store.primaryID, zed.providerID)
        XCTAssertEqual(priority(files, zed) as? Int, 100)
        XCTAssertEqual(priority(files, amy) as? Int, 0)
        XCTAssertEqual(ProviderParse.jsonObject(Data(files.files[amy.path]!.utf8))?["refresh_token"] as? String, "KEEP")
    }

    func testTurningThePrimaryOffSetsEveryAccountTo0() async {
        let files = files(amy: "100", zed: "0")
        let store = CLIProxyAPIPrimaryStore(accounts: [amy, zed], authStore: CLIProxyAPIAuthStore(files: files))

        await store.setPrimary(amy.providerID, false)

        XCTAssertNil(store.primaryID)
        XCTAssertEqual(priority(files, amy) as? Int, 0)
        XCTAssertEqual(priority(files, zed) as? Int, 0)
    }

    func testASingleAccountHasNoSwitch() {
        let store = CLIProxyAPIPrimaryStore(accounts: [amy], authStore: CLIProxyAPIAuthStore(files: FakeFiles()))
        XCTAssertFalse(store.hasSwitch(amy.providerID))
    }
}
