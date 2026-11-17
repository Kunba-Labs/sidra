import XCTest
@testable import Sidra

final class PipelinesTests: XCTestCase {
    /// The shape of a GitLab 19 runner trace: timestamped lines, `+` continuations, sections with
    /// ESC[0K, ANSI colour, the failure inside step_script and the runner's verdict outside.
    static let trace = [
        "2026-11-05T15:24:27.100000Z 00O Running with gitlab-runner 19.5.0",
        "2026-11-05T15:24:27.200000Z 00O section_start:1793892267:prepare_executor\r\u{1b}[0K",
        "2026-11-05T15:24:27.200001Z 00O+\u{1b}[0K\u{1b}[36;1mPreparing the \"docker\" executor\u{1b}[0;m",
        "2026-11-05T15:24:29.000000Z 00O Using docker image ruby:3.4",
        "2026-11-05T15:24:29.100000Z 00O section_end:1793892269:prepare_executor\r\u{1b}[0K",
        "2026-11-05T15:24:32.000000Z 00O section_start:1793892272:step_script\r\u{1b}[0K",
        "2026-11-05T15:24:32.000001Z 00O+\u{1b}[0K\u{1b}[36;1mExecuting \"step_script\" stage of the job script\u{1b}[0;m",
        "2026-11-05T15:27:20.053700Z 01E   #20 DONE 10.4s",
        "2026-11-05T15:27:20.053710Z 01O   test result: ok. 23 passed; 0 failed",
        "2026-11-05T15:27:20.053743Z 01O   build_failed   {\"code\":\"image_scan_blocked\"}",
        "2026-11-05T15:27:20.055067Z 01E Error: deployment 01a1ac50 failed at build_failed",
        "2026-11-05T15:27:20.255230Z 00O section_end:1793892440:step_script\r\u{1b}[0K",
        "2026-11-05T15:27:20.257212Z 00O+section_start:1793892440:cleanup_file_variables\r\u{1b}[0K",
        "2026-11-05T15:27:20.257224Z 00O+\u{1b}[0K\u{1b}[36;1mCleaning up project directory and file based variables\u{1b}[0;m",
        "2026-11-05T15:27:22.892314Z 00O section_end:1793892442:cleanup_file_variables\r\u{1b}[0K",
        "2026-11-05T15:27:23.167764Z 00O \u{1b}[31;1mERROR: Job failed: exit code 1\u{1b}[0;m",
    ].joined(separator: "\n")

    func testParsesSectionsAndFindsTheFailure() throws {
        let log = JobLog.parse(Self.trace)
        let named = log.sections.filter { !$0.name.isEmpty }
        XCTAssertEqual(named.map(\.name), ["prepare_executor", "step_script", "cleanup_file_variables"])
        XCTAssertEqual(named[0].title, "Preparing the \"docker\" executor", "the header comes from the + line after section_start")
        XCTAssertEqual(named[1].duration, 168)

        let script = try XCTUnwrap(log.sections.first { $0.name == "step_script" })
        XCTAssertEqual(log.failingSectionID, script.id, "the script failed, not the cleanup")
        XCTAssertEqual(script.lines.filter(\.isError).map(\.text), [
            "  build_failed   {\"code\":\"image_scan_blocked\"}",
            "Error: deployment 01a1ac50 failed at build_failed",
        ])
        XCTAssertFalse(script.lines.contains { $0.text.contains("passed;") && $0.isError }, "a passing test summary is no error")
        XCTAssertFalse(log.sections.flatMap(\.lines).contains { $0.text.contains("\u{1b}") || $0.text.contains("2026-11-05T") }, "timestamps and ANSI are gone")

        let last = try XCTUnwrap(log.sections.last)
        XCTAssertEqual(last.name, "", "the runner's verdict sits outside any section, after it")
        XCTAssertEqual(last.lines.map(\.text), ["ERROR: Job failed: exit code 1"])
        XCTAssertTrue(last.lines[0].isError)
        XCTAssertEqual(log.sections.first?.lines.first?.text, "Running with gitlab-runner 19.5.0")
    }

    func testPlainTraceWithoutTimestamps() {
        let log = JobLog.parse("$ make\ncc -c a.c\na.c:3: error: expected ';'\nmake: *** [a.o] Error 1")
        XCTAssertEqual(log.sections.count, 1)
        XCTAssertEqual(log.sections[0].lines.filter(\.isError).count, 2)
    }

    func testURLNormalising() {
        XCTAssertEqual(GitLabClient.normalize("git.example.com/")?.absoluteString, "https://git.example.com")
        XCTAssertEqual(GitLabClient.normalize("https://git.example.com/api/v4")?.absoluteString, "https://git.example.com")
        XCTAssertNil(GitLabClient.normalize("  "))
        XCTAssertNil(GitLabClient.normalize("http://git.example.com"), "the token never goes over plain HTTP")
    }

    func testGroupsByTopNamespace() throws {
        let json = #"[{"id":1,"name":"aktes","path_with_namespace":"spqr/kvk/aktes","web_url":"x","avatar_url":null,"namespace":{"id":2,"kind":"group","full_path":"spqr/kvk"},"last_activity_at":"2026-11-14T10:00:00.000Z"},{"id":3,"name":"shop","path_with_namespace":"acme/shop","web_url":"x","avatar_url":null,"namespace":{"id":4,"kind":"group","full_path":"acme"},"last_activity_at":null}]"#
        let projects = try GitLabClient.decoder.decode([GitLabProject].self, from: Data(json.utf8))
        XCTAssertEqual(projects.map(\.group), ["spqr", "acme"])
        XCTAssertNotNil(projects[0].last_activity_at)
    }

    // MARK: GitHub

    func testGitHubStatusesMapToPipelineStatuses() {
        XCTAssertEqual(GitHubClient.status("in_progress", nil), "running")
        XCTAssertEqual(GitHubClient.status("queued", nil), "pending")
        XCTAssertEqual(GitHubClient.status("completed", "success"), "success")
        XCTAssertEqual(GitHubClient.status("completed", "failure"), "failed")
        XCTAssertEqual(GitHubClient.status("completed", "timed_out"), "failed")
        XCTAssertEqual(GitHubClient.status("completed", "cancelled"), "canceled")
        XCTAssertEqual(GitHubClient.status("completed", "skipped"), "skipped")
    }

    func testGitHubLogGroupsAndErrors() {
        let raw = """
        2026-11-17T10:00:00.0000000Z ##[group]Run actions/checkout@v4
        2026-11-17T10:00:01.0000000Z Syncing repository
        2026-11-17T10:00:02.0000000Z ##[endgroup]
        2026-11-17T10:00:03.0000000Z ##[group]Run swift test
        2026-11-17T10:00:04.0000000Z Test Suite passed
        2026-11-17T10:00:05.0000000Z ##[error]Process completed with exit code 1.
        2026-11-17T10:00:06.0000000Z ##[endgroup]
        """
        let log = JobLog.parseGitHub(raw)
        let named = log.sections.filter { !$0.name.isEmpty }
        XCTAssertEqual(named.map(\.title), ["Run actions/checkout@v4", "Run swift test"])
        XCTAssertEqual(named[0].lines.map(\.text), ["Syncing repository"])   // timestamps off
        XCTAssertTrue(named[1].lines.last?.isError == true)
        XCTAssertEqual(named[1].lines.last?.text, "Process completed with exit code 1.")
        XCTAssertEqual(log.failingSectionID, named[1].id)
    }

    func testConnectionURLsAndTitles() {
        XCTAssertEqual(PipelineConnection.normalize("github.example.com/api/v3/")?.absoluteString, "https://github.example.com")
        XCTAssertNil(PipelineConnection.normalize("http://gitlab.example.com"), "the token never goes over plain HTTP")
        let hub = PipelineConnection(provider: .github, url: "https://github.com")
        XCTAssertTrue(hub.isHosted)
        XCTAssertEqual(hub.title, "GitHub")
        XCTAssertEqual((hub.client(token: "t") as? GitHubClient)?.api.absoluteString, "https://api.github.com")
        let ghe = PipelineConnection(provider: .github, url: "https://github.example.com")
        XCTAssertEqual(ghe.title, "github.example.com")
        XCTAssertEqual((ghe.client(token: "t") as? GitHubClient)?.api.absoluteString, "https://github.example.com/api/v3")
        XCTAssertEqual(PipelineConnection(provider: .gitlab, url: "https://gitlab.com").title, "GitLab")
    }

    func testGitHubNestedGroupsResumeTheParent() {
        let raw = "##[group]Outer\nfirst\n##[group]Inner\ninner line\n##[endgroup]\nback in outer\n##[endgroup]\nafter"
        let log = JobLog.parseGitHub(raw)
        let outer = log.sections.first { $0.title == "Outer" }
        XCTAssertEqual(outer?.lines.map(\.text), ["first", "back in outer"])
        XCTAssertEqual(log.sections.first { $0.title == "Inner" }?.lines.map(\.text), ["inner line"])
        XCTAssertEqual(log.sections.last?.lines.map(\.text), ["after"])
    }

    func testGitHubPollsRecentAndRotatesTheRest() {
        let projects = (0..<60).map { i in
            GitLabProject(id: i, name: "r\(i)", path_with_namespace: "o/r\(i)", web_url: "", avatar_url: nil,
                          namespace: .init(id: 1, kind: "user", full_path: "o"), last_activity_at: Date(timeIntervalSince1970: Double(1000 - i)))
        }
        let gh = GitHubClient(web: URL(string: "https://github.com")!, token: "t")
        let r0 = gh.pollSet(projects, round: 0).map(\.id), r1 = gh.pollSet(projects, round: 1).map(\.id)
        XCTAssertEqual(Array(r0.prefix(30)), Array(0..<30))          // the 30 most recent every round
        XCTAssertEqual(Set(r0.dropFirst(30)), Set(30..<50))
        XCTAssertEqual(Set(r1.dropFirst(30)), Set((50..<60).map { $0 } + (30..<40).map { $0 }))   // the rest in turn
    }
}
