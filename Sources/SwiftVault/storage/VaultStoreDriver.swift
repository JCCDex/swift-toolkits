import Foundation

protocol VaultStoreDriver {
    func load() throws -> VaultStoreSnapshot
    func save(_ snapshot: VaultStoreSnapshot) throws
}
