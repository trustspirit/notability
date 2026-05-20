import Foundation

struct MeetingNotes: Codable, Equatable {
    var summary: String
    var actionItems: [ActionItem]
    var keyDecisions: [String]
}

struct ActionItem: Codable, Equatable, Identifiable {
    let id: UUID
    var description: String
    var assignee: String?
    var dueDate: String?
    var isCompleted: Bool
}
