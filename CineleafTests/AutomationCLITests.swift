import XCTest

final class AutomationCLITests: XCTestCase {
    func testNativeAutomationCLIReportsStructuredCapabilities() throws {
        let executable = Bundle(for: AutomationCLITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("CineleafCLI")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["capabilities"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["protocolVersion"] as? Int, 1)
        XCTAssertEqual(data["platform"] as? String, "macos")
    }
}
