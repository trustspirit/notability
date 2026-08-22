import XCTest
@testable import Notability

/// Relaunching to pick up a permission grant has to survive the app declining to
/// quit. `applicationShouldTerminate` refuses while a recording is in flight, and
/// the version this replaces had already launched the replacement by then: the
/// user kept recording in an app that would not close, with a second instance
/// running behind it.
@MainActor
final class RelauncherTests: XCTestCase {

    func test_nothing_launches_when_no_relaunch_was_asked_for() {
        let spy = LaunchSpy()
        let sut = Relauncher(launchSuccessor: spy.launch)

        sut.launchSuccessorIfRequested()

        XCTAssertEqual(spy.count, 0, "An ordinary quit must not start the app again")
    }

    /// The reported bug: the user picks Continue Recording, so termination never
    /// happens and there must be no replacement waiting in the wings.
    func test_a_declined_quit_leaves_no_second_instance() {
        let spy = LaunchSpy()
        let sut = Relauncher(launchSuccessor: spy.launch)

        sut.requestRelaunchAfterTermination()

        XCTAssertEqual(
            spy.count, 0,
            "Requesting the relaunch must not launch anything on its own — only "
                + "termination actually going through may"
        )
    }

    func test_the_replacement_launches_once_termination_goes_through() {
        let spy = LaunchSpy()
        let sut = Relauncher(launchSuccessor: spy.launch)

        sut.requestRelaunchAfterTermination()
        sut.launchSuccessorIfRequested()

        XCTAssertEqual(spy.count, 1)
    }

    /// Asking twice is reachable: the permission alert can be dismissed with
    /// Continue Recording and opened again from the banner.
    func test_asking_twice_still_launches_one_replacement() {
        let spy = LaunchSpy()
        let sut = Relauncher(launchSuccessor: spy.launch)

        sut.requestRelaunchAfterTermination()
        sut.requestRelaunchAfterTermination()
        sut.launchSuccessorIfRequested()

        XCTAssertEqual(spy.count, 1)
    }

    func test_the_request_does_not_survive_the_termination_it_was_made_for() {
        let spy = LaunchSpy()
        let sut = Relauncher(launchSuccessor: spy.launch)

        sut.requestRelaunchAfterTermination()
        sut.launchSuccessorIfRequested()
        sut.launchSuccessorIfRequested()

        XCTAssertEqual(spy.count, 1, "AppKit may deliver the notification more than once")
    }

    private final class LaunchSpy {
        private(set) var count = 0
        func launch() { count += 1 }
    }
}
