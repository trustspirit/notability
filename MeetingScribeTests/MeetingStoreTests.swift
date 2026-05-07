// MeetingScribeTests/MeetingStoreTests.swift
import XCTest
import Combine
@testable import MeetingScribe

final class MeetingStoreTests: XCTestCase {
    var sut: MeetingStore!
    var tempDir: URL!
    var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = MeetingStore(storageDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_save_and_fetch() {
        let meeting = makeMeeting(title: "Alpha")
        sut.save(meeting)
        XCTAssertEqual(sut.fetch(id: meeting.id)?.title, "Alpha")
    }

    func test_all_returns_sorted_by_date_descending() {
        let early = makeMeeting(title: "Early", date: Date(timeIntervalSince1970: 100))
        let late  = makeMeeting(title: "Late",  date: Date(timeIntervalSince1970: 200))
        sut.save(early)
        sut.save(late)
        let all = sut.allMeetings
        XCTAssertEqual(all.first?.title, "Late")
    }

    func test_delete_removes_meeting() {
        let meeting = makeMeeting(title: "ToDelete")
        sut.save(meeting)
        sut.delete(id: meeting.id)
        XCTAssertNil(sut.fetch(id: meeting.id))
    }

    func test_persists_across_instances() {
        let meeting = makeMeeting(title: "Persisted")
        sut.save(meeting)

        let sut2 = MeetingStore(storageDirectory: tempDir)
        XCTAssertEqual(sut2.fetch(id: meeting.id)?.title, "Persisted")
    }

    func test_meetings_publisher_emits_on_save() {
        let expectation = expectation(description: "publisher emits")
        var received: [Meeting] = []

        sut.$allMeetings
            .dropFirst()
            .sink { meetings in
                received = meetings
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.save(makeMeeting(title: "New"))
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received.first?.title, "New")
    }

    private func makeMeeting(title: String, date: Date = Date()) -> Meeting {
        Meeting(id: UUID(), title: title, date: date, durationSeconds: 0, transcript: [], notes: nil, notesGenerationError: nil)
    }
}
