# Damerau-Levenshtein Mode — Algorithm Documentation

This document provides a detailed explanation of the algorithms and techniques used in the default edit distance mode. For a high-level comparison of both matching modes, see [MATCHING_MODES.md](MATCHING_MODES.md). For the Smith-Waterman mode, see [SMITH_WATERMAN.md](SMITH_WATERMAN.md).

## Table of Contents

1. [Overview](#overview)
2. [Edit Distance Algorithm](#edit-distance-algorithm)
3. [Prefiltering Pipeline](#prefiltering-pipeline)
4. [Scoring Model](#scoring-model)
5. [Word Boundary Detection](#word-boundary-detection)
6. [Scoring Bonuses](#scoring-bonuses)
7. [Subsequence Matching](#subsequence-matching)
8. [Acronym Matching](#acronym-matching)
9. [Implementation Details](#implementation-details) — Query Preparation, Fast Paths, Zero-Allocation Design, UTF-8 Processing, Unicode Support, Match Strategy
10. [Complexity Analysis](#complexity-analysis)
11. [Fuzz Testing](#fuzz-testing)
12. [References](#references)

---

## Overview

FuzzyMatcher implements a hybrid fuzzy string matching system. The system combines:

1. **Damerau-Levenshtein edit distance** for accurate similarity measurement
2. **Multi-stage prefiltering** for fast candidate rejection
3. **Intelligent scoring bonuses** for intuitive ranking
4. **Subsequence matching fallback** for abbreviation-style queries
5. **Acronym matching** for word-initial abbreviations (e.g., "bms" → "Bristol-Myers Squibb")
6. **Zero-allocation design** for high-throughput scenarios

The matching pipeline:

```
Candidate → Length Filter → Bitmask Filter → Trigram Filter → Edit Distance
                                                                    ↓
                                                            Position Finding
                                                                    ↓
                                              Bonus Calculation (boundaries, consecutive, gaps)
                                                                    ↓
                                                         Subsequence Fallback
                                                                    ↓
                                                          Acronym Matching
                                                                    ↓
                                                              Final Score
```

If edit distance matching fails, subsequence matching provides a fallback for queries like "gubi" → "getUserById". Acronym matching then checks if the query matches word-initial characters (e.g., "bms" → "Bristol-Myers Squibb").

---

## Edit Distance Algorithm

### Damerau-Levenshtein Distance

FuzzyMatcher uses the **Restricted Damerau-Levenshtein distance** (also known as Optimal String Alignment distance), which measures the minimum number of edit operations to transform one string into another.

#### Supported Operations

| Operation | Example | Cost |
|-----------|---------|------|
| Insertion | "cat" → "cart" | 1 |
| Deletion | "cart" → "cat" | 1 |
| Substitution | "cat" → "bat" | 1 |
| Transposition | "teh" → "the" | 1 |

#### Why Damerau-Levenshtein?

Standard Levenshtein distance treats transpositions as two operations (delete + insert). Damerau-Levenshtein recognizes that swapping adjacent characters is a common typing error and counts it as a single operation.

```
Levenshtein("teh", "the") = 2  (delete 'h', insert 'h')
Damerau-Levenshtein("teh", "the") = 1  (transpose 'eh' → 'he')
```

Studies show that ~80% of human spelling errors are single-character edits, with transpositions being particularly common.

### Dynamic Programming Implementation

The algorithm uses a dynamic programming approach with a 2D matrix where `dp[i][j]` represents the minimum edits to transform the first `i` characters of the candidate to match the first `j` characters of the query.

#### Recurrence Relation

```
dp[i][j] = min(
    dp[i-1][j] + 1,                    // Deletion
    dp[i][j-1] + 1,                    // Insertion
    dp[i-1][j-1] + cost(i,j),          // Substitution (cost=0 if match, 1 otherwise)
    dp[i-2][j-2] + 1                   // Transposition (if applicable)
)
```

The transposition case applies when:
- `i > 1` and `j > 1`
- `candidate[i] == query[j-1]` and `candidate[i-1] == query[j]`

#### Space Optimization

Instead of maintaining the full O(nm) matrix, we use a rolling array technique with three rows:

- `row` - Current row being computed
- `prevRow` - Previous row (i-1)
- `prevPrevRow` - Row from two iterations ago (i-2), needed for transposition

This reduces space complexity from O(nm) to O(m).

### Prefix vs. Substring Matching

FuzzyMatcher supports two matching modes:

#### Prefix Matching

Finds the minimum edits to match the query against the **beginning** of the candidate. The candidate may have trailing characters that are ignored.

```
Query: "get"
Candidate: "getUserById"

Prefix distance = 0 (exact prefix match)
```

#### Substring Matching

Finds the minimum edits to match the query **anywhere** within the candidate. This is achieved by setting `row[0] = 0` at each position, allowing the match to "start fresh" at any point.

```
Query: "user"
Candidate: "getCurrentUser"

Substring distance = 0 (exact substring match at position 10)
```

---

## Prefiltering Pipeline

Computing edit distance is O(nm), which is expensive for large candidate sets. FuzzyMatcher uses a three-stage prefiltering pipeline to quickly reject non-matching candidates.

### Stage 1: Length Bounds

**Complexity:** O(1)

If the edit distance between two strings exceeds the effective edit distance budget, their lengths must satisfy certain bounds.

```
minLength = queryLength - effectiveMaxEditDistance
```

Note: `effectiveMaxEditDistance` is tightened for short queries — see [Query Preparation](#query-preparation) for the formula. For a 4-character query with `maxEditDistance=2`, the effective value is `min(2, max(1, 3/2)) = 1`, so `minLength = 4 - 1 = 3`, not `4 - 2 = 2`.

**Rationale:**
- Minimum: If candidate is shorter than `query - effectiveMaxEditDistance`, we'd need more deletions than allowed
- No upper limit: Subsequence matching can match short queries against long candidates (e.g., "fb" → "file_browser")

### Stage 2: Character Bitmask

**Complexity:** O(1) after precomputation

A 64-bit bitmask tracks character presence:
- Bits 0-25: Letters a-z
- Bits 26-35: Digits 0-9
- Bit 36: Underscore
- Bits 37-63: 2-byte UTF-8 characters (Latin-1 Supplement, Greek, Cyrillic) via hash of lowercased (lead, second) byte pair into 27 available slots

**Lookup table optimization:** Bitmask computation uses a 256-entry lookup table (`charBitmaskLookup`) that maps each byte directly to its bitmask contribution. This replaces 5 conditional branches per byte with a single table load and bitwise OR. The `computeCharBitmaskWithASCIICheck()` function also folds ASCII detection into the same single O(n) scan — it checks for `byte >= 0x80` while computing the bitmask, avoiding a separate pass over the candidate bytes.

**Algorithm:**
```
missingChars = queryMask & ~candidateMask
bitmaskTolerance = queryLength <= 3 ? 0 : effectiveMaxEditDistance
pass = popcount(missingChars) <= bitmaskTolerance
```

**Adaptive tolerance:** For queries of 4+ characters, the tolerance equals `effectiveMaxEditDistance`, allowing substitution typos (each edit can account for one missing character type). For very short queries (≤3 characters), tolerance is 0 (strict) — with only 1-3 distinct character types, allowing even one missing type lets nearly everything through, defeating the purpose of the prefilter. This means substitution typos (e.g., "UES" for "USD") are not detected for short queries, but transposition typos (e.g., "UDS" for "USD") still work because they involve the same character set.

**Example:**
- Query "gubi" matching "getUserById": g, u, b, i all exist → 0 missing, passes
- Query "hein" matching "heia": 'n' missing → 1 missing ≤ bitmaskTolerance(1), passes (substitution). Note: for "hein" (4 chars), `effectiveMaxEditDistance = min(2, max(1, 3/2)) = 1`, and `bitmaskTolerance = 1` (since queryLength > 3).
- Query "teh" matching "the": t, e, h all exist → 0 missing, passes (transposition handled by edit distance)
- Query "xyz" matching "abc": x, y, z all missing → 3 missing > bitmaskTolerance, fails

### Stage 3: Trigram Filtering

**Complexity:** O(n) where n = candidate length

Trigrams are consecutive 3-character sequences. If two strings are similar, they should share many trigrams.

**Algorithm:**
```
queryTrigrams = {"get", "etU", "tUs", "Use", "ser"}  // for "getUser"
sharedCount = count trigrams in candidate that appear in queryTrigrams
pass = sharedCount >= queryTrigrams.count - 3 * effectiveMaxEditDistance
```

Each edit operation can destroy up to 3 trigrams (a transposition at position i affects trigrams at i-2..i, i-1..i+1, and i..i+2), hence the factor of 3. This avoids false rejections on Damerau-Levenshtein transposition typos.

**Note:** Trigram filtering is only applied for queries of 4+ characters whose trigram count exceeds `3 * effectiveMaxEditDistance` (ensuring the threshold is positive). Shorter queries produce too few trigrams for effective filtering. Space-containing trigrams (e.g., `"n s"`, `" sa"`) are excluded at computation time, so multi-word queries still pass through the trigram filter but only their non-space trigrams are compared.

---

## Scoring Model

### Base Score Calculation

Edit distance is converted to a score between 0.0 and 1.0:

```
baseScore = max(0, 1.0 - (editDistance / queryLength))
```

**Examples:**
- Distance 0, length 5: score = 1.0 (perfect match)
- Distance 1, length 5: score = 0.8
- Distance 2, length 5: score = 0.6

### Match Type Weighting

Different match types receive configurable weights using an asymptotic formula:

```
weightedScore = max(0, 1.0 - (1.0 - baseScore) / weight)
```

This formula ensures that:
- **Perfect matches always score 1.0** regardless of weight (distance=0 → baseScore=1.0 → score=1.0)
- **Imperfect matches always score below 1.0**, so a perfect prefix is always ranked above a transposed prefix
- **Higher weights compress the penalty** but never eliminate it (e.g., prefixWeight=1.5 reduces a 0.2 penalty to 0.133)
- **Weight=1.0 is identity**: the formula produces the same result as the unweighted base score

| Match Type | Default Weight | Rationale |
|------------|---------------|-----------|
| Prefix | 1.5 | Users often type the beginning of identifiers |
| Substring | 1.0 | Baseline for matches anywhere in the string |
| Acronym | 1.0 | Word-initial abbreviations (e.g., "bms" → "Bristol-Myers Squibb") |

### Length Penalty

Candidates longer than the query receive a penalty proportional to the excess length:

```
lengthPenalty = (candidateLength - queryLength) × config.lengthPenalty
```

**Default:** `config.lengthPenalty = 0.003` per excess character

This prevents long candidates from outscoring shorter, more relevant ones. For whole-word substring matches, 80% of the length penalty is recovered (see [Whole-Word Substring Recovery](#whole-word-substring-recovery)). For exact prefix matches (distance == 0 only), 90% is recovered; non-exact prefix matches receive no length penalty recovery.

### Final Score with Bonuses

After weighting, scoring bonuses are applied:

```
if distance > 0:
    maxBonus = (1.0 - weightedScore) * 0.8
    finalScore = weightedScore + min(bonuses, maxBonus)
else:
    finalScore = min(weightedScore + bonuses, 1.0)
```

For non-exact matches (distance > 0), bonuses are capped at 80% of the gap between the weighted score and 1.0. This prevents imperfect matches from reaching a perfect score through bonuses alone — only exact matches (distance == 0) can score 1.0 after bonuses.

#### Same-Length Near-Exact Boost

When the candidate has the same length as the query but `distance > 0` (e.g., a single transposition like "UDS" → "USD" or "MFST" → "MSFT"), the prefix path applies an additional recovery: 70% of the gap to 1.0 is recovered before bonuses are applied. This applies to queries of any length — including 2-3 character queries — and gives near-exact same-length matches a significant score advantage over longer candidates that happen to contain the query as a prefix.

#### Short Query Same-Length Restriction

For very short queries (≤3 characters) with `distance > 0`, both the prefix and substring paths restrict edit distance matches to same-length candidates only. This prevents a short typo query like "UDS" from matching a longer candidate like "USD Bond Fund" — the match is only allowed if the candidate is the same length as the query (e.g., "USD"). This restriction is critical for precision on 2-3 character typo queries in large corpora.

See [Scoring Bonuses](#scoring-bonuses) for details.

---

## Word Boundary Detection

Word boundaries are positions in code identifiers where new "words" begin. FuzzyMatcher detects boundaries for applying scoring bonuses.

### Boundary Types

| Boundary Type | Example | Positions |
|---------------|---------|-----------|
| Start of string | `getUserById` | 0 |
| camelCase transition | `getUserById` | 0, 3, 7, 9 |
| After underscore | `get_user_by_id` | 0, 4, 9, 12 |
| After digit | `user2name` | 0, 5 |
| After non-alphanumeric | `foo.bar` | 0, 4 |

### Boundary Detection Algorithm

```
function isWordBoundary(index, bytes, length):
    if index == 0: return true
    if index >= length: return false

    current = bytes[index]
    previous = bytes[index - 1]

    // After underscore
    if previous == '_': return true

    // After digit
    if previous is digit: return true

    // camelCase: lowercase → uppercase
    if previous is lowercase and current is uppercase: return true

    // After non-alphanumeric
    if previous is not alphanumeric: return true

    return false
```

### Boundary Mask Optimization

For identifiers up to 64 characters, boundaries are precomputed as a `UInt64` bitmask:

```swift
let mask = computeBoundaryMask(bytes: candidateBytes, length: length)
// Check if position 3 is a boundary:
let isBoundary = (mask & (1 << 3)) != 0
```

This enables O(1) boundary lookups during scoring.

---

## Scoring Bonuses

FuzzyMatcher applies intelligent scoring bonuses to improve ranking quality. These bonuses reward patterns that match user expectations.

### Word Boundary Bonus

**Purpose:** Reward matches at word boundaries, indicating the user is typing abbreviations.

**Default:** 0.1 (10% bonus per boundary match)

**Example:**
```
Query: "gubi"
Candidate: "getUserById"
Positions: [0, 3, 7, 9]  (g, U, B, I)

All 4 characters match at word boundaries.
Bonus: 4 × 0.1 = 0.4
```

### Consecutive Match Bonus

**Purpose:** Reward sequential character matches, indicating a contiguous substring.

**Default:** 0.05 (5% bonus per consecutive pair)

**Example:**
```
Query: "get"
Candidate: "getUserById"
Positions: [0, 1, 2]

Two consecutive pairs: (0→1) and (1→2)
Bonus: 2 × 0.05 = 0.1
```

### Gap Penalty

**Purpose:** Penalize scattered matches where query characters are spread far apart.

FuzzyMatcher supports two gap penalty models via the `GapPenalty` enum:

#### Linear Gap Penalty

Each gap character costs the same amount.

**Usage:** `.linear(perCharacter: 0.01)`

**Example:**
```
Query: "ab"
Candidate: "aXXXb"
Gap of 3 characters.
Penalty: 3 × 0.01 = 0.03
```

#### Affine Gap Penalty (Default)

Starting a gap is more expensive than continuing one. This encourages tighter matches.

**Usage:** `.affine(open: 0.03, extend: 0.005)` (default)

**Formula:** `penalty = open + (gapSize - 1) × extend`

**Example:**
```
Query: "ab"
Candidate: "aXXXb"
Gap of 3 characters.
Penalty: 0.03 + (3-1) × 0.005 = 0.04
```

**Comparison:**
| Gap Size | Linear (0.01/char) | Affine (0.03 + 0.005) |
|----------|-------------------|----------------------|
| 1 | 0.01 | 0.03 |
| 2 | 0.02 | 0.035 |
| 3 | 0.03 | 0.04 |
| 5 | 0.05 | 0.05 |
| 10 | 0.10 | 0.075 |

Affine penalizes small gaps more but is gentler on large gaps, encouraging either tight matches or accepting larger structural gaps.

### First Match Position Bonus

**Purpose:** Reward matches that start early in the candidate string.

**Default:** `firstMatchBonus: 0.15`, `firstMatchBonusRange: 10`

The bonus decays linearly from full value at position 0 to zero at `firstMatchBonusRange`.

**Formula:** `bonus = firstMatchBonus × (1 - firstPosition / firstMatchBonusRange)`

**Example:**
```
Query: "gui"
Candidate: "getUserInfo" (match at position 0)
Position bonus: 0.15 × (1 - 0/10) = 0.15

Candidate: "debugUserInfo" (match at position 5)
Position bonus: 0.15 × (1 - 5/10) = 0.075

Candidate: "someLongPrefixUserInfo" (match at position 14)
Position bonus: 0 (beyond range)
```

### Contiguous Substring Recovery

**Purpose:** For short queries (2–4 characters), the greedy `findMatchPositions` algorithm may find scattered positions that miss a contiguous occurrence of the query elsewhere in the candidate. When the edit distance confirms an exact substring match exists (`distance == 0`) but the greedy positions are non-contiguous, a full scan finds the actual contiguous match — preferring a whole-word-bounded position.

**When it runs:**
1. Query length is 2–4 characters (uses greedy `findMatchPositions`, not DP)
2. Substring edit distance is 0 (an exact contiguous match exists somewhere)
3. Greedy positions are non-contiguous (`lastPos - firstPos + 1 != queryLength`)

**Algorithm:**
```
function findContiguousSubstring(query, candidate, boundaryMask):
    firstMatch = -1
    for startPos in 0..(candidateLength - queryLength):
        if candidate[startPos..startPos+queryLength] == query:
            if firstMatch == -1: firstMatch = startPos
            if isWordBounded(startPos, startPos + queryLength):
                return startPos  // prefer whole-word match
    return firstMatch  // fallback to first contiguous match
```

**Example:**
```
Query: "SRI", Candidate: "iShares MSCI EM SRI UCITS ETF"

Greedy findMatchPositions finds: s(1), r(4), i(11) — scattered across "isharesmscI"
  (search window candidateIndex + queryLength + 5 = 8 chars too narrow to see "sri" at position 16)

findContiguousSubstring scans full candidate:
  - Finds "sri" at position 16, word-bounded (space before, space after)
  - Replaces scattered [1,4,11] with contiguous [16,17,18]

Contiguous positions enable: consecutive bonuses + whole-word recovery
```

### Whole-Word Substring Recovery

**Purpose:** Partially offset the length penalty when a substring match is a complete, delimited word — bounded by word boundaries or string edges on both sides. Uses a lower recovery factor (0.8) than exact prefix recovery (0.9) so that prefix matches always rank above equivalent substring matches.

**Formula:** `recovery = min(lengthPenalty × 0.8, 0.15)` (vs `min(lengthPenalty × 0.9, 0.15)` for prefix)

**Conditions:** The recovery applies only when all of these hold:
1. `distance == 0` — exact substring match (no edits)
2. All query characters found in order (position count equals query length)
3. Matched positions are consecutive (contiguous, not scattered)
4. Start boundary: position 0 or preceded by a non-alphanumeric character
5. End boundary: end of string or followed by a non-alphanumeric character

**Example:**
```
Query: "SRI"
Candidate: "iShares MSCI EM SRI UCITS ETF" (lowercased)

After contiguous substring recovery: positions [16,17,18]
Whole-word check: position 16 is a word boundary (space before), position 19 is a space → bounded
Length penalty: (29 - 3) × 0.003 = 0.078
Recovery: min(0.078 × 0.8, 0.15) = 0.062
Net penalty: 0.078 - 0.062 = 0.016

Without contiguous recovery, scattered positions would fail the consecutive check,
and the length penalty would push this below "SERVICENOW" (shorter, lower penalty).
```

### Bonus Calculation Algorithm

```
function calculateBonuses(positions, boundaryMask, config):
    bonus = 0
    previousPosition = -2

    for each position in positions:
        // Word boundary bonus
        if isBoundary(position, boundaryMask):
            bonus += config.wordBoundaryBonus

        // Consecutive bonus
        if position == previousPosition + 1:
            bonus += config.consecutiveBonus
        else if previousPosition >= 0:
            // Gap penalty (affine or linear)
            gap = position - previousPosition - 1
            switch config.gapPenalty:
                case .none:
                    break
                case .linear(perCharacter):
                    bonus -= gap × perCharacter
                case .affine(open, extend):
                    bonus -= open + (gap - 1) × extend

        previousPosition = position

    // First match position bonus
    if config.firstMatchBonus > 0:
        firstPos = positions[0]
        if firstPos < config.firstMatchBonusRange:
            decay = 1.0 - (firstPos / firstMatchBonusRange)
            bonus += config.firstMatchBonus × decay

    return bonus
```

---

## Subsequence Matching

When edit distance matching fails (e.g., query "gubi" exceeds the effectiveMaxEditDistance threshold against "getUserById"), FuzzyMatcher falls back to subsequence matching.

### Algorithm

Subsequence matching finds positions where all query characters appear in order:

```
function findMatchPositions(query, candidate, boundaryMask):
    positions = []
    candidateIndex = 0

    for each queryChar in query:
        // Look for boundary match first
        bestPosition = -1
        for searchPos in candidateIndex..<searchLimit:
            if candidate[searchPos] == queryChar:
                if isBoundary(searchPos, boundaryMask):
                    bestPosition = searchPos
                    break
                else if bestPosition == -1:
                    bestPosition = searchPos

        if bestPosition == -1:
            return nil  // No match

        positions.append(bestPosition)
        candidateIndex = bestPosition + 1

    return positions
```

### Subsequence Scoring

For subsequence matches, the base score is computed from the gap ratio:

```
totalGaps = matchPositions[0]                          // gap before first match
for i in 1..<positionCount:
    totalGaps += matchPositions[i] - matchPositions[i-1] - 1  // gaps between matches
gapRatio = totalGaps / candidateLength
baseScore = max(0.3, 1.0 - gapRatio)
score = baseScore * config.substringWeight
```

The gap before the first match is included so that matches starting later in the candidate are penalized. After computing the base score, it is multiplied by `substringWeight` (default 1.0). Bonuses are then applied (capped at 80% recovery, consistent with the prefix and substring paths), which typically boosts subsequence matches at word boundaries significantly.

### Example

```
Query: "gubi"
Candidate: "getUserById"

Prefix/substring edit distance exceeds effectiveMaxEditDistance threshold
Subsequence match finds: g(0), U(3), B(7), I(9)
All at word boundaries → high bonus
Final score ≈ 0.64 (matches well)
```

---

## Acronym Matching

When both edit distance and subsequence matching fail to produce strong results, FuzzyMatcher tries acronym matching as a final pass. This handles abbreviation-style queries where users type the first letter of each word in a multi-word name.

### When It Runs

The acronym pass runs when all of these conditions are met:
- Query length is 2-8 characters
- Candidate has at least 3 words (detected via `popcount(boundaryMask)`)
- Candidate has at least as many words as query characters

### Algorithm

1. **Extract word initials**: Collect the first character of each word using the precomputed boundary mask
2. **Subsequence check**: Verify the query is a subsequence of the initials array
3. **Score by coverage**: `score = (0.55 + 0.4 × coverage) × acronymWeight`

Where `coverage = queryLength / initialCount` (ratio of query chars to total words).

```
function acronymMatch(query, candidate, boundaryMask, config):
    // Quick check: enough words?
    wordCount = popcount(boundaryMask)
    if wordCount < 3 or wordCount < query.length:
        return nil

    // Extract word-initial characters
    initials = []
    for each position i where boundary bit is set:
        initials.append(lowercasedCandidate[i])

    // Subsequence match
    qi = 0
    for each initial in initials:
        if qi < query.length and query[qi] == initial:
            qi += 1
    if qi != query.length:
        return nil

    // Score by coverage
    coverage = query.length / initials.count
    score = (0.55 + 0.4 × coverage) × config.acronymWeight
    return score
```

### Scoring

| Coverage | Score | Example |
|----------|-------|---------|
| 1.0 (all words) | 0.95 | "bms" → "Bristol-Myers Squibb" (3/3) |
| 0.8 (most words) | 0.87 | "icag" → "International Consolidated Airlines Group SA" (4/5) |
| 0.67 (partial) | 0.82 | "bms" → "Bristol-Myers Squibb Company" (3/4, if subsequence doesn't win) |

No length penalty is applied to acronym matches — long candidates are inherent to the abbreviation use case. The coverage ratio already penalizes partial matches.

### Performance

The acronym pass uses `popcount(boundaryMask)` as an O(1) early exit to skip candidates with fewer than 3 words. For the ~272K instrument corpus, most candidates are single-word symbols or short derivative names that fail this check immediately. The word-initial extraction loop only runs for multi-word candidates that pass the word-count threshold.

### Example

```
Query: "bms"
Candidate: "Bristol-Myers Squibb"

Word boundaries: B(0), M(8), S(14)
Initials: [b, m, s]
Query subsequence: b→b ✓, m→m ✓, s→s ✓

Coverage: 3/3 = 1.0
Score: 0.55 + 0.4 × 1.0 = 0.95
```

---

## Implementation Details

### Query Preparation

`FuzzyQuery.prepare()` precomputes several derived constants that avoid per-candidate recomputation in the scoring loop:

| Field | Formula | Purpose |
|-------|---------|---------|
| `effectiveMaxEditDistance` | `min(maxED, max(1, (queryLength - 1) / 2))` where `maxED = queryLength >= longQueryThreshold ? longQueryMaxEditDistance : maxEditDistance` | Tighten edit budget for short queries (e.g., 3-char → maxED=1). For long queries (>= 13 chars by default), `maxED` increases from 2 to 3 to allow more typos. |
| `bitmaskTolerance` | `queryLength <= 3 ? 0 : effectiveMaxEditDistance` | Strict bitmask for very short queries, relaxed for longer ones |
| `minCandidateLength` | `queryLength - effectiveMaxEditDistance` | Minimum candidate length that can pass the length bounds prefilter |

These constants are stored in the `FuzzyQuery` struct and used directly by the prefilter checks and edit distance bounds, eliminating repeated `min`/`max` calls in the hot path.

### Fast Paths

#### Tiny Query (queryLength == 1)

Single-character queries bypass the entire `scoreImpl` pipeline. Instead, a dedicated `scoreTinyQuery1()` method performs a single linear scan of the candidate bytes with inline lowercasing, boundary detection, and scoring. This fast path:

- Uses zero buffer capacity (no DP arrays, no positions)
- Performs case-insensitive matching for single ASCII bytes only (Latin Extended and other 2-byte characters fall through to the full pipeline)
- Detects word boundaries inline during the scan
- Returns exact, prefix, or substring match kind based on position
- For exact matches (single-char candidate), returns score 1.0
- For prefix matches (query matches first character), recovers 90% of the gap between the base score and 1.0
- For substring matches (query appears later in the candidate), recovers 80% of the gap
- Applies a word boundary boost when the match occurs at a camelCase transition, underscore boundary, or other word start
- Applies a length penalty that decreases the score for longer candidates, keeping short exact matches above long partial ones

#### Short Query (queryLength <= 4)

For queries of 2–4 characters, the scoring pipeline replaces the DP-optimal `optimalAlignment()` with a greedy `findMatchPositions()` + `calculateBonuses()` approach. This avoids allocating and filling the full DP match/gap matrices, since short queries have too few characters for the DP alignment to provide meaningful improvement over the greedy heuristic. The contiguous substring recovery (see [Contiguous Substring Recovery](#contiguous-substring-recovery)) compensates for cases where the greedy approach misses the best contiguous match.

#### DP-Optimal Alignment (queryLength > 4)

For queries longer than 4 characters, `optimalAlignment()` replaces the greedy `findMatchPositions()` + `calculateBonuses()` pair. This is a two-state affine gap dynamic programming alignment (Smith-Waterman-style) that jointly optimizes word boundary bonuses, consecutive match bonuses, and gap penalties in a single pass. Two matrices track the best score at each (candidate position, query position) pair: one for the "match/consecutive" state and one for the "gap" state, with traceback to recover the optimal positions.

This avoids the greedy heuristic's tendency to lock into locally attractive positions that produce suboptimal global alignment — for example, choosing an early non-boundary match that forces large gaps later, when a slightly later boundary match would yield a higher total bonus.

For candidates longer than 512 bytes, `optimalAlignment()` falls back to the greedy `findMatchPositions()` + `calculateBonuses()` approach to avoid excessive memory and computation on very long strings.

### Zero-Allocation Design

The hot path (`score` method) achieves zero heap allocations through:

1. **Prepared Queries** - Query preprocessing (lowercasing, bitmask, trigrams) done once
2. **Reusable Buffers** - `ScoringBuffer` holds pre-allocated arrays:
   - DP rows for edit distance (3 rolling rows)
   - Candidate bytes buffer (lowercased copy)
   - Match positions array
   - Word initials buffer (for acronym matching)
   - Alignment state matrices (matchScore, gapScore, traceback) for DP-optimal alignment (queries > 4 chars)
3. **Capacity Management** - Buffers grow on demand (`ensureCapacity` only allocates when current capacity is insufficient) and periodically shrink: after a configurable check interval, if capacity exceeds 4x the high-water mark of recent usage, buffers are reallocated to 2x the high-water mark

### UTF-8 Processing

All string processing operates on raw UTF-8 bytes rather than Swift `Character` or `Unicode.Scalar` types:

```swift
candidate.utf8.withContiguousStorageIfAvailable { bytes in
    // Direct pointer access, no copying
}
```

**Case Handling:**
- ASCII letters (0x41-0x5A) are lowercased by setting bit 5: `byte | 0x20`
- Latin-1 Supplement (U+00C0–U+00DE, lead byte 0xC3): second byte is lowercased by adding 0x20 (e.g., Ä→ä, Ö→ö, Ü→ü, Å→å), excluding non-letter code points U+00D7 (×) and U+00DF (ß)
- Greek (lead bytes 0xCE, 0xCF): case folding handles two ranges — CE 91–9F adds 0x20 to the second byte (Α→α through Ο→ο), CE A0–A9 changes the lead byte to CF and subtracts 0x20 (Π→π through Ω→ω, skipping the unassigned CE A2). Sigma (Σ, CE A3 → σ, CF 83) is handled correctly.
- Cyrillic (lead bytes 0xD0, 0xD1): case folding handles three ranges — D0 90–9F adds 0x20 (А→а through П→п), D0 A0–AF changes lead to D1 and subtracts 0x20 (Р→р through Я→я), and D0 80–8F changes lead to D1 and adds 0x10 (Ё→ё and other U+0400–U+040F characters).
- Other non-ASCII bytes pass through unchanged
- Word boundary detection uses original bytes (not lowercased) to detect camelCase

**Why custom byte-level case folding instead of Swift's `lowercased()`:**

Swift's standard `String.lowercased()` is Unicode-correct and handles the full Unicode range, but it allocates a new `String` on every call and operates through the full `Character`/grapheme-cluster abstraction. In the hot scoring path — called once per candidate in a corpus of hundreds of thousands — this allocation and abstraction overhead is prohibitive. The byte-level approach:

1. **Zero allocations** — lowercasing writes directly into a pre-allocated buffer
2. **No iterator overhead** — direct indexed access into a `Span<UInt8>`
3. **ASCII fast path** — a single `byte >= 0x80` scan (with early exit) skips all multi-byte dispatch for the ~99% of candidates that are pure ASCII in typical financial instrument corpora
4. **Predictable branch costs** — the ASCII path is a simple bitwise OR; multi-byte dispatch only runs for the rare non-ASCII candidate

The trade-off is limited script coverage: only ASCII, Latin-1 Supplement, Greek, and basic Cyrillic are supported. Characters outside these ranges (e.g., CJK, Arabic, extended Cyrillic) pass through without case folding. This is acceptable for the library's primary use case of financial instruments, code identifiers, and Western-alphabet text.

### Unicode Support

FuzzyMatcher operates on UTF-8 bytes and supports case-insensitive matching for the following scripts:

| Script | Unicode Range | UTF-8 Lead Bytes | Examples |
|--------|--------------|-------------------|----------|
| ASCII | U+0000–U+007F | (single byte) | A→a, Z→z |
| Latin-1 Supplement | U+00C0–U+00FF | 0xC3 | Ä→ä, Ö→ö, Ü→ü, Å→å |
| Greek | U+0370–U+03FF | 0xCE, 0xCF | Α→α, Σ→σ, Ω→ω |
| Cyrillic (basic) | U+0400–U+047F | 0xD0, 0xD1 | А→а, Я→я, Ё→ё |

The primary corpus and use case has been financial instruments (stock tickers, fund names, ISINs), which are predominantly ASCII and Latin-1. Greek and Cyrillic support is provided as a courtesy for users who need these scripts, but they are not a primary target for the package.

#### Normalization

Two kinds of normalization are applied during the lowercasing pass, allowing visually similar characters to match interchangeably:

**Diacritic normalization** — Latin-1 Supplement diacritics (lead byte 0xC3) are folded to their ASCII base letters via `latin1ToASCII()`. For example, `é` (0xC3 0xA9) becomes `e` (0x65). Combining diacritical marks (U+0300–U+036F, lead bytes 0xCC/0xCD) are stripped entirely, so both precomposed (`café`) and decomposed (`cafe\u{0301}`) forms match `cafe`.

**Confusable-character normalization** — Visually similar punctuation and whitespace characters are collapsed to their ASCII canonical forms. Multi-byte confusables collapse to a single ASCII byte, exactly like Latin-1 diacritics:

| Group | Characters (UTF-8) | Canonical |
|-------|-------------------|-----------|
| Apostrophe-like | `'` `'` U+2018–2019 (0xE2 0x80 0x98–99), `` ` `` U+0060, `´` U+00B4 (0xC2 0xB4), `ʻ` U+02BB (0xCA 0xBB), `ʼ` U+02BC (0xCA 0xBC) | `'` U+0027 |
| Double-quote-like | `"` `"` U+201C–201D (0xE2 0x80 0x9C–9D) | `"` U+0022 |
| Dash-like | `‐` `‑` `‒` `–` `—` U+2010–2014 (0xE2 0x80 0x90–94), `−` U+2212 (0xE2 0x88 0x92) | `-` U+002D |
| Space-like | NBSP U+00A0 (0xC2 0xA0) | space U+0020 |

Both query and candidate are normalized identically during lowercasing, so the DP operates on already-normalized bytes. The lookup functions are:
- `confusableASCIIToCanonical(_:)` — maps grave accent (0x60 → 0x27)
- `confusable2ByteToASCII(lead:second:)` — handles 0xC2 (NBSP, acute accent) and 0xCA (ʻokina, modifier apostrophe) lead bytes
- `confusable3ByteToASCII(second:third:)` — handles 0xE2 lead byte (curly quotes, dashes, minus sign)

**What is byte-level:**
- Edit distance counts byte-level edits. Most Greek/Cyrillic single-character substitutions cost 1 byte edit (when the lead byte is preserved). Cross-lead-byte substitutions (e.g., Π→α, which changes both lead and second byte) cost 2 byte edits.
- Trigrams are byte-level 3-grams, not character-level.
- The character bitmask uses a hash of the (lead, second) byte pair for 2-byte characters, mapped into bits 37–63 of the 64-bit bitmask.

**What is not supported:**
- Characters beyond the basic Cyrillic block (e.g., Ukrainian Ґ U+0490, Serbian Ђ U+0402 with lead byte D2) are not case-folded
- CJK, Arabic, Devanagari, and other multi-byte scripts pass through without case folding
- Final sigma (ς, U+03C2) is not folded to medial sigma (σ) — they are treated as distinct characters
- Word boundary detection treats all 2-byte lead bytes (0xC3, 0xCE, 0xCF, 0xD0, 0xD1) and continuation bytes (0x80–0xBF) as alphanumeric, preventing false boundaries inside multi-byte characters

### Match Strategy

1. Check for **exact match** (score = 1.0, immediate return)
2. Compute **prefix edit distance**
3. If prefix score < 0.7 **and** prefix distance != 0, compute **substring edit distance**
4. For matches, compute **position bonuses**
5. If no edit distance match, try **subsequence matching** with bonuses
6. For short queries (2-8 chars), try **acronym matching** against word initials
7. Return best score above `minScore` threshold

---

## Complexity Analysis

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Query preparation | O(q) | q = query length |
| Length filter | O(1) | Simple comparison |
| Bitmask filter | O(1) | Bitwise operations + popcount |
| Trigram filter | O(c) | c = candidate length |
| Edit distance | O(q × min(c, q + maxED)) | Bounded by prefix limit |
| Boundary mask | O(min(c, 64)) | One-time per candidate |
| Position finding | O(q × k) | k = search lookahead (~q+5) |
| Bonus calculation | O(q) | Linear in query length |
| Acronym matching | O(min(64, c) + w) | O(1) popcount early exit; word-initial extraction for first 64 bytes via boundary mask, linear scan for longer candidates; subsequence check O(w) where w = word count |
| Tiny query (q=1) | O(c) | Single scan, bypasses entire pipeline |
| Short query (q≤4) | O(q × c) | Greedy positions instead of DP alignment |

**Overall per-candidate:** O(q × c) worst case, often O(1) with prefilter rejection

### Space Complexity

| Component | Space | Notes |
|-----------|-------|-------|
| FuzzyQuery | O(q) | Stores lowercased bytes, trigrams |
| ScoringBuffer | O(q + c) | DP rows + candidate + positions + word initials |
| Per-score call | O(1) | No allocations in hot path |

---

## Fuzz Testing

FuzzyMatcher includes a [libFuzzer](https://llvm.org/docs/LibFuzzer.html)-based fuzz target that validates scoring invariants over randomized inputs. Fuzz testing complements unit tests by exploring the vast input space of arbitrary (query, candidate, config) combinations that hand-written tests cannot cover.

### Platform Requirements

Swift's `-sanitize=fuzzer` flag requires the **open-source Swift toolchain** on Linux. It is **not available** in the Xcode toolchain on macOS. You need Swift 6.2+ installed on a Linux system (e.g., Ubuntu 24.04).

### Running the Fuzzer

```bash
# Build only (release, optimized)
bash Fuzz/run.sh

# Build and run (Ctrl-C to stop)
bash Fuzz/run.sh run

# Run for a fixed duration
bash Fuzz/run.sh run -max_total_time=60    # 60 seconds
bash Fuzz/run.sh run -max_total_time=300   # 5 minutes

# Debug build for investigating crashes with lldb
bash Fuzz/run.sh debug        # build only, with -Onone -g
bash Fuzz/run.sh debug run    # build debug + run
```

The release build uses `-O -whole-module-optimization` for realistic performance. The debug build uses `-Onone -g` for useful backtraces and variable inspection in lldb.

A corpus directory (`Fuzz/corpus/`) is automatically created on first run. libFuzzer saves interesting inputs there and reuses them to improve coverage across runs.

### Input Structure

The fuzzer generates random byte buffers and maps them to structured inputs:

```
[configByte] [splitByte] [stringData...]
```

- **configByte** selects one of 10 `MatchConfig` variants (via modulo)
- **splitByte** determines where to split stringData into query and candidate
- **stringData** bytes are mapped to printable ASCII (0x20–0x7E) to ensure valid UTF-8

### Config Variants

The fuzz target cycles through ten configurations — five edit distance and five Smith-Waterman — to exercise both algorithm paths:

#### Edit Distance Configs

| Index | Style | maxEditDistance | minScore | prefixWeight | substringWeight |
|-------|-------|----------------|----------|-------------|-----------------|
| 0 | Default | 2 | 0.3 | 1.5 | 1.0 |
| 1 | Exact only | 0 | 0.0 | 1.5 | 1.0 |
| 2 | Strict | 1 | 0.5 | 1.5 | 1.0 |
| 3 | Lenient | 3 | 0.0 | 1.5 | 1.0 |
| 4 | Picker-style | 2 | 0.0 | 4.0 | 0.5 |

#### Smith-Waterman Configs

| Index | Style | minScore | Key Differences |
|-------|-------|----------|-----------------|
| 5 | Default | 0.3 | Default SmithWatermanConfig |
| 6 | Lenient | 0.0 | Accept any match |
| 7 | Strict | 0.5 | Higher quality threshold |
| 8 | High gap penalty | 0.3 | gapStart=8, gapExtend=4 |
| 9 | No space splitting | 0.3 | splitSpaces=false (monolithic multi-word) |

### Invariants Checked

Every fuzz input validates five invariants:

**INVARIANT 1: No crash.** The `score()` method must never panic, trap, or access out-of-bounds memory for any input combination.

**INVARIANT 2: Score range.** If a result is returned, `0.0 <= score <= 1.0` and `score >= minScore`. This ensures the normalization formula and bonus calculations never produce values outside the valid range.

**INVARIANT 3: Self-match.** Every non-empty string scored against itself must return `score == 1.0` with `kind == .exact`. This validates that the exact-match check works for all printable ASCII inputs.

**INVARIANT 4: Empty query.** An empty query always matches any candidate with `score == 1.0`. This ensures the empty-query early return handles all candidate strings.

**INVARIANT 5: Buffer reuse.** Scoring the same (candidate, query) pair twice with the same buffer must produce identical results. This validates that buffer state from previous calls (including the self-match and empty-query checks above) does not corrupt subsequent scoring.

### Design Notes

**No symmetry invariant.** An earlier version checked that same-length strings produce symmetric scores (both > 0 if both match). This was removed because prefix edit distance is inherently asymmetric — it matches the query against any prefix of the candidate, including shorter prefixes. For example, `prefixED(" o", "o&") = 1` (matches 1-char prefix "o" with one deletion) but `prefixED("o&", " o") = 2` (no short prefix of " o" is close to "o&"). With asymmetric weights (e.g., prefixWeight=4.0 vs substringWeight=0.5), this causes one direction to score 0.875 via prefix while the reverse scores 0.0 via substring — a legitimate consequence of the algorithm design, not a bug.

### Results

A 60-second run on x86_64 Linux (Ubuntu 24.04, Swift 6.2) typically achieves:

- ~670K+ inputs executed
- ~11,000 exec/s throughput
- ~510 coverage edges explored
- Zero invariant violations

The corpus grows to ~470 entries / 40KB, with inputs ranging from 3 to ~1,400 bytes. libFuzzer's mutation strategies (crossover, erase, shuffle, insert, change) effectively explore edge cases in the scoring pipeline including empty strings, single characters, maximum-length inputs, and adversarial character combinations.

---

## References

### Edit Distance

1. Damerau, F. J. (1964). "A technique for computer detection and correction of spelling errors". *Communications of the ACM*, 7(3), 171-176.

2. Levenshtein, V. I. (1966). "Binary codes capable of correcting deletions, insertions, and reversals". *Soviet Physics Doklady*, 10(8), 707-710.

3. Wagner, R. A., & Fischer, M. J. (1974). "The string-to-string correction problem". *Journal of the ACM*, 21(1), 168-173.

### Prefiltering Techniques

4. Navarro, G. (2001). "A guided tour to approximate string matching". *ACM Computing Surveys*, 33(1), 31-88.

5. Ukkonen, E. (1992). "Approximate string-matching with q-grams and maximal matches". *Theoretical Computer Science*, 92(1), 191-211.

### Scoring Algorithms

6. Smith, T. F., & Waterman, M. S. (1981). "Identification of common molecular subsequences". *Journal of Molecular Biology*, 147(1), 195-197. *(Smith-Waterman algorithm)*

7. Needleman, S. B., & Wunsch, C. D. (1970). "A general method applicable to the search for similarities in the amino acid sequence of two proteins". *Journal of Molecular Biology*, 48(3), 443-453.

### Additional References

8. [PostgreSQL pg_trgm](https://www.postgresql.org/docs/current/pgtrgm.html) - Trigram-based fuzzy search

---

## Appendix: Algorithm Pseudocode

### Position Finding with Boundary Preference

```
function findMatchPositions(query, candidate, boundaryMask):
    positions = []
    candidateIndex = 0

    for queryIndex = 0 to query.length - 1:
        queryChar = query[queryIndex]
        bestPosition = -1
        foundBoundary = false

        // Look ahead for boundary match
        searchLimit = min(candidateIndex + query.length + 5, candidate.length)

        for searchPos = candidateIndex to searchLimit - 1:
            if candidate[searchPos] == queryChar:
                isBoundary = checkBoundary(searchPos, boundaryMask)
                if isBoundary:
                    bestPosition = searchPos
                    foundBoundary = true
                    break
                else if bestPosition == -1:
                    bestPosition = searchPos

        // Check for consecutive match
        if not foundBoundary and bestPosition != -1 and positions.length > 0:
            prevPos = positions[positions.length - 1]
            if prevPos + 1 < candidate.length and candidate[prevPos + 1] == queryChar:
                bestPosition = prevPos + 1

        // Scan rest if still not found
        if bestPosition == -1:
            for searchPos = searchLimit to candidate.length - 1:
                if candidate[searchPos] == queryChar:
                    bestPosition = searchPos
                    break

        if bestPosition == -1:
            return nil  // Match failed

        positions.append(bestPosition)
        candidateIndex = bestPosition + 1

    return positions
```

### Complete Scoring Flow

```
function score(candidate, query, buffer):
    // Prefilters
    if not passesLengthBounds(candidate, query): return nil
    if not passesCharBitmask(candidate, query): return nil
    if query.length >= 4 and query.trigrams.count > 3 * effectiveMaxEditDistance:
        if not passesTrigramFilter(candidate, query): return nil

    // Compute boundary mask for bonuses
    boundaryMask = computeBoundaryMask(candidate)

    // Try edit distance matching
    bestScore = 0
    bestKind = prefix

    prefixDist = prefixEditDistance(query, candidate)
    if prefixDist != nil:
        score = normalizedScore(prefixDist, query.length, prefixWeight)

        // Same-length near-exact boost (e.g., "UDS" → "USD", "MFST" → "MSFT")
        if candidate.length == query.length and prefixDist > 0:
            score += (1.0 - score) * 0.7

        // Calculate bonuses from match positions
        positions = findMatchPositions(query, candidate, boundaryMask)
        if positions != nil:
            bonuses = calculateBonuses(positions, boundaryMask, config)
            // Cap bonuses: non-exact matches can recover at most 80% of gap to 1.0
            if prefixDist > 0:
                maxBonus = (1.0 - score) * 0.8
                score += min(bonuses, maxBonus)
            else:
                score = min(score + bonuses, 1.0)

        // Length penalty (excess candidate length)
        lengthPenalty = (candidate.length - query.length) × config.lengthPenalty
        // Exact prefix matches recover 90% of length penalty
        if prefixDist == 0:
            lengthPenalty -= min(lengthPenalty × 0.9, 0.15)
        score -= lengthPenalty

        if score >= minScore:
            bestScore = score

    // Try substring if prefix weak and not exact prefix
    if bestScore < 0.7 and prefixDist != 0:
        substringDist = substringEditDistance(query, candidate)
        if substringDist != nil:
            score = normalizedScore(substringDist, query.length, substringWeight)
            // For short queries: if exact substring exists but greedy found
            // scattered positions, scan for contiguous occurrence
            if query.length <= 4 and substringDist == 0:
                if positions are non-contiguous:
                    contiguousStart = findContiguousSubstring(query, candidate, boundaryMask)
                    if contiguousStart >= 0:
                        replace positions with [contiguousStart..contiguousStart+query.length]
            score += calculateBonuses(positions, boundaryMask, config)

    // Fallback to subsequence matching
    if bestScore < minScore:
        positions = findMatchPositions(query, candidate, boundaryMask)
        if positions != nil and positions.length == query.length:
            score = computeSubsequenceScore(positions, candidate.length)
            score += calculateBonuses(positions, boundaryMask, config)
            if score > bestScore:
                bestScore = score

    // Acronym matching: check word-initial characters
    if query.length >= 2 and query.length <= 8:
        wordCount = popcount(boundaryMask)
        if wordCount >= 3 and wordCount >= query.length:
            initials = extractWordInitials(candidate, boundaryMask)
            if isSubsequence(query, initials):
                coverage = query.length / initials.count
                score = (0.55 + 0.4 × coverage) × config.acronymWeight
                if score > bestScore:
                    bestScore = score
                    bestKind = acronym

    return bestScore >= minScore ? ScoredMatch(bestScore, bestKind) : nil
```
