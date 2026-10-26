import XCTest
import LaunchCore
@testable import Cadence

final class AppModelTests: XCTestCase {
    @MainActor
    func testToggleDuringRefreshWaitsThenMutatesAndRereads() async {
        let service = SuspendedService()
        let model = AppModel(service: service)
        let job = LaunchJob(label: "fixture", name: "Fixture", plistURL: URL(fileURLWithPath: "/tmp/fixture.plist"),
            program: "/bin/echo", scheduleDescription: "On demand", isEnabled: true, status: .waiting)
        let refresh = Task { await model.refresh() }
        await service.waitForInitialRead()
        XCTAssertTrue(model.isRefreshing)
        model.setEnabled(false, job: job)
        XCTAssertTrue(model.busyJobs.contains(job.id), "A click during refresh must remain pending.")
        // Resume the read. The pending click must execute once, then reread state.
        await service.resumeInitialRead()
        await refresh.value
        await service.waitForFinalRead()
        let mutations = await service.requestedStates
        XCTAssertEqual(mutations, [false])
    }
}

private actor SuspendedService: JobServing {
    private var readCount = 0
    private var initialRead: CheckedContinuation<DiscoveryResult, Never>?
    private var initialObservers: [CheckedContinuation<Void, Never>] = []
    private var finalObservers: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedStates: [Bool] = []

    func discover() async throws -> DiscoveryResult {
        readCount += 1
        if readCount == 1 {
            return await withCheckedContinuation { continuation in
                initialRead = continuation
                initialObservers.forEach { $0.resume() }
                initialObservers.removeAll()
            }
        }
        finalObservers.forEach { $0.resume() }
        finalObservers.removeAll()
        return DiscoveryResult(jobs: [])
    }

    func setEnabled(_ enabled: Bool, job: LaunchJob) async throws { requestedStates.append(enabled) }
    func runNow(job: LaunchJob) async throws {}
    func createJob(_ draft: JobDraft) async throws -> JobCreationResult { throw LaunchServiceError.unavailable("Unused test operation") }
    func readLog(job: LaunchJob, stream: LogStream) async -> LogSnapshot { LogSnapshot(text: "") }
    func waitForInitialRead() async {
        if initialRead != nil { return }
        await withCheckedContinuation { initialObservers.append($0) }
    }
    func resumeInitialRead() {
        initialRead?.resume(returning: DiscoveryResult(jobs: []))
        initialRead = nil
    }
    func waitForFinalRead() async {
        if readCount > 1 { return }
        await withCheckedContinuation { finalObservers.append($0) }
    }
}
