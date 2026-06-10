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

// Verifies `EditDistanceConfig.isSubsequenceMatchingEnabled`. With it disabled (alongside
// `maxEditDistance: 0` and `acronymWeight: 0`) the matcher becomes a literal, case- and
// diacritic-insensitive `contains`: only contiguous occurrences survive.

private func strictContains() -> FuzzyMatcher {
    FuzzyMatcher(config: .init(algorithm: .editDistance(.init(
        maxEditDistance: 0,
        acronymWeight: 0,
        isSubsequenceMatchingEnabled: false
    ))))
}

@Test func defaultMatchesGapBasedSubsequence() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("usd")
    var buffer = matcher.makeBuffer()
    // "usd" appears in order but scattered across "indUS holDing".
    let result = matcher.score("INDUS HOLDING", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .substring)
}

@Test func strictRejectsGapBasedSubsequence() {
    let matcher = strictContains()
    let query = matcher.prepare("usd")
    var buffer = matcher.makeBuffer()
    #expect(matcher.score("INDUS HOLDING", against: query, buffer: &buffer) == nil)
}

@Test func strictRejectsAcronym() {
    let matcher = strictContains()
    let query = matcher.prepare("usd")
    var buffer = matcher.makeBuffer()
    // "usd" is the word-initial acronym of "United States Dollar" — must not match.
    #expect(matcher.score("United States Dollar", against: query, buffer: &buffer) == nil)
}

@Test func strictMatchesContiguousSubstring() {
    let matcher = strictContains()
    let query = matcher.prepare("dus")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("INDUS HOLDING", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .substring)
}

@Test func strictMatchesExactAndPrefix() {
    let matcher = strictContains()
    var buffer = matcher.makeBuffer()
    #expect(matcher.score("USD", against: matcher.prepare("usd"), buffer: &buffer)?.kind == .exact)
    #expect(matcher.score("USD/JPY", against: matcher.prepare("usd"), buffer: &buffer)?.kind == .prefix)
}

@Test func strictStaysDiacriticInsensitive() {
    let matcher = strictContains()
    var buffer = matcher.makeBuffer()
    // Diacritic folding survives because it happens during normalization, not via the
    // subsequence phase.
    #expect(matcher.score("café", against: matcher.prepare("cafe"), buffer: &buffer)?.kind == .exact)
    #expect(matcher.score("Le Café Noir", against: matcher.prepare("cafe"), buffer: &buffer)?.kind == .substring)
}
