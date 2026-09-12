import ServiceManagement
import XCTest
@testable import DiskStewardApp

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testAdapterRegistersAndUnregistersMainAppService() {
        let service = FakeMainAppService()
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.isEnabled)

        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testAdapterPreservesObservedStatusWhenRegistrationFails() {
        let service = FakeMainAppService()
        service.shouldFail = true
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}

private final class FakeMainAppService: MainAppServiceBacking {
    var status: SMAppService.Status = .notRegistered
    var registerCount = 0
    var unregisterCount = 0
    var shouldFail = false

    func register() throws {
        registerCount += 1
        if shouldFail { throw NSError(domain: "fixture", code: 1) }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if shouldFail { throw NSError(domain: "fixture", code: 2) }
        status = .notRegistered
    }
}
