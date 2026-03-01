# Quality & Performance

How FuzzyMatch compares to established fuzzy matchers and what to expect from its performance.

## Overview

FuzzyMatch has been compared against established fuzzy matching implementations — [fzf](https://github.com/junegunn/fzf) (Go), [nucleo](https://github.com/helix-editor/nucleo) (Rust), [RapidFuzz](https://github.com/rapidfuzz/rapidfuzz-cpp) (C++), and [Ifrit](https://github.com/ukushu/Ifrit) (Swift) — on a corpus of 272K financial instruments across 197 test queries. The quality comparison below uses the default edit distance mode. See [COMPARISON.md](https://github.com/ordo-one/FuzzyMatch/blob/main/COMPARISON.md) for full results including Smith-Waterman mode.

## Quality Comparison

| Metric | FuzzyMatch | nucleo | fzf |
|--------|-----------|--------|-----|
| Queries returning results | **197/197** | 190/197 | 186/197 |
| Top-1 agreement with fzf | **129/197** | 87/197 | — |

FuzzyMatch achieves the highest hit rate among precision-focused matchers and the highest pairwise agreement with fzf (65%), the de facto standard for fuzzy search.

### Typo Handling

FuzzyMatch's Damerau-Levenshtein foundation handles transposition typos that other matchers miss entirely:

| Query (typo) | FuzzyMatch | nucleo | fzf |
|--------------|-----------|--------|-----|
| "Voeing" (B→V adjacent) | Found | Not found | Not found |
| "Gokdman Sachs" (l→k adjacent) | Found | Not found | Not found |
| "Govenrment" | Found | Found | Found |
| "isahres" | Found | Found | Found |

### Abbreviation Handling

FuzzyMatch's acronym matching pass finds the correct company for 7/12 abbreviation queries, outperforming all other matchers:

| Query | FuzzyMatch | nucleo | fzf |
|-------|-----------|--------|-----|
| "bms" → Bristol-Myers Squibb | **Found** | Not found | Not found |
| "tfs" → Thermo Fisher Scientific | **Found** | **Found** | **Found** |
| "gmc" → General Motors Company | **Found** | Not found | Not found |
| "csc" → Columbia Sportswear Co | **Found** | Not found | Not found |

### Overall Assessment

| | Hit Rate | Typo Handling | Short Queries | Abbreviations | Precision |
|---|---|---|---|---|---|
| **FuzzyMatch** | 197/197 | Best | Good | Good (7/12) | High |
| **fzf** | 186/197 | None | Good | Poor (2/12) | High |
| **nucleo** | 190/197 | Decent | Poor | Poor (2/12) | Medium |

### Smith-Waterman Mode

In Smith-Waterman mode, FuzzyMatch trades typo tolerance for higher throughput and nucleo-compatible rankings:

| Metric | FuzzyMatch (ED) | FuzzyMatch (SW) | nucleo |
|--------|---------|---------|--------|
| Hit rate | **197/197** | 187/197 | 190/197 |
| Top-1 agreement with nucleo | 77/197 | **182/197** | — |
| Throughput | 26M/sec | 44M/sec | 86M/sec |

FuzzyMatch (SW) agrees with nucleo on 92% of top-1 rankings (182/197). It excels at multi-word queries and long descriptive searches, but loses 10 queries that require edit distance typo tolerance. Use Smith-Waterman mode when you need maximum throughput or nucleo-compatible behavior; use the default edit distance mode when typo tolerance matters.

## Performance

FuzzyMatch processes ~26 million candidates per second in edit distance mode and ~44 million in Smith-Waterman mode on Apple Silicon (M4 Max). While nucleo (Rust, Smith-Waterman variant) is 1.3–4.9x faster in raw throughput, both FuzzyMatch modes comfortably handle interactive-speed search:

| | Throughput |
|---|---|
| nucleo (Rust) | ~86M candidates/sec |
| FuzzyMatch — SW (Swift) | ~44M candidates/sec |
| FuzzyMatch — ED (Swift) | ~26M candidates/sec |

The gap narrows to **1.3x** for exact symbol queries and widens to **4.9x** for exact name queries where FuzzyMatch's longer-query scoring overhead dominates.

### Benchmark Examples

Typical performance on Apple Silicon:

| Scenario | Time |
|----------|------|
| Query preparation | ~2.2 μs |
| 1M dataset (single-threaded) | ~36 ms |
| 1M dataset (8 workers) | ~4.8 ms |

Run benchmarks locally with:

```bash
swift package --package-path Benchmarks benchmark
```

## Unicode Support

FuzzyMatch supports case-insensitive matching for ASCII, Latin-1 Supplement (Ä→ä, Ö→ö, Å→å), Greek (Α→α, Σ→σ, Ω→ω), and basic Cyrillic (А→а, Я→я, Ё→ё). Greek and Cyrillic support is provided as a courtesy for users who need these scripts, but they are not a primary target for the package. All string processing operates on raw UTF-8 bytes — custom byte-level case folding is used instead of Swift's `String.lowercased()` to avoid per-call allocations in the hot scoring path. An ASCII fast path skips multi-byte dispatch for the vast majority of candidates, maintaining full throughput on ASCII-dominant corpora.

Two kinds of normalization are applied during matching:
- **Diacritic normalization** — Latin-1 diacritics fold to ASCII base letters (`café` → `cafe`); combining marks (U+0300–U+036F) are stripped
- **Confusable-character normalization** — visually similar punctuation and whitespace collapse to canonical ASCII forms (curly quotes → `'`, en-dash → `-`, NBSP → space, ʻokina → `'`)

Both matching modes share the same UTF-8 processing, case folding, and normalization. See [DAMERAU_LEVENSHTEIN.md](https://github.com/ordo-one/FuzzyMatch/blob/main/Documentation/DAMERAU_LEVENSHTEIN.md#unicode-support) for the full list of supported scripts and byte-level semantics.

## Zero-Allocation Design

The high-performance API (``FuzzyMatcher/score(_:against:buffer:)``) performs zero heap allocations when using prepared queries and reusable buffers. This is achieved through:

- **Prepared queries** — ``FuzzyQuery`` precomputes lowercased bytes, bitmask, and trigrams once
- **Reusable buffers** — ``ScoringBuffer`` holds pre-allocated arrays for DP rows, candidate bytes, and match positions
- **Automatic memory management** — Buffers grow when needed and periodically shrink when recent usage is much smaller than allocated capacity

This design is critical for responsive UI and high-throughput batch processing scenarios.

### Choosing the Right API

FuzzyMatch provides two API levels that produce identical results:

| API | When to use | Allocations |
|-----|-------------|-------------|
| ``FuzzyMatcher/score(_:against:buffer:)`` | Production hot paths, interactive search, batch processing | Zero (after buffer warmup) |
| ``FuzzyMatcher/score(_:against:)`` | One-off checks, prototyping | Per-call (buffer + query) |
| ``FuzzyMatcher/topMatches(_:against:limit:)`` | Quick top-N results | Per-call (buffer) |
| ``FuzzyMatcher/matches(_:against:)`` | Quick sorted results | Per-call (buffer) |

The convenience methods (``FuzzyMatcher/score(_:against:)``, ``FuzzyMatcher/topMatches(_:against:limit:)``, ``FuzzyMatcher/matches(_:against:)``) allocate a buffer internally on each call. For scoring loops over many candidates, the high-performance API with an explicit buffer avoids this overhead entirely.
