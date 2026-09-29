import Testing

extension Tag {
    /// Integration tests that run real Vision recognition on fixture pages (slow: up to about 15 s per page).
    @Tag static var integration: Self
    /// Performance records: print metrics and assert loose thresholds; the numbers go into the archived test results.
    @Tag static var performance: Self
}
