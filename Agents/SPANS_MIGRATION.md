# Migrate to Swift Span (Swift 6.2+)

This guide covers migrating FuzzyMatch from `UnsafeBufferPointer` back to Swift's `Span` type. Follow these steps when the project is ready to require Swift 6.2+.

## Overview

FuzzyMatch originally used `Span<UInt8>` and `Span<Int32>` for safe, non-escaping buffer access. These were replaced with `UnsafeBufferPointer` to support Swift 6.0 deployment. When Swift 6.2 becomes the minimum, restoring Span provides:

- **Memory safety**: `~Escapable` lifetime tracking prevents dangling pointer bugs
- **Cleaner API**: `.span` property replaces `withUnsafeBufferPointer` closures
- **Sub-range slicing**: `.extracting(range)` replaces `UnsafeBufferPointer(rebasing:)`

## Prerequisites

- Swift 6.2+ toolchain
- Xcode 26+ (for macOS development)

## Step-by-step Migration

### 1. Update Package.swift files and .swift-version

Update `swift-tools-version` to `6.2` and platform requirements in these files:

| File | platforms |
|------|-----------|
| `Package.swift` | `.macOS(.v26), .iOS(.v26), .visionOS(.v26), .watchOS(.v26)` |
| `Benchmarks/Package.swift` | `.macOS(.v26), .iOS(.v26), .visionOS(.v26)` |
| `Comparison/bench-fuzzymatch/Package.swift` | `.macOS(.v26)` |
| `Comparison/bench-contains/Package.swift` | `.macOS(.v26)` |
| `Comparison/quality-fuzzymatch/Package.swift` | `.macOS(.v26)` |

Update `.swift-version` to `6.2`.

Note: `Comparison/bench-ifrit/` and `Comparison/quality-ifrit/` stay at 5.9. `Examples/` is already at 6.2.

### 2. Replace UnsafeBufferPointer with Span in function signatures

In all source files under `Sources/FuzzyMatch/`:

```
UnsafeBufferPointer<UInt8>  →  Span<UInt8>
UnsafeBufferPointer<Int32>  →  Span<Int32>
```

**Files with parameter replacements:**

| File | Functions to update |
|------|-------------------|
| `EditDistance.swift` | `prefixEditDistance`, `substringEditDistance` |
| `SmithWaterman.swift` | `smithWatermanScore` |
| `Prefilters.swift` | `lowercaseUTF8`, `computeCharBitmask`, `computeCharBitmaskCaseInsensitive`, `computeCharBitmaskWithASCIICheck` |
| `WordBoundary.swift` | `isWordBoundary`, `isCamelCaseBoundary`, `computeBoundaryMask`, `computeBoundaryMaskCompressed` |
| `ScoringBonuses.swift` | `findMatchPositions`, `optimalAlignment`, `calculateBonuses`, `findContiguousSubstring` |
| `Trigrams.swift` | `countSharedTrigrams`, `passesTrigramFilter` |
| `FuzzyMatcher.swift` | `scoreImpl`, `scorePrefix`, `scoreSubstring`, `scoreSubsequence`, `scoreAcronym`, `computeAlignmentIfNeeded`, `scoreTinyQuery1` |
| `FuzzyMatcher+SmithWaterman.swift` | `scoreSmithWatermanImpl` |

### 3. Replace withUnsafeBufferPointer with .span property

In `FuzzyMatcher.swift` — `prepare` method:
```swift
// Before:
let lowercasedLength = utf8Bytes.withUnsafeBufferPointer { ptr in
    lowercaseUTF8(from: ptr, into: &lowercased, isASCII: isASCII)
}

// After:
let lowercasedLength = lowercaseUTF8(from: utf8Bytes.span, into: &lowercased, isASCII: isASCII)
```

In `FuzzyMatcher.swift` — `score` method entry point:
```swift
// Before: withContiguousStorageIfAvailable + fallback
// After: candidate.utf8.span directly
```

Replace the entire `withContiguousStorageIfAvailable` block and fallback with direct `.span` access:
```swift
switch query.config.algorithm {
case .smithWaterman(let swConfig):
    return scoreSmithWatermanImpl(candidate.utf8.span, ...)
case .editDistance(let edConfig):
    ...
    return scoreImpl(candidate.utf8.span, ...)
}
```

### 4. Replace withUnsafeBufferPointer / withReadBuffers with .span.extracting()

In `FuzzyMatcher.swift` — `scoreImpl`:
```swift
// Before:
return candidateStorage.bytes.withUnsafeBufferPointer { bytesPtr in
    let candidateSpan = UnsafeBufferPointer(rebasing: bytesPtr[0..<actualCandidateLength])
    return query.lowercased.withUnsafeBufferPointer { querySpan -> ScoredMatch? in
        ...
    }
}

// After:
let candidateSpan = candidateStorage.bytes.span.extracting(0..<actualCandidateLength)
let querySpan = query.lowercased.span
```

In `FuzzyMatcher+SmithWaterman.swift` — `scoreSmithWatermanImpl`:
```swift
// Before:
return candidateStorage.withReadBuffers(length: actualCandidateLength) { candidateSpan, bonusSpan in
    return query.lowercased.withUnsafeBufferPointer { querySpan -> ScoredMatch? in
        ...
    }
}

// After:
let candidateSpan = candidateStorage.bytes.span.extracting(0..<actualCandidateLength)
let bonusSpan = candidateStorage.bonus.span.extracting(0..<actualCandidateLength)
let querySpan = query.lowercased.span
```

For multi-atom paths:
```swift
// Before: UnsafeBufferPointer(rebasing: querySpan[atom.start..<(atom.start + atom.length)])
// After:  query.lowercased.span.extracting(atom.start..<(atom.start + atom.length))
```

### 5. Remove withReadBuffers helper

Delete the `withReadBuffers` method from `CandidateStorage` in `ScoringBuffer.swift`. It was added specifically for the UnsafeBufferPointer migration.

### 6. Update test files

**Delete `Tests/FuzzyMatchTests/TestHelpers.swift`** — the array-accepting wrappers are no longer needed since `.span` provides direct access.

**Update test call sites** — add `.span` to array arguments:

```swift
// Before (array-accepting wrapper):
let d = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 3)

// After (Span):
let d = prefixEditDistance(query: query.span, candidate: candidate.span, state: &state, maxEditDistance: 3)
```

For `TinyQueryFastPathTests.swift`, replace the `withUnsafeBufferPointer` closure with `.span`:

```swift
// Before:
return candidateUTF8.withUnsafeBufferPointer { ptr in
    matcher.scoreImpl(ptr, ...)
}

// After:
return matcher.scoreImpl(candidateUTF8.span, ...)
```

Test files to update:
- `EditDistanceTests.swift`
- `SmithWatermanTests.swift`
- `PrefilterTests.swift`
- `WordBoundaryTests.swift`
- `ScoringBonusTests.swift`
- `OptimalAlignmentTests.swift`
- `TrigramTests.swift`
- `DiacriticNormalizationTests.swift`
- `CombiningMarkTests.swift`
- `ConfusableNormalizationTests.swift`
- `TinyQueryFastPathTests.swift`
- `ExactScoreVerificationTests.swift`
- `GreekCyrillicTests.swift`
- `AlgorithmBoundaryTests.swift`

### 7. Deprecate or remove score(utf8:against:buffer:)

The `score(utf8:against:buffer:)` method was added as a workaround for Swift 6.0's non-inlinable `String.withUTF8`. With Span, the String API recovers full throughput — the UTF-8 overload is no longer needed.

**Source changes:**
- `FuzzyMatcher.swift`: Mark `score(utf8:against:buffer:)` as `@available(*, deprecated, message: "Use score(_:against:buffer:) instead — Span provides equivalent throughput")`, or remove it entirely
- Remove the `@inlinable` / `@inline(__always)` annotations that were added for the UTF-8 bypass path if they are no longer needed

**Documentation — remove three-tier API references:**
- `CLAUDE.md`: Remove the "UTF-8 API" section and the Swift 6.0 limitation note; collapse back to two tiers (High-Performance + Convenience)
- `README.md`: Remove the "UTF-8 API (Maximum Throughput)" section and the `score(utf8:...)` row from the API reference table
- `FuzzyMatch.docc/FuzzyMatch.md`: Remove the UTF-8 API paragraph and code example
- `FuzzyMatch.docc/GettingStarted.md`: Remove the UTF-8 API paragraph and code example
- `FuzzyMatch.docc/QualityAndPerformance.md`: Remove the `score(utf8:...)` row from the API table and the inlining explanation paragraph; restore the original two-column table format

**Benchmarks — remove UTF-8 variants:**
- `Benchmarks/Benchmarks/FuzzyMatchBenchmark/FuzzyMatchBenchmark.swift`: Remove the "(UTF-8)" benchmark variants (ED 5-char, ED 10-char, SW 5-char, SW 10-char)
- `Benchmarks/Benchmarks/CorpusBenchmark/CorpusBenchmark.swift`: Remove "ED - all queries (UTF-8)" and "SW - all queries (UTF-8)" benchmarks
- `Comparison/bench-fuzzymatch/Sources/main.swift`: Remove the `--utf8` flag, `useUTF8` config field, and the UTF-8 scoring path in `scoreQuery`
- `Comparison/run-benchmarks.sh`: Remove `--fm-ed-utf8` and `--fm-sw-utf8` flags and their run/save sections

**Tests:**
- `Tests/FuzzyMatchTests/ConvenienceAPITests.swift`: Remove or update the `utf8API*` tests (they can be removed if the method is removed, or updated to test the deprecated path if kept)

### 8. Update documentation

- `CLAUDE.md`: Change `Swift 6.0+, macOS 14+` → `Swift 6.2+, macOS 26+`; remove the Spans migration note
- `README.md`: Change `Swift 6.0+` → `Swift 6.2+`; update platform versions; add back "(requires span support)" note
- `CONTRIBUTING.md`: Change `Swift 6.0+` → `Swift 6.2+`; update platform versions
- `ScoringBuffer.swift`: Update doc comment on CandidateStorage from "buffer borrowing" back to "Span borrowing"

### 9. Update doc comments in source files

- `Prefilters.swift`: Update `computeCharBitmask` doc comment to reference "Span" instead of "UnsafeBufferPointer"
- `WordBoundary.swift`: Update example code in doc comments to use `.span` syntax
- `FuzzyMatcher.swift`: Update `scoreImpl` doc comment to reference "Span"

## Verification

```bash
swift test && swiftlint lint
swift build -c release
swift build --package-path Benchmarks
swift build --package-path Comparison/bench-fuzzymatch
```

## Benefits of Span

- **`~Escapable`**: Span cannot outlive the storage it borrows from — the compiler enforces this at compile time, preventing entire classes of use-after-free and dangling pointer bugs
- **No closure nesting**: `.span` is a property, not a closure-based API, so code reads linearly instead of nesting deeper with each buffer access
- **`.extracting(range)`**: Built-in sub-range slicing that returns another Span, vs the verbose `UnsafeBufferPointer(rebasing: ptr[range])` pattern
- **Zero cost**: Span has the same runtime performance as UnsafeBufferPointer — the safety checks are all at compile time
