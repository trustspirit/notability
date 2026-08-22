import XCTest
@testable import Notability

final class LiveCaptionAggregatorTests: XCTestCase {

    func test_starts_empty() {
        let aggregator = LiveCaptionAggregator()
        XCTAssertTrue(aggregator.visibleRows.isEmpty)
        XCTAssertNil(aggregator.notice)
    }

    func test_volatile_row_carries_its_sources_speaker_label() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.volatile(source: .systemAudio, text: "잠시만요", startTime: 3))

        XCTAssertEqual(aggregator.visibleRows.count, 1)
        XCTAssertEqual(aggregator.visibleRows[0].text, "잠시만요")
        XCTAssertEqual(aggregator.visibleRows[0].speaker, "상대방")
        XCTAssertEqual(aggregator.visibleRows[0].timestamp, 3)
    }

    func test_volatile_row_is_replaced_per_source_not_accumulated() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.volatile(source: .microphone, text: "안", startTime: 0))
        aggregator.apply(.volatile(source: .microphone, text: "안녕", startTime: 0))
        aggregator.apply(.volatile(source: .microphone, text: "안녕하세요", startTime: 0))

        XCTAssertEqual(aggregator.visibleRows.map(\.text), ["안녕하세요"])
    }

    func test_each_source_keeps_its_own_volatile_row() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.volatile(source: .microphone, text: "제가", startTime: 0))
        aggregator.apply(.volatile(source: .systemAudio, text: "네", startTime: 1))

        XCTAssertEqual(aggregator.visibleRows.map(\.text), ["제가", "네"])
    }

    func test_finalized_row_clears_only_its_own_volatile_row() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.volatile(source: .microphone, text: "제가", startTime: 0))
        aggregator.apply(.volatile(source: .systemAudio, text: "네", startTime: 1))
        aggregator.apply(.finalized(source: .microphone, text: "제가 하겠습니다.", startTime: 0))

        XCTAssertEqual(aggregator.visibleRows.map(\.text), ["제가 하겠습니다.", "네"])
    }

    func test_finalized_rows_keep_arrival_order() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.finalized(source: .microphone, text: "두 번째로 확정", startTime: 20))
        aggregator.apply(.finalized(source: .systemAudio, text: "먼저 확정", startTime: 5))

        // Sorting by timestamp would make a row the user has already read jump
        // down the list every time the other source confirms an earlier segment.
        XCTAssertEqual(aggregator.visibleRows.map(\.text), ["두 번째로 확정", "먼저 확정"])
    }

    func test_volatile_rows_always_sort_after_finalized_rows() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.finalized(source: .microphone, text: "확정", startTime: 10))
        aggregator.apply(.volatile(source: .systemAudio, text: "임시", startTime: 1))

        XCTAssertEqual(aggregator.visibleRows.map(\.text), ["확정", "임시"])
    }

    func test_download_progress_is_rendered_as_a_percentage() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.downloading(progress: 0.42))
        XCTAssertEqual(aggregator.notice, "Downloading the on-device speech model… 42%")

        aggregator.apply(.downloading(progress: 1))
        XCTAssertEqual(aggregator.notice, "Downloading the on-device speech model… 100%")
    }

    func test_ready_clears_a_download_notice() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.downloading(progress: 0.5))
        aggregator.apply(.ready)
        XCTAssertNil(aggregator.notice)
    }

    func test_unavailable_notice_outlives_ready() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.unavailable("Live captions unavailable for systemAudio"))
        aggregator.apply(.ready)

        // The service reports one source failing and then `.ready` for the other,
        // so `.ready` cannot be taken as "everything is fine".
        XCTAssertEqual(aggregator.notice, "Live captions unavailable for systemAudio")
    }

    func test_unavailable_notice_outranks_download_progress() {
        var aggregator = LiveCaptionAggregator()
        aggregator.apply(.unavailable("Model not installed"))
        aggregator.apply(.downloading(progress: 0.1))

        XCTAssertEqual(aggregator.notice, "Model not installed")
    }

    func test_notice_events_do_not_report_a_row_change() {
        var aggregator = LiveCaptionAggregator()
        XCTAssertFalse(aggregator.apply(.downloading(progress: 0.1)).rowsChanged)
        XCTAssertFalse(aggregator.apply(.downloading(progress: 0.1)).noticeChanged)
        XCTAssertTrue(aggregator.apply(.volatile(source: .microphone, text: "가", startTime: 0)).rowsChanged)
    }

    func test_repeated_identical_volatile_text_reports_no_change() {
        var aggregator = LiveCaptionAggregator()
        _ = aggregator.apply(.volatile(source: .microphone, text: "안녕", startTime: 0))

        // Volatile results arrive several times a second and are frequently the
        // same string; republishing each one is pointless SwiftUI work.
        XCTAssertFalse(
            aggregator.apply(.volatile(source: .microphone, text: "안녕", startTime: 0)).rowsChanged
        )
    }
}
