import CryptoKit
import Foundation
import Testing
@testable import ReadStairCore

/// U-LEX-001–002: lexicon lookup speed, and the licenses of every data directory.
@Suite("U-LEX Lexicon")
struct LexiconDataTests {
    /// A single run can take 20 ms when the machine is busy, so only the median of 20 runs is asserted.
    @Test("U-LEX-001 Lemma and band of every word on one 226-word page: median of 20 runs ≤ 50 ms, the lexicon already parsed")
    func pageLookupSpeed() throws {
        let truth = try JSONDecoder().decode(RecognitionIntegrationTests.Truth.self,
                                             from: Data(contentsOf: fixtureURL("Fixtures/alice-p1.json")))
        let keys = truth.words.prefix(226).map { PageWord.key($0.text) }
        try #require(keys.count == 226)
        let lexicon = Lexicon.bundled
        var banded = 0
        var times: [Duration] = []
        for _ in 0..<20 {
            banded = 0
            times.append(ContinuousClock().measure {
                for key in keys where lexicon.band(ofLemma: lexicon.lemma(of: key)) != nil { banded += 1 }
            })
        }
        let median = percentile(0.5, times)
        ExperimentLog.record(["test": "U-LEX-001", "median_ms": median, "max_ms": times.max() ?? .zero, "banded": banded])
        #expect(median <= .milliseconds(50), "median \(median)")
    }

    /// Every data directory carries its own license and attribution: each one under Data/, Fixtures/ and the bundled lexicon. The
    /// lexicon's ATTRIBUTION.md lists the SHA-256 of each table, so a hand edit of a generated table fails here in every environment.
    @Test("U-LEX-002 Every data directory has a LICENSE and an ATTRIBUTION.md; the lexicon's attribution lists each table's SHA-256 and its license carries both notices")
    func licenses() throws {
        let files = FileManager.default
        func subdirectories(_ url: URL) throws -> [URL] {
            try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        let lexicon = try #require(Lexicon.directory)
        let data = try subdirectories(fixtureURL("Data"))
        try #require(!data.isEmpty, "no directories under Data/")
        for directory in data + [fixtureURL("Fixtures"), lexicon] {
            for name in ["LICENSE", "ATTRIBUTION.md"] {
                #expect(!text(directory.appending(path: name)).isEmpty, "\(directory.lastPathComponent)/\(name) is missing or empty")
            }
        }

        let attribution = text(lexicon.appending(path: "ATTRIBUTION.md"))
        let tables = try files.contentsOfDirectory(at: lexicon, includingPropertiesForKeys: nil).filter { $0.pathExtension == "tsv" }
        #expect(Set(tables.map(\.lastPathComponent)).isSuperset(of: ["bands.tsv", "forms.tsv"]))
        for table in tables {
            let digest = try SHA256.hash(data: Data(contentsOf: table)).map { String(format: "%02x", $0) }.joined()
            #expect(attribution.contains(digest), "\(table.lastPathComponent) has SHA-256 \(digest), not listed in ATTRIBUTION.md")
        }
        let license = text(lexicon.appending(path: "LICENSE"))
        #expect(license.contains("Attribution-ShareAlike 4.0"))
        #expect(license.contains("WordNet 3.0 Copyright 2006 by Princeton University"))
    }
}
