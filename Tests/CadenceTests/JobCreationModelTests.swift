import XCTest
import LaunchCore
@testable import Cadence

final class JobCreationModelTests: XCTestCase {
    @MainActor
    func testCreationRevealsSavedJobDespitePreviousSearchAndFilter() async throws {
        let service = CreationService()
        let model = AppModel(service: service)
        model.query = "an unrelated search"
        model.filter = .disabled
        model.tab = .logs
        let job = try await model.createJob(JobDraft(name: "Created job", command: "/usr/bin/true", cronExpression: "0 9 * * *"))
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.tab, .overview)
        XCTAssertEqual(model.selectedJob?.id, job.id)
        XCTAssertEqual(model.selectedJob?.name, "Created job")
        XCTAssertTrue(model.busyJobs.isEmpty)
    }

    @MainActor
    func testSavedButUnloadedWarningStillCompletesCreation() async throws {
        let model = AppModel(service: CreationService(warning: "Saved, but registration failed."))
        _ = try await model.createJob(JobDraft(name: "Created job", command: "/usr/bin/true", cronExpression: "0 9 * * *"))
        XCTAssertEqual(model.error, "Saved, but registration failed.")
        XCTAssertNotNil(model.selectedJob)
        XCTAssertTrue(model.busyJobs.isEmpty)
    }

    @MainActor
    func testFailedCreationReleasesBusyStateAndPreservesView() async {
        let model = AppModel(service: CreationService(shouldFail: true))
        model.query = "existing search"
        do {
            _ = try await model.createJob(JobDraft(name: "Created job", command: "/usr/bin/true", cronExpression: "0 9 * * *"))
            XCTFail("Expected write failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("write failed")) }
        XCTAssertTrue(model.busyJobs.isEmpty)
        XCTAssertEqual(model.query, "existing search")
    }

    @MainActor
    func testFormValidationAndPathQuoting() throws {
        let form = NewJobFormModel()
        XCTAssertNotNil(form.validationMessage)
        form.name = "Daily backup"
        form.command = "/usr/bin/true"
        form.expression = "0 9 * * *"
        XCTAssertNil(form.validationMessage)
        form.workingDirectory = "relative/path"
        XCTAssertThrowsError(try form.validatedDraft())
        form.workingDirectory = ""
        form.expression = "0 9 * * MON"
        XCTAssertNotNil(form.scheduleError)
        XCTAssertNotNil(form.validationMessage)
        XCTAssertEqual(NewJobFormModel.quotePath("/tmp/a b's.sh"), "'/tmp/a b'\\''s.sh'")
    }
}

private actor CreationService: JobServing {
    let warning: String?
    let shouldFail: Bool
    private var jobs: [LaunchJob] = []

    init(warning: String? = nil, shouldFail: Bool = false) {
        self.warning = warning
        self.shouldFail = shouldFail
    }
    func discover() async throws -> DiscoveryResult { DiscoveryResult(jobs: jobs) }
    func setEnabled(_ enabled: Bool, job: LaunchJob) async throws {}
    func runNow(job: LaunchJob) async throws {}
    func readLog(job: LaunchJob, stream: LogStream) async -> LogSnapshot { LogSnapshot(text: "") }
    func createJob(_ draft: JobDraft) async throws -> JobCreationResult {
        if shouldFail { throw LaunchServiceError.unavailable("Fixture write failed") }
        let job = LaunchJob(label: "dev.cadence.fixture", name: draft.name,
            plistURL: URL(fileURLWithPath: "/tmp/dev.cadence.fixture.plist"), program: "/bin/zsh",
            arguments: ["-c", draft.command], scheduleDescription: "Daily at 09:00",
            isEnabled: draft.isEnabled, status: warning == nil ? .waiting : .unloaded)
        jobs = [job]
        return JobCreationResult(job: job, warning: warning)
    }
}
