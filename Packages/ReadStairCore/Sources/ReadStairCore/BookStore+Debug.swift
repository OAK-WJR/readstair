#if DEBUG
import Foundation

// Debug builds only: hooks for UI tests that need an iCloud change without an iCloud account.
extension BookStore {
    /// Applies a level as if iCloud had delivered it, through the same merge as a fetched record: with no level row it becomes the
    /// level (not marked for upload), a placeholder yields to it, and a newer chosen level keeps its place. Publishes `.profile` like
    /// any fetched change. Lets a UI test check that a level arriving during the first-launch test changes nothing on screen.
    public func applyCloudLevelForTesting(_ level: Int, at date: Date = .now) throws(StoreError) {
        let value = SyncedValue.profile(SyncedProfile(level: level, updatedAt: SyncRules.milliseconds(date)))
        _ = try applyFetched([.saved(SyncRecord(name: SyncRules.profileRecordName, systemFields: nil, value: value))])
    }
}
#endif
