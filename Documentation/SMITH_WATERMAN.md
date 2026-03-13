# Smith-Waterman Mode — Algorithm Documentation

This document describes the **Smith-Waterman local alignment** matching mode available via `MatchingAlgorithm.smithWaterman`. For a high-level comparison of both matching modes, see [MATCHING_MODES.md](MATCHING_MODES.md). For the default edit distance pipeline, see [DAMERAU_LEVENSHTEIN.md](DAMERAU_LEVENSHTEIN.md).

## Table of Contents

1. [Overview](#overview)
2. [Comparison with Edit Distance Mode](#comparison-with-edit-distance-mode)
3. [Scoring Pipeline](#scoring-pipeline)
4. [Prefiltering](#prefiltering)
5. [Boundary Bonus Precomputation](#boundary-bonus-precomputation)
6. [Smith-Waterman DP Core](#smith-waterman-dp-core)
7. [Consecutive Bonus Propagation](#consecutive-bonus-propagation)
8. [Score Normalization](#score-normalization)
9. [Multi-Word Queries](#multi-word-queries)
10. [Acronym Fallback](#acronym-fallback)
11. [Highlight Traceback](#highlight-traceback)
12. [Configuration](#configuration)
13. [Implementation Details](#implementation-details) — Memory Layout, ASCII Fast Path, Multi-Byte Slow Path, Zero-Allocation Design
14. [Complexity Analysis](#complexity-analysis)
15. [Worked Examples](#worked-examples)
16. [References](#references)

---

## Overview

The Smith-Waterman mode implements a **bonus-driven** local alignment scorer inspired by [nucleo](https://github.com/helix-editor/nucleo) and [fzf](https://github.com/junegunn/fzf). Instead of counting penalties (edit distance), it awards points for each matched character and adds bonuses for desirable alignment properties:

- **Word boundary matches** (after whitespace, delimiters, or non-word characters)
- **camelCase transitions** (lowercase-to-uppercase)
- **Consecutive match runs** (contiguous character sequences)
- **First character emphasis** (multiplied bonus on the first matched character)

Gaps between matched characters receive an **affine penalty** (opening cost + extension cost), encouraging tight alignments.

All arithmetic in the inner loop is **Int32-only**. Floating-point normalization to 0.0–1.0 happens once after the DP completes.

---

## Comparison with Edit Distance Mode

| Aspect | Edit Distance Mode | Smith-Waterman Mode |
|--------|-------------------|---------------------|
| Philosophy | Penalty-driven (count errors) | Bonus-driven (reward matches) |
| Pipeline | Multi-phase (exact → prefix → substring → subsequence → acronym) | Single DP pass + acronym fallback |
| Scoring arithmetic | Floating-point throughout | Int32 DP, normalize once at end |
| Prefilters | Length bounds + bitmask + trigrams | Bitmask only (tolerance 0) |
| Gap model | Post-hoc affine penalty on found positions | Integrated affine gap in the DP |
| Multi-word queries | Treated as monolithic string | Split into atoms with AND semantics |
| Match kinds returned | `.exact`, `.prefix`, `.substring`, `.acronym` | `.exact`, `.alignment`, `.acronym` |
| Best for | Typo-tolerant search with edit budget | Ranking-quality alignment scoring |

---

## Scoring Pipeline

```
Candidate → Bitmask Prefilter → Lowercase + Bonus Precomputation → Exact Match Check
                                                                        ↓
                                                              Smith-Waterman DP
                                                                        ↓
                                                                  Normalize Score
                                                                        ↓
                                                                Acronym Fallback
                                                                        ↓
                                                          max(SW, Acronym) → Result
```

For multi-word queries, the DP runs once per atom with AND semantics (all atoms must match).

---

## Prefiltering

Smith-Waterman mode uses a single prefilter: the **64-bit character bitmask** with **tolerance 0**.

```
missingChars = queryMask & ~candidateMask
pass = popcount(missingChars) == 0
```

With tolerance 0, **any** character present in the query but absent from the candidate causes immediate rejection. This is stricter than the edit distance mode (which allows missing characters up to `effectiveMaxEditDistance` for longer queries), but appropriate for a local alignment scorer that does not model substitutions — a missing character in the candidate means the DP cannot align it.

The bitmask is computed in a single O(n) pass that also determines whether the candidate is pure ASCII, enabling the fast path for lowercase + bonus precomputation.

Length bounds and trigram filtering are **not used** in Smith-Waterman mode. The bitmask provides sufficient rejection for the local alignment model.

---

## Boundary Bonus Precomputation

Before the DP runs, a single O(n) scan computes two arrays simultaneously:

1. **Lowercased candidate bytes** — written into the reusable `CandidateStorage.bytes` buffer
2. **Per-position bonus values** — written into `CandidateStorage.bonus` as `Int32`

### Bonus Tiers

The bonus system uses a **tiered model** matching nucleo's character-class hierarchy:

| Tier | Default Value | Condition |
|------|:------------:|-----------|
| Whitespace boundary | 10 | Position 0, or previous character is space/tab |
| Delimiter boundary | 9 | Previous character is `/`, `:`, `;`, or `\|` |
| General boundary | 8 | Previous character is non-alphanumeric, non-whitespace (e.g., `_`, `-`, `.`) |
| camelCase / digit transition | 5 | Lowercase→uppercase, or non-digit→digit |
| Whitespace character itself | 10 | Current character is whitespace |
| Non-word character itself | 8 | Current character is non-alphanumeric and non-whitespace |
| No bonus | 0 | Mid-word alphanumeric character |

The tiered model reflects that **whitespace-delimited words** are the strongest signal, followed by **path delimiters**, then **general non-word separators**, and finally **camelCase transitions**.

### ASCII Fast Path

When the candidate is pure ASCII (detected during the bitmask scan), the merged pass uses direct byte comparisons:

```
for each position i in candidate:
    lowercased[i] = byte | 0x20  (if uppercase ASCII)
    bonus[i] = tierFromPreviousByte(prevByte, currentByte)
```

### Multi-Byte Slow Path

For candidates containing Latin-1 Supplement (0xC3), Greek (0xCE/0xCF), or Cyrillic (0xD0/0xD1) characters, the slow path dispatches to the appropriate case-folding function and uses `multiByteBonusTier()` for bonus assignment. Continuation bytes within a multi-byte character receive bonus 0.

---

## Smith-Waterman DP Core

### Three-State Recurrence

The DP maintains three logical rows, each of width `queryLen`:

| Row | Symbol | Meaning |
|-----|--------|---------|
| Match | `M[j]` | Best score ending with `candidate[i]` matched to `query[j]` as a consecutive match |
| Gap | `G[j]` | Best score with a gap ending at `candidate[i]` (query[j] was matched earlier) |
| Bonus | `B[j]` | Carried consecutive bonus from the start of the current match run |

All three rows are stored in a single flat `[Int32]` buffer with layout `[match₀..matchₙ | gap₀..gapₙ | bonus₀..bonusₙ]`.

### Diagonal Carry Optimization

The recurrence needs values from `[i-1, j-1]` (diagonal). Instead of maintaining separate "previous" rows and swapping, diagonal values are carried as **scalar variables** during the left-to-right inner loop:

```
diagMatch = old M[i-1, j-1]
diagGap   = old G[i-1, j-1]
diagBonus = old B[i-1, j-1]
```

Before overwriting `M[j]`, `G[j]`, `B[j]` with new values, the old values are saved and become the diagonal for the next `j` iteration. This eliminates row-swap logic entirely.

### Recurrence Relations

For each candidate position `i` and query position `j`:

**Gap transition** (using values from row above: `M[i-1,j]` and `G[i-1,j]`):

```
G[j] = max(
    0,
    M[i-1,j] - penaltyGapStart,     // open a new gap from a match
    G[i-1,j] - penaltyGapExtend      // extend an existing gap
)
```

**Match transition** (using diagonal values from `[i-1, j-1]`):

```
if candidate[i] == query[j]:
    if j == 0:
        // First query character: fresh alignment start
        M[j] = scoreMatch + posBonus[i] × firstCharMultiplier
        B[j] = posBonus[i]
    else:
        // From consecutive match (diagonal match state)
        if diagMatch > 0:
            carriedBonus = max(diagBonus, bonusConsecutive)
            if posBonus[i] >= bonusBoundary and posBonus[i] > carriedBonus:
                carriedBonus = posBonus[i]
            effectiveBonus = max(carriedBonus, posBonus[i])
            fromConsecutive = diagMatch + scoreMatch + effectiveBonus

        // From gap-to-match (diagonal gap state)
        if diagGap > 0:
            fromGap = diagGap + scoreMatch + posBonus[i]

        M[j] = max(fromConsecutive, fromGap)
        B[j] = (winner's carried bonus)
else:
    M[j] = 0   // no match possible
    B[j] = 0
```

**Zero-floor convention:** A value of 0 means "no valid state". All valid scores are strictly positive (since `scoreMatch > 0`). This replaces the need for sentinel values or optional types.

### Best Score Tracking

After each candidate position `i`, the algorithm checks the last query column (`j = queryLen - 1`):

```
bestScore = max(bestScore, M[queryLen-1], G[queryLen-1])
```

This finds the best **local** alignment ending at any candidate position — the Smith-Waterman hallmark.

### Pseudocode

```
function smithWatermanScore(query, candidate, bonus, state, config):
    // Initialize 3 rows to zero
    for j in 0..<queryLen:
        M[j] = 0; G[j] = 0; B[j] = 0

    bestScore = 0

    for i in 0..<candidateLen:
        diagMatch = 0; diagGap = 0; diagBonus = 0

        for j in 0..<queryLen:
            // Save old values before overwrite
            oldMatch = M[j]; oldGap = G[j]; oldBonus = B[j]

            // Gap transition
            newGap = max(0, oldMatch - gapStart, oldGap - gapExtend)
            G[j] = newGap

            // Match transition
            if candidate[i] == query[j]:
                if j == 0:
                    M[j] = scoreMatch + bonus[i] * firstCharMultiplier
                    B[j] = bonus[i]
                else:
                    compute fromConsecutive using diagMatch, diagBonus
                    compute fromGap using diagGap
                    M[j] = max(fromConsecutive, fromGap)
                    B[j] = corresponding bonus
            else:
                M[j] = 0; B[j] = 0

            // Diagonal carry
            diagMatch = oldMatch; diagGap = oldGap; diagBonus = oldBonus

        // Track best at last query position
        bestScore = max(bestScore, M[queryLen-1], G[queryLen-1])

    return bestScore
```

---

## Consecutive Bonus Propagation

A key feature borrowed from nucleo is **consecutive bonus carry-forward**. When characters match consecutively at a word boundary, the boundary bonus propagates through the entire consecutive run rather than applying only to the boundary position.

### Mechanism

1. When a character matches at a boundary, `B[j]` is set to the position bonus (e.g., 8 for a word boundary)
2. For the next consecutive match, `carriedBonus = max(diagBonus, bonusConsecutive)` — the carried bonus is at least `bonusConsecutive` (4)
3. If the current position has a strong boundary (`posBonus >= bonusBoundary`), the carried bonus upgrades to the position bonus
4. The effective bonus for this match is `max(carriedBonus, posBonus)` — whichever is higher

### Example

```
Query: "bar"
Candidate: "foo_bar"
Bonus array: [10, 0, 0, 0, 8, 0, 0]
              f   o   o   _  b   a   r

Alignment at positions 4, 5, 6:
  'b' at position 4 (boundary bonus = 8):
    M = 16 + 8*2 = 32  (first char multiplied)
    B = 8

  'a' at position 5 (posBonus = 0):
    carriedBonus = max(8, 4) = 8
    effectiveBonus = max(8, 0) = 8
    M = 32 + 16 + 8 = 56
    B = 8 (carried forward)

  'r' at position 6 (posBonus = 0):
    carriedBonus = max(8, 4) = 8
    effectiveBonus = max(8, 0) = 8
    M = 56 + 16 + 8 = 80
    B = 8 (carried forward)
```

Without carry-forward, positions 5 and 6 would receive only `bonusConsecutive = 4`. With carry-forward, they receive the full boundary bonus of 8, making boundary-aligned runs significantly more valuable than scattered boundary matches.

---

## Score Normalization

The raw Int32 score from the DP is normalized to 0.0–1.0 by dividing by the **maximum possible score** for the query.

### Maximum Score Formula

The maximum assumes a perfect alignment: all characters match consecutively at whitespace boundaries (the highest-bonus tier), with consecutive bonus carry-forward:

```
maxScore = queryLen × scoreMatch
         + bonusBoundaryWhitespace × (firstCharMultiplier + queryLen - 1)
```

Breaking this down:
- Each character contributes `scoreMatch` (16)
- The first character gets `bonusBoundaryWhitespace × firstCharMultiplier` (10 × 2 = 20)
- Each subsequent character gets `bonusBoundaryWhitespace` (10) via carry-forward

For the default config with a 4-character query:

```
maxScore = 4 × 16 + 10 × (2 + 3) = 64 + 50 = 114
```

### Normalization

```
normalizedScore = clamp(rawScore / maxScore, 0.0, 1.0)
```

The `minScore` threshold (default 0.3) is applied after normalization to filter weak matches.

---

## Multi-Word Queries

When `SmithWatermanConfig.splitSpaces` is `true` (default) and the query contains spaces, the query is split into independent **atoms** — one per non-empty word.

### Splitting

```
Query: "johnson johnson"
Atoms: ["johnson", "johnson"]

Query: "  procter  gamble  "
Atoms: ["procter", "gamble"]  (leading/trailing/repeated spaces trimmed)
```

### AND Semantics

Each atom is scored independently against the full candidate. **All atoms must match** (score > 0) for the candidate to pass. The total raw score is the sum of per-atom scores.

```
for each atom in query.atoms:
    atomScore = smithWatermanScore(atom, candidate, bonus, state, config)
    if atomScore <= 0:
        return nil           // AND: any failure rejects
    totalRawScore += atomScore

maxScore = sum of per-atom maxScores
normalizedScore = totalRawScore / maxScore
```

### Per-Atom Max Score

Each atom's max score is computed independently using its length:

```
atomMaxScore = atomLen × scoreMatch
             + bonusBoundaryWhitespace × (firstCharMultiplier + atomLen - 1)
```

### Why Split?

Monolithic multi-word alignment fails when one word contains a typo — the DP may not bridge across the gap. Splitting into atoms allows each word to find its best local alignment independently. This matches the behavior of nucleo and fzf.

### Single-Word Queries

When a query has no spaces (or `splitSpaces` is `false`), `atoms` is empty and the standard single-DP-pass path runs.

---

## Acronym Fallback

After the Smith-Waterman DP, short queries (2–8 characters) attempt **acronym matching** as a competing scorer. The higher score wins.

### Conditions

The acronym pass runs when:
1. Query length is 2–8 characters
2. Candidate has at least 3 words (via `popcount(boundaryMask)`)
3. Candidate has at least as many words as query characters

### Algorithm

1. Compute the boundary mask from the **original** (non-lowercased) candidate bytes
2. Extract word-initial characters from the lowercased candidate
3. Check if the query is a subsequence of the initials
4. Score by coverage: `score = 0.55 + 0.4 × (queryLen / initialCount)`

### Competition with SW

The acronym score competes with the SW score. The higher one wins:

```
if acronymScore > swScore and acronymScore >= minScore:
    return (acronymScore, .acronym)
else if swScore >= minScore:
    return (swScore, .alignment)
```

### Example

```
Query: "bms"
Candidate: "Bristol-Myers Squibb"

Boundary mask: bits at 0, 8, 14 → word initials: [b, m, s]
Subsequence check: b→b, m→m, s→s ✓
Coverage: 3/3 = 1.0
Score: 0.55 + 0.4 × 1.0 = 0.95 → kind = .acronym
```

---

## Highlight Traceback

The `highlight(_:against:)` method recovers matched character positions from the Smith-Waterman alignment for UI highlighting. It uses a full-matrix variant of the SW DP (`smithWatermanPositions()`) that retains the complete match, gap, bonus, and trace matrices so positions can be recovered via traceback.

### How It Works

1. **Normalization** — build a `mapping[normalizedByteIndex] = originalByteOffset` array mirroring the merged lowercase + bonus pass
2. **Full-matrix SW DP** — same three-state recurrence as the scoring DP, but stores all rows (not just the current one) plus traceback flags at each cell
3. **Traceback** — from the best score at the last query column, trace back through the matrix collecting matched candidate positions
4. **Multi-word queries** — run one traceback per atom, concatenate position arrays
5. **Acronym fallback** — if acronym score beats SW score, use word-initial positions instead
6. **Map to ranges** — convert normalized byte positions through the mapping array to `Range<String.Index>`, coalesce adjacent ranges

### Differences from ED Highlight

| Aspect | ED Highlight | SW Highlight |
|--------|-------------|-------------|
| Typo support | Substituted positions highlighted | No — all query chars must exist |
| Pipeline | Multi-phase fallback chain | Single DP pass |
| Multi-word | Monolithic alignment | Per-atom traceback |
| Scoring consistency | Priority-ordered phases | Same DP as scoring |

This method is completely separate from the scoring hot path. The full-matrix DP allocates O(q × c) space, which is acceptable since it runs only for visible results (~10-20 candidates).

---

## Configuration

Smith-Waterman mode is controlled by `SmithWatermanConfig`. All values are integers to keep the inner loop free of floating-point arithmetic.

| Parameter | Default | Description |
|-----------|:-------:|-------------|
| `scoreMatch` | 16 | Points per matched character |
| `penaltyGapStart` | 3 | Penalty for opening a new gap |
| `penaltyGapExtend` | 1 | Penalty for extending an existing gap |
| `bonusConsecutive` | 4 | Minimum bonus for consecutive matches |
| `bonusBoundary` | 8 | Bonus for matching at a general word boundary |
| `bonusBoundaryWhitespace` | 10 | Bonus for matching after whitespace (strongest) |
| `bonusBoundaryDelimiter` | 9 | Bonus for matching after a delimiter (`/`, `:`, `;`, `\|`) |
| `bonusCamelCase` | 5 | Bonus for matching at a camelCase or digit transition |
| `bonusFirstCharMultiplier` | 2 | Multiplier on the first matched character's bonus |
| `splitSpaces` | true | Split multi-word queries into independent atoms |

### Usage

```swift
// Default Smith-Waterman mode
let matcher = FuzzyMatcher(config: .smithWaterman)

// Custom tuning
let custom = SmithWatermanConfig(
    scoreMatch: 20,
    penaltyGapStart: 5,
    penaltyGapExtend: 2,
    bonusConsecutive: 6,
    bonusBoundary: 10,
    bonusCamelCase: 7,
    bonusFirstCharMultiplier: 3
)
let config = MatchConfig(algorithm: .smithWaterman, smithWatermanConfig: custom)
let matcher = FuzzyMatcher(config: config)
```

### Shared Parameters

The following `MatchConfig` parameters are shared between both modes:

- `minScore` — minimum normalized score threshold (default 0.3)

The edit-distance-specific parameters (`maxEditDistance`, `prefixWeight`, `substringWeight`, `wordBoundaryBonus`, `consecutiveBonus`, `gapPenalty`, `firstMatchBonus`, `firstMatchBonusRange`, `lengthPenalty`, `acronymWeight`) are **ignored** in Smith-Waterman mode.

---

## Implementation Details

### Memory Layout

The DP state is stored in `SmithWatermanState`, which holds a single flat `[Int32]` buffer of size `3 × queryCapacity`:

```
[match₀ match₁ ... matchₙ | gap₀ gap₁ ... gapₙ | bonus₀ bonus₁ ... bonusₙ]
 ← queryLen elements →     ← queryLen elements →  ← queryLen elements →
```

Offsets:
- Match row: `buf[0 ..< queryLen]`
- Gap row: `buf[queryLen ..< 2*queryLen]`
- Bonus row: `buf[2*queryLen ..< 3*queryLen]`

This contiguous layout provides cache-friendly access during the inner loop.

### ASCII Fast Path

The merged lowercase + bonus precomputation pass detects pure-ASCII candidates via the bitmask scan (`byte >= 0x80` check). For ASCII-only candidates (~99% of typical financial instrument corpora), the pass uses:

- Direct byte comparisons for character classification (upper/lower/digit/whitespace)
- `byte | 0x20` for lowercasing
- No multi-byte dispatch

### Multi-Byte Slow Path

For candidates containing non-ASCII characters, the slow path:

1. **Combining marks** (0xCC/0xCD) — stripped entirely (same as edit distance mode)
2. **Latin-1 diacritics** (0xC3) — case-folded and normalized to ASCII base letters when possible (e.g., `é` → `e`)
3. **Greek** (0xCE/0xCF) and **Cyrillic** (0xD0/0xD1) — case-folded, emitting 2 output bytes
4. **Confusable characters** (0xC2/0xCA for 2-byte, 0xE2 for 3-byte) — normalized to canonical ASCII (e.g., curly quotes → `'`, en-dash → `-`, NBSP → space), emitting 1 output byte with the appropriate bonus tier (NBSP gets whitespace boundary bonus; punctuation gets general boundary bonus)
5. Uses `multiByteBonusTier()` for boundary classification of non-confusable multi-byte characters
6. Assigns bonus 0 to continuation bytes within a multi-byte character

### Zero-Allocation Design

The Smith-Waterman mode follows the same zero-allocation pattern as the edit distance mode:

1. **Prepared queries** — `FuzzyQuery` precomputes `lowercased`, `charBitmask`, `atoms`, and `maxSmithWatermanScore`
2. **Reusable buffers** — `ScoringBuffer` holds `CandidateStorage` (bytes + bonus arrays) and `SmithWatermanState` (DP rows)
3. **Capacity management** — buffers grow via `ensureCapacity` and shrink periodically (4x threshold → 2x high-water mark)

Each call to `score()` uses only the pre-allocated buffers with zero heap allocations.

### Orchestration

`FuzzyMatcher+SmithWaterman.swift` contains the `scoreSmithWatermanImpl()` method, which orchestrates:

1. Empty input handling
2. Buffer capacity checks
3. Bitmask prefilter (tolerance 0)
4. Merged lowercase + bonus precomputation (ASCII fast path or multi-byte slow path)
5. Multi-atom path (if `atoms.count > 1`): score each atom independently with AND semantics
6. Single-word path: exact match early exit → SW DP → acronym fallback
7. Return best score above `minScore`

---

## Complexity Analysis

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Query preparation | O(q) | Lowercasing, bitmask, atom splitting |
| Bitmask prefilter | O(c) | Single pass for bitmask + ASCII detection |
| Lowercase + bonus pass | O(c) | Merged into one scan |
| Exact match check | O(q) | Byte-by-byte comparison |
| Smith-Waterman DP | O(q × c) | Core inner loop |
| Score normalization | O(1) | Division + clamp |
| Acronym fallback | O(min(64, c) + w) | Boundary mask extraction + subsequence check |
| Multi-atom total | O(a × q_avg × c) | `a` atoms, each scored independently |

**Overall per-candidate:** O(q × c) for single-word queries, O(1) with bitmask rejection.

### Space Complexity

| Component | Space | Notes |
|-----------|-------|-------|
| FuzzyQuery | O(q) | Lowercased bytes, atoms, bitmask |
| SmithWatermanState | O(q) | 3 rows × queryLen Int32 elements |
| CandidateStorage | O(c) | Lowercased bytes + Int32 bonus array |
| Per-score call | O(1) | No allocations in hot path |

---

## Worked Examples

### Example 1: Simple Prefix Match

```
Query:     "get"  (queryLen = 3)
Candidate: "getUserById"
Config:    default SmithWatermanConfig

Step 1 — Bitmask prefilter:
  queryMask has bits for g, e, t
  candidateMask has bits for g, e, t, u, s, r, b, y, i, d
  Missing = 0 → passes

Step 2 — Lowercase + bonus:
  Lowercased: "getuserbyid"
  Bonus:      [10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
               g   e   t  U→u s   e   r  B→b y  I→i d
  (position 0 gets whitespace bonus 10; camelCase at 3,7,9)
  Bonus:      [10, 0, 0, 5, 0, 0, 0, 5, 0, 5, 0]
               g   e   t  U   s   e   r  B   y  I   d

Step 3 — SW DP (showing match row for last query char 't'):
  i=0 (g): M[0] = 16 + 10*2 = 36    (first char, whitespace bonus)
  i=1 (e): M[1] = 36 + 16 + max(10, 4, 0) = 62  (consecutive, carried bonus = 10)
  i=2 (t): M[2] = 62 + 16 + max(10, 4, 0) = 88  (consecutive, carried bonus = 10)
  → rawScore = 88

Step 4 — Normalize:
  maxScore = 3 × 16 + 10 × (2 + 2) = 48 + 40 = 88
  normalizedScore = 88 / 88 = 1.0

  But wait — exact match check would fire first since
  "get" != "getuserbyid" (different lengths), so no exact match.
  Result: ScoredMatch(score: 1.0, kind: .alignment)
```

### Example 2: Scattered Match with Gap

```
Query:     "ac"  (queryLen = 2)
Candidate: "axxxxc"
Config:    default

Bonus: [10, 0, 0, 0, 0, 0]  (position 0 = whitespace bonus)

DP trace:
  i=0 (a): M[0] = 16 + 10*2 = 36  (first char)
  i=1 (x): G[0] = 36 - 3 = 33     (gap start)
  i=2 (x): G[0] = 33 - 1 = 32     (gap extend)
  i=3 (x): G[0] = 32 - 1 = 31
  i=4 (x): G[0] = 31 - 1 = 30
  i=5 (c): M[1] = 30 + 16 + 0 = 46  (from gap, posBonus = 0)

rawScore = 46
maxScore = 2 × 16 + 10 × (2 + 1) = 32 + 30 = 62
normalizedScore = 46 / 62 ≈ 0.742
```

### Example 3: Multi-Word Query

```
Query:     "johnson johnson"
Candidate: "Johnson & Johnson"
Config:    default (splitSpaces = true)

Atoms: ["johnson", "johnson"]

Atom 1 ("johnson"):
  Aligns to "Johnson" at start → strong boundary match
  rawScore₁ = high (boundary + consecutive)

Atom 2 ("johnson"):
  Aligns to "Johnson" at end → boundary match after space
  rawScore₂ = high

totalRawScore = rawScore₁ + rawScore₂
maxScore = 2 × (7 × 16 + 10 × (2 + 6)) = 2 × (112 + 80) = 384
normalizedScore = totalRawScore / 384

Both atoms found → match returned as .alignment
```

### Example 4: Acronym Beats SW

```
Query:     "bms"  (3 chars, in 2-8 range)
Candidate: "Bristol-Myers Squibb"

SW DP: "bms" scattered across "bristol-myers squibb"
  → rawScore is modest (gaps between b, m, s)

Acronym check:
  Boundary mask: bits at 0 (B), 8 (M), 14 (S)
  Word initials: [b, m, s]
  Subsequence: b→b, m→m, s→s ✓
  Coverage: 3/3 = 1.0
  Score: 0.55 + 0.4 × 1.0 = 0.95

Acronym score (0.95) > SW score → return .acronym
```

---

## References

1. Smith, T. F., & Waterman, M. S. (1981). "Identification of common molecular subsequences". *Journal of Molecular Biology*, 147(1), 195-197.

2. [nucleo](https://github.com/helix-editor/nucleo) — High-performance fuzzy matcher for Helix editor. Inspired the bonus-driven scoring model and consecutive bonus propagation.

3. [fzf](https://github.com/junegunn/fzf) — Command-line fuzzy finder. The scoring constants (scoreMatch=16, boundary ratios) are aligned with fzf's proven ratios.

4. Gotoh, O. (1982). "An improved algorithm for matching biological sequences". *Journal of Molecular Biology*, 162(3), 705-708. *(Affine gap penalties in sequence alignment)*
