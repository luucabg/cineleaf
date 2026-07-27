import XCTest

final class AutomationCLITests: XCTestCase {
    func testNativeAutomationCLIReportsStructuredCapabilities() throws {
        var directory = Bundle(for: AutomationCLITests.self).bundleURL
        var candidates: [URL] = []
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("CineleafCLI"))
            directory.deleteLastPathComponent()
        }
        let executable = try XCTUnwrap(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "CineleafCLI was not found in the bounded Xcode products ancestry."
        )
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
