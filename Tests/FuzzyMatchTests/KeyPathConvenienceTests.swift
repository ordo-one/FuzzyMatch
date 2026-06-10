// ===----------------------------------------------------------------------===//
//
// This source file is part of the FuzzyMatch open source project
//
// Copyright (c) 2026 Ordo One, AB. and the FuzzyMatch project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
// ===----------------------------------------------------------------------===//

@testable import FuzzyMatch
import Testing

private struct Instrument: Equatable, Hashable, Sendable {
    let ticker: String
    let name: String
}

private let instruments = [
    Instrument(ticker: "AAPL", name: "Apple Inc"),
    Instrument(ticker: "MSFT", name: "Microsoft Corporation"),
    Instrument(ticker: "GOOG", name: "Alphabet Inc"),
    Instrument(ticker: "AMZN", name: "Amazon.com Inc"),
    Instrument(ticker: "META", name: "Meta Platforms Inc"),
    Instrument(ticker: "TSLA", name: "Tesla Inc"),
    Instrument(ticker: "JPM", name: "JPMorgan Chase & Co"),
    Instrument(ticker: "GS", name: "Goldman Sachs Group Inc"),
]

// MARK: - topMatches by KeyPath Tests

@Test func keyPathTopMatchesReturnsCorrectItems() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("apple")
    let results = matcher.topMatches(instruments, by: \.name, against: query, limit: 3)
    #expect(!results.isEmpty)
    #expect(results[0].item.ticker == "AAPL")
}

@Test func keyPathTopMatchesSortedByScoreDescending() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")
    let results = matcher.topMatches(instruments, by: \.name, against: query, limit: 10)
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

@Test func keyPathTopMatchesRespectsLimit() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")
    let results = matcher.topMatches(instruments, by: \.name, against: query, limit: 2)
    #expect(results.count <= 2)
}

@Test func keyPathTopMatchesDefaultLimitIs10() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")
    let results = matcher.topMatches(instruments, by: \.name, against: query)
    // Default limit is 10, we have 8 instruments so all matches should be returned
    #expect(results.count <= 10)
}

@Test func keyPathTopMatchesEmptyWhenNoMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("zzzzz")
    let results = matcher.topMatches(instruments, by: \.name, against: query, limit: 5)
    #expect(results.isEmpty)
}

@Test func keyPathTopMatchesEmptyCandidates() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("apple")
    let results = matcher.topMatches([] as [Instrument], by: \.name, against: query, limit: 5)
    #expect(results.isEmpty)
}

// MARK: - matches by KeyPath Tests

@Test func keyPathMatchesReturnsAllMatchingItems() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")
    let results = matcher.matches(instruments, by: \.name, against: query)
    #expect(!results.isEmpty)
    // All results should be sorted by score descending
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

@Test func keyPathMatchesEmptyForNoMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("zzzzz")
    let results = matcher.matches(instruments, by: \.name, against: query)
    #expect(results.isEmpty)
}

@Test func keyPathMatchesEmptyCandidates() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("apple")
    let results = matcher.matches([] as [Instrument], by: \.name, against: query)
    #expect(results.isEmpty)
}

// MARK: - String Query Overloads

@Test func keyPathStringQueryTopMatchesEquivalent() {
    let matcher = FuzzyMatcher()
    let queryStr = "apple"
    let prepared = matcher.prepare(queryStr)

    let fromPrepared = matcher.topMatches(instruments, by: \.name, against: prepared, limit: 5)
    let fromString = matcher.topMatches(instruments, by: \.name, against: queryStr, limit: 5)

    #expect(fromPrepared.count == fromString.count)
    for i in 0..<fromPrepared.count {
        #expect(fromPrepared[i].item == fromString[i].item,
                "Item mismatch at index \(i)")
        #expect(fromPrepared[i].match.score == fromString[i].match.score,
                "Score mismatch at index \(i)")
        #expect(fromPrepared[i].match.kind == fromString[i].match.kind,
                "Kind mismatch at index \(i)")
    }
}

@Test func keyPathStringQueryMatchesEquivalent() {
    let matcher = FuzzyMatcher()
    let queryStr = "inc"
    let prepared = matcher.prepare(queryStr)

    let fromPrepared = matcher.matches(instruments, by: \.name, against: prepared)
    let fromString = matcher.matches(instruments, by: \.name, against: queryStr)

    #expect(fromPrepared.count == fromString.count)
    for i in 0..<fromPrepared.count {
        #expect(fromPrepared[i].item == fromString[i].item,
                "Item mismatch at index \(i)")
        #expect(fromPrepared[i].match.score == fromString[i].match.score,
                "Score mismatch at index \(i)")
    }
}

// MARK: - Different Key Paths

@Test func keyPathMatchesByTicker() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("AAPL")
    let results = matcher.topMatches(instruments, by: \.ticker, against: query, limit: 3)
    #expect(!results.isEmpty)
    #expect(results[0].item.ticker == "AAPL")
    #expect(results[0].match.kind == .exact)
}

@Test func keyPathDifferentKeyPathsDifferentResults() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("meta")

    let byName = matcher.matches(instruments, by: \.name, against: query)
    let byTicker = matcher.matches(instruments, by: \.ticker, against: query)

    let nameItems = Set(byName.map { $0.item.ticker })
    let tickerItems = Set(byTicker.map { $0.item.ticker })

    // "meta" should match "Meta Platforms Inc" by name and "META" by ticker
    #expect(nameItems.contains("META"))
    #expect(tickerItems.contains("META"))
}

// MARK: - Equivalence with String API

@Test func keyPathResultsMatchStringAPIResults() {
    let matcher = FuzzyMatcher()
    let queryStr = "gold"
    let query = matcher.prepare(queryStr)

    // Key-path API
    let keyPathResults = matcher.matches(instruments, by: \.name, against: query)

    // String API with extracted names
    let names = instruments.map { $0.name }
    let stringResults = matcher.matches(names, against: query)

    #expect(keyPathResults.count == stringResults.count,
            "Count mismatch: keyPath=\(keyPathResults.count) string=\(stringResults.count)")
    for i in 0..<keyPathResults.count {
        #expect(keyPathResults[i].item.name == stringResults[i].candidate,
                "Candidate mismatch at index \(i)")
        #expect(keyPathResults[i].match.score == stringResults[i].match.score,
                "Score mismatch at index \(i)")
        #expect(keyPathResults[i].match.kind == stringResults[i].match.kind,
                "Kind mismatch at index \(i)")
    }
}

// MARK: - Cross-method Consistency

@Test func keyPathTopMatchesSubsetOfMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")

    let all = matcher.matches(instruments, by: \.name, against: query)
    let top3 = matcher.topMatches(instruments, by: \.name, against: query, limit: 3)

    let allTop3 = Array(all.prefix(3))
    #expect(top3.count == allTop3.count)
    for i in 0..<top3.count {
        #expect(top3[i].item == allTop3[i].item,
                "Item mismatch at \(i): topMatches=\(top3[i].item) matches=\(allTop3[i].item)")
        #expect(top3[i].match.score == allTop3[i].match.score,
                "Score mismatch at \(i)")
    }
}

@Test func keyPathTopMatchesLimitExceedingCountEqualsMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("inc")

    let all = matcher.matches(instruments, by: \.name, against: query)
    let topAll = matcher.topMatches(instruments, by: \.name, against: query, limit: 1_000)

    #expect(all.count == topAll.count)
}
