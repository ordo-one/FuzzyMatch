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

/// Validates the Span polyfill logic indirectly.
///
/// On Swift 6.2+ the real `Swift.Span` is used and `SpanPolyfill.swift` is dead code.
/// These tests validate correctness through three complementary strategies:
///
/// 1. **TestSpan struct** — an always-compiled replica of the polyfill, unit-tested directly
/// 2. **Byte equivalence** — proves `String.withUTF8` gives the same bytes as `String.utf8.span`
/// 3. **Scoring equivalence** — proves the `withUTF8 → Array → .span` byte path produces
///    identical scores to the `utf8.span` path through both ED and SW pipelines

@testable import FuzzyMatch
import Testing

// MARK: - TestSpan: Always-compiled polyfill replica

/// Exact replica of `SpanPolyfill.swift`'s `Span` struct (minus attributes).
/// Always compiled regardless of Swift version, so we can test its logic.
private struct TestSpan<Element> {
    let pointer: UnsafePointer<Element>
    let count: Int

    init(_ buffer: UnsafeBufferPointer<Element>) {
        pointer = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        count = buffer.count
    }

    subscript(index: Int) -> Element {
        pointer[index]
    }

    func extracting(_ range: Range<Int>) -> TestSpan {
        TestSpan(UnsafeBufferPointer(start: pointer + range.lowerBound, count: range.count))
    }
}

// MARK: - TestSpan Unit Tests

@Suite("TestSpan (polyfill replica) unit tests")
struct TestSpanTests {
    @Test("Subscript access returns correct elements")
    func subscriptAccess() {
        let array: [UInt8] = [10, 20, 30, 40, 50]
        array.withUnsafeBufferPointer { buf in
            let span = TestSpan(buf)
            #expect(span.count == 5)
            #expect(span[0] == 10)
            #expect(span[2] == 30)
            #expect(span[4] == 50)
        }
    }

    @Test("Extracting sub-range returns correct slice")
    func extractingSubRange() {
        let array: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        array.withUnsafeBufferPointer { buf in
            let span = TestSpan(buf)
            let sub = span.extracting(2 ..< 5)
            #expect(sub.count == 3)
            #expect(sub[0] == 2)
            #expect(sub[1] == 3)
            #expect(sub[2] == 4)
        }
    }

    @Test("Empty array buffer has count 0")
    func emptyArrayBuffer() {
        let empty: [UInt8] = []
        empty.withUnsafeBufferPointer { buf in
            let span = TestSpan(buf)
            #expect(span.count == 0)
            // Empty Array may still have a non-nil baseAddress (internal storage),
            // so we only verify count here.
        }
    }

    @Test("Nil-baseAddress buffer gets sentinel pointer")
    func nilBaseAddressSentinel() {
        let buf = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        let span = TestSpan(buf)
        #expect(span.count == 0)
        // When baseAddress is nil, the polyfill uses a sentinel (bitPattern: 1)
        #expect(span.pointer == UnsafePointer(bitPattern: 1)!)
    }

    @Test("TestSpan elements match Array.span element-by-element")
    func elementsMatchRealSpan() {
        let array: [UInt8] = [72, 101, 108, 108, 111] // "Hello"
        array.withUnsafeBufferPointer { buf in
            let testSpan = TestSpan(buf)
            let realSpan = array.span
            #expect(testSpan.count == realSpan.count)
            for i in 0 ..< testSpan.count {
                #expect(testSpan[i] == realSpan[i], "Mismatch at index \(i)")
            }
        }
    }

    @Test("Nested extracting produces correct elements")
    func nestedExtracting() {
        let array: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        array.withUnsafeBufferPointer { buf in
            let span = TestSpan(buf)
            let mid = span.extracting(2 ..< 8) // [2,3,4,5,6,7]
            let inner = mid.extracting(1 ..< 4) // [3,4,5]
            #expect(inner.count == 3)
            #expect(inner[0] == 3)
            #expect(inner[1] == 4)
            #expect(inner[2] == 5)
        }
    }
}

// MARK: - Byte Equivalence Tests

@Suite("Byte equivalence: withUTF8 vs utf8.span")
struct ByteEquivalenceTests {
    static let testStrings: [(label: String, value: String)] = [
        ("empty", ""),
        ("ascii", "hello world"),
        ("camelCase", "getUserById"),
        ("diacritics", "café résumé naïve"),
        ("emoji", "hello 🌍🎉"),
        ("mixed", "Config_v2.json"),
        ("underscores", "get_user_by_id"),
        ("digits", "test123value456"),
        ("latin extended", "Ångström Ölüdeniz"),
    ]

    @Test("Every byte from withUTF8 matches utf8.span", arguments: testStrings)
    func byteEquivalence(label _: String, value: String) {
        // Path A: withUTF8
        var withUTF8Bytes: [UInt8] = []
        var mutValue = value
        mutValue.withUTF8 { buffer in
            withUTF8Bytes = Array(buffer)
        }

        // Path B: utf8.span
        let spanBytes = value.utf8
        let spanArray = Array(spanBytes)

        #expect(withUTF8Bytes.count == spanArray.count, "Length mismatch for '\(value)'")
        for i in 0 ..< withUTF8Bytes.count {
            #expect(withUTF8Bytes[i] == spanArray[i], "Byte mismatch at index \(i) for '\(value)'")
        }
    }
}

// MARK: - Scoring Equivalence Tests

@Suite("Scoring equivalence: utf8.span vs withUTF8 → Array → span")
struct ScoringEquivalenceTests {
    /// Scores a candidate through the "polyfill path": candidate.withUTF8 → Array → .span
    /// then calls the internal scoring method directly with the array span.
    private static func scoreViaArraySpan(
        _ candidate: String,
        against query: FuzzyQuery,
        matcher: FuzzyMatcher
    ) -> ScoredMatch? {
        // Simulate the polyfill path: get bytes via withUTF8, copy into an Array
        var mutCandidate = candidate
        var capturedBytes: [UInt8] = []
        mutCandidate.withUTF8 { buffer in
            capturedBytes = Array(buffer)
        }

        var buffer = matcher.makeBuffer()
        buffer.recordUsage(queryLength: query.lowercased.count, candidateLength: capturedBytes.count)

        let candidateBytes = capturedBytes.span

        switch query.config.algorithm {
        case .smithWaterman(let swConfig):
            return matcher.scoreSmithWatermanImpl(
                candidateBytes,
                against: query,
                swConfig: swConfig,
                candidateStorage: &buffer.candidateStorage,
                smithWatermanState: &buffer.smithWatermanState,
                wordInitials: &buffer.wordInitials
            )

        case .editDistance(let edConfig):
            if query.lowercased.count == 1 {
                return matcher.scoreTinyQuery1(
                    candidateBytes,
                    candidateLength: capturedBytes.count,
                    q0: query.lowercased[0],
                    edConfig: edConfig,
                    minScore: query.config.minScore
                )
            }
            return matcher.scoreImpl(
                candidateBytes,
                against: query,
                edConfig: edConfig,
                candidateStorage: &buffer.candidateStorage,
                editDistanceState: &buffer.editDistanceState,
                matchPositions: &buffer.matchPositions,
                alignmentState: &buffer.alignmentState,
                wordInitials: &buffer.wordInitials
            )
        }
    }

    // MARK: - Edit Distance: Multi-char queries

    static let edMultiCharPairs: [(query: String, candidate: String)] = [
        ("user", "getUserById"),
        ("config", "MatchConfig.swift"),
        ("get", "getUserById"),
        ("test", "testValue123"),
        ("abc", "abcdef"),
        ("hello", "Hello World"),
        ("café", "café résumé"),
        ("usr", "user"),
    ]

    @Test("ED multi-char: scores match between paths", arguments: edMultiCharPairs)
    func edMultiCharEquivalence(query: String, candidate: String) {
        let matcher = FuzzyMatcher()
        let prepared = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        let pathA = matcher.score(candidate, against: prepared, buffer: &buffer)
        let pathB = Self.scoreViaArraySpan(candidate, against: prepared, matcher: matcher)

        if let a = pathA, let b = pathB {
            #expect(
                abs(a.score - b.score) < 1e-10,
                "Score mismatch for '\(query)' vs '\(candidate)': \(a.score) != \(b.score)"
            )
            #expect(a.kind == b.kind, "Kind mismatch for '\(query)' vs '\(candidate)': \(a.kind) != \(b.kind)")
        } else {
            #expect(pathA == nil && pathB == nil, "Nil mismatch for '\(query)' vs '\(candidate)'")
        }
    }

    // MARK: - Edit Distance: Tiny query (1-char fast path)

    static let edTinyPairs: [(query: String, candidate: String)] = [
        ("a", "Apple"),
        ("g", "getUserById"),
        ("x", "index"),
        ("u", "User"),
        ("5", "test5value"),
        ("z", "fuzzy"),
    ]

    @Test("ED tiny query: scores match between paths", arguments: edTinyPairs)
    func edTinyQueryEquivalence(query: String, candidate: String) {
        let matcher = FuzzyMatcher()
        let prepared = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        let pathA = matcher.score(candidate, against: prepared, buffer: &buffer)
        let pathB = Self.scoreViaArraySpan(candidate, against: prepared, matcher: matcher)

        if let a = pathA, let b = pathB {
            #expect(
                abs(a.score - b.score) < 1e-10,
                "Score mismatch for '\(query)' vs '\(candidate)': \(a.score) != \(b.score)"
            )
            #expect(a.kind == b.kind, "Kind mismatch for '\(query)' vs '\(candidate)': \(a.kind) != \(b.kind)")
        } else {
            #expect(pathA == nil && pathB == nil, "Nil mismatch for '\(query)' vs '\(candidate)'")
        }
    }

    // MARK: - Smith-Waterman

    static let swPairs: [(query: String, candidate: String)] = [
        ("user", "getUserById"),
        ("config", "MatchConfig.swift"),
        ("hello", "Hello World"),
        ("get user", "getUserById"),
        ("abc", "a_big_cat"),
    ]

    @Test("SW: scores match between paths", arguments: swPairs)
    func swEquivalence(query: String, candidate: String) {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let prepared = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        let pathA = matcher.score(candidate, against: prepared, buffer: &buffer)
        let pathB = Self.scoreViaArraySpan(candidate, against: prepared, matcher: matcher)

        if let a = pathA, let b = pathB {
            #expect(
                abs(a.score - b.score) < 1e-10,
                "Score mismatch for '\(query)' vs '\(candidate)': \(a.score) != \(b.score)"
            )
            #expect(a.kind == b.kind, "Kind mismatch for '\(query)' vs '\(candidate)': \(a.kind) != \(b.kind)")
        } else {
            #expect(pathA == nil && pathB == nil, "Nil mismatch for '\(query)' vs '\(candidate)'")
        }
    }

    // MARK: - Acronym matches

    static let acronymPairs: [(query: String, candidate: String)] = [
        ("bms", "Bristol-Myers Squibb"),
        ("icag", "International Consolidated Airlines Group"),
        ("gubi", "get_user_by_id"),
    ]

    @Test("ED acronym: scores match between paths", arguments: acronymPairs)
    func acronymEquivalence(query: String, candidate: String) {
        let matcher = FuzzyMatcher()
        let prepared = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        let pathA = matcher.score(candidate, against: prepared, buffer: &buffer)
        let pathB = Self.scoreViaArraySpan(candidate, against: prepared, matcher: matcher)

        if let a = pathA, let b = pathB {
            #expect(
                abs(a.score - b.score) < 1e-10,
                "Score mismatch for '\(query)' vs '\(candidate)': \(a.score) != \(b.score)"
            )
            #expect(a.kind == b.kind, "Kind mismatch for '\(query)' vs '\(candidate)': \(a.kind) != \(b.kind)")
        } else {
            #expect(pathA == nil && pathB == nil, "Nil mismatch for '\(query)' vs '\(candidate)'")
        }
    }

    // MARK: - Non-matching candidates

    static let nonMatchPairs: [(query: String, candidate: String)] = [
        ("xyz", "hello"),
        ("zzz", "abc"),
        ("longquery", "hi"),
    ]

    @Test("Non-matching: both paths return nil", arguments: nonMatchPairs)
    func nonMatchEquivalence(query: String, candidate: String) {
        let matcher = FuzzyMatcher()
        let prepared = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        let pathA = matcher.score(candidate, against: prepared, buffer: &buffer)
        let pathB = Self.scoreViaArraySpan(candidate, against: prepared, matcher: matcher)

        #expect(pathA == nil, "Expected nil for '\(query)' vs '\(candidate)' (pathA)")
        #expect(pathB == nil, "Expected nil for '\(query)' vs '\(candidate)' (pathB)")
    }
}
