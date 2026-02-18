# ``FuzzyMatch``

High-performance fuzzy string matching for Swift.

## Overview

FuzzyMatch provides configurable fuzzy string matching with two matching modes — **Damerau-Levenshtein edit distance** (default, penalty-driven) and **Smith-Waterman local alignment** (bonus-driven) — both with multi-stage prefiltering and zero-allocation hot paths. It handles typos (insertions, deletions, substitutions, and transpositions), supports prefix, substring, acronym, and alignment matching, and uses intelligent scoring bonuses for intuitive ranking.

Originally developed for searching financial instrument databases (stock tickers, fund names, ISINs), the library is equally well suited to code identifiers, file names, product catalogs, contact lists, and any other domain where typo tolerance, fast performance, and sensible ranking are important.

### Convenience API

The simplest way to get started — ideal for prototyping or small candidate sets:

```swift
import FuzzyMatch

let matcher = FuzzyMatcher()

// One-shot scoring
if let match = matcher.score("getUserById", against: "getUser") {
    print("score=\(match.score), kind=\(match.kind)")
}

// Top-N matching
let query = matcher.prepare("config")
let top3 = matcher.topMatches(
    ["appConfig", "configManager", "database", "userConfig"],
    against: query,
    limit: 3
)
```

### High-Performance API

For production use, interactive search, and batch processing — zero heap allocations per `score` call:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("getUser")
var buffer = matcher.makeBuffer()

let candidates = ["getUserById", "getUsername", "setUser", "fetchData"]
for candidate in candidates {
    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
        print("\(candidate): score=\(match.score), kind=\(match.kind)")
    }
}
// getUserById: score=0.9988, kind=prefix
// getUsername: score=0.9988, kind=prefix
// setUser: score=0.9047619047619048, kind=prefix
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AlgorithmOverview>
- <doc:QualityAndPerformance>

### Core Types

- ``FuzzyMatcher``
- ``FuzzyQuery``
- ``ScoringBuffer``

### Configuration

- ``MatchConfig``
- ``MatchingAlgorithm``
- ``EditDistanceConfig``
- ``SmithWatermanConfig``
- ``GapPenalty``

### Results

- ``ScoredMatch``
- ``MatchResult``
- ``ItemMatchResult``
- ``MatchKind``
