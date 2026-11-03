import Foundation
struct JiraIssue: Decodable {
    let key: String
    let fields: [String: AnyDecodable]
}
// since I can't easily compile the whole project with dependencies, I'll just check if there's a cached response.
