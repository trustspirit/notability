import Foundation

/// Runs `operation`, returning after `deadline` whether or not it has finished.
///
/// For work that has to be attempted but must not be able to hold anything up:
/// releasing an operating system resource on the way out, where the framework
/// owning it does not promise to call back at all.
///
/// Deliberately not a task group. `withTaskGroup` does not return until every
/// child has returned, cancelled or not, so a child that never finishes would
/// take the deadline down with it — and a suspension that never resumes is the
/// one case this exists for. Missing the deadline cancels the work and leaves
/// it, which is all that can be done: cancellation is cooperative, and a task
/// suspended inside a framework that has stopped answering will not notice it.
@MainActor
func withDeadline(
    _ deadline: Duration,
    _ operation: @escaping @MainActor () async -> Void
) async {
    let (finished, signal) = AsyncStream<Void>.makeStream()

    let work = Task { @MainActor in
        await operation()
        signal.yield()
    }
    let timer = Task {
        try? await Task.sleep(for: deadline)
        signal.yield()
    }
    defer {
        work.cancel()
        timer.cancel()
    }

    var whicheverIsFirst = finished.makeAsyncIterator()
    _ = await whicheverIsFirst.next()
}
