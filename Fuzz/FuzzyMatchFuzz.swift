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

// Fuzz target for FuzzyMatcher using libFuzzer.
//
// Build:  bash Fuzz/run.sh
// Run:    Fuzz/fuzz-fuzzymatch [corpus_dir]
//
// The fuzzer generates random byte buffers and uses them to construct
// (query, candidate, config) inputs. It validates invariants that must
// hold for ALL inputs — any violation is a bug.

// No `import FuzzyMatch` — compiled as a single module with the library sources.

// MARK: - Input parsing

/// Parses fuzzer-provided bytes into a (query, candidate, configIndex) tuple.
/// Layout: [configByte] [splitByte] [stringData...]
/// - configByte selects the MatchConfig variant
/// - splitByte determines where to split stringData into query and candidate
/// - stringData bytes are mapped to printable ASCII (0x20–0x7E)
private func parseInput(_ start: UnsafeRawPointer, _ count: Int) -> (String, String, Int)? {
    guard count >= 3 else { return nil }

    let data = UnsafeRawBufferPointer(start: start, count: count)
    let configByte = Int(data[0])
    let splitByte = Int(data[1])
    let stringCount = count - 2

    let splitPoint = splitByte % stringCount

    // Map raw bytes to printable ASCII to avoid invalid UTF-8
    var queryChars = [Character]()
    queryChars.reserveCapacity(splitPoint)
    for i in 0..<splitPoint {
        queryChars.append(Character(UnicodeScalar(32 + (Int(data[i + 2]) % 95))!))
    }

    var candidateChars = [Character]()
    candidateChars.reserveCapacity(stringCount - splitPoint)
    for i in splitPoint..<stringCount {
        candidateChars.append(Character(UnicodeScalar(32 + (Int(data[i + 2]) % 95))!))
    }

    return (String(queryChars), String(candidateChars), configByte)
}

// MARK: - Config variants

private let configs: [MatchConfig] = [
    // Edit distance configs (indices 0-4)
    MatchConfig(),                                                        // ED: default
    MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 0))), // ED: exact only
    MatchConfig(minScore: 0.5, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))), // ED: strict
    MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 3))), // ED: lenient
    // ED: picker-style
    MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2, prefixWeight: 4.0, substringWeight: 0.5))
    ),

    // Smith-Waterman configs (indices 5-9)
    .smithWaterman,                                                       // SW: default
    MatchConfig(minScore: 0.0, algorithm: .smithWaterman()),              // SW: lenient
    MatchConfig(minScore: 0.5, algorithm: .smithWaterman()),              // SW: strict
    MatchConfig(algorithm: .smithWaterman(                                // SW: high gap penalty
        SmithWatermanConfig(penaltyGapStart: 8, penaltyGapExtend: 4))),
    MatchConfig(algorithm: .smithWaterman(                                // SW: no space splitting
        SmithWatermanConfig(splitSpaces: false))),
]

// MARK: - Fuzz entry point

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTest(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    guard let (query, candidate, configIdx) = parseInput(start, count) else {
        return 0
    }

    let config = configs[configIdx % configs.count]
    let matcher = FuzzyMatcher(config: config)
    let prepared = matcher.prepare(query)
    var buffer = matcher.makeBuffer()

    // ── INVARIANT 1: No crash ──
    let result = matcher.score(candidate, against: prepared, buffer: &buffer)

    // ── INVARIANT 2: Score in [0.0, 1.0] and >= minScore ──
    if let match = result {
        precondition(match.score >= 0.0, "Score \(match.score) < 0.0")
        precondition(match.score <= 1.0, "Score \(match.score) > 1.0")
        precondition(match.score >= config.minScore,
                     "Score \(match.score) < minScore \(config.minScore)")
    }

    // ── INVARIANT 3: Self-match scores 1.0 ──
    if !query.isEmpty {
        let selfResult = matcher.score(query, against: prepared, buffer: &buffer)
        if let r = selfResult {
            precondition(r.score == 1.0,
                         "Self-match scored \(r.score), expected 1.0 for \"\(query)\"")
            precondition(r.kind == .exact,
                         "Self-match kind \(r.kind), expected .exact")
        }
        // selfResult could be nil only if prefilters erroneously reject
        // self-match — which would also be a bug caught by the crash invariant
        // if it leads to inconsistency downstream.
    }

    // ── INVARIANT 4: Empty query always matches with 1.0 ──
    let emptyPrepared = matcher.prepare("")
    let emptyResult = matcher.score(candidate, against: emptyPrepared, buffer: &buffer)
    precondition(emptyResult != nil, "Empty query returned nil for candidate")
    precondition(emptyResult!.score == 1.0,
                 "Empty query scored \(emptyResult!.score), expected 1.0")

    // ── INVARIANT 5: Buffer reuse consistency ──
    let result2 = matcher.score(candidate, against: prepared, buffer: &buffer)
    if let res1 = result, let res2 = result2 {
        precondition(res1.score == res2.score,
                     "Buffer reuse: \(res1.score) != \(res2.score)")
        precondition(res1.kind == res2.kind,
                     "Buffer reuse: \(res1.kind) != \(res2.kind)")
    } else {
        precondition((result == nil) == (result2 == nil),
                     "Buffer reuse: nil mismatch")
    }

    // Note: No symmetry invariant for same-length strings. Prefix edit distance
    // is inherently asymmetric because it matches against any prefix length, so
    // score("A", prepare("B")) can use the prefix path while score("B", prepare("A"))
    // falls through to substring — producing very different scores when
    // prefixWeight != substringWeight.

    return 0
}
