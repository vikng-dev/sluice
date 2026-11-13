import Foundation

/// The accounts on GitHub whose name is like `text`, by its public search (docs/wire.md). The search is
/// asked as nobody, which allows ten a minute; past that, or when it cannot be reached, there are none,
/// and the owner is typed in full.
func githubOwners(like text: String) async -> [String] {
    struct Found: Decodable {
        struct Item: Decodable { let login: String }
        let items: [Item]
    }
    var address = URLComponents(string: "https://api.github.com/search/users")!
    address.queryItems = [URLQueryItem(name: "q", value: "\(text) in:login"), URLQueryItem(name: "per_page", value: "6")]
    var request = URLRequest(url: address.url!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
          let found = try? JSONDecoder().decode(Found.self, from: data) else { return [] }
    return found.items.map(\.login)
}
