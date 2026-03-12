# Matching Modes

FuzzyMatch provides two matching algorithms with fundamentally different design philosophies. Both share the same API surface and zero-allocation hot path, but they produce different rankings and have different strengths.

For detailed algorithm internals, see [DAMERAU_LEVENSHTEIN.md](DAMERAU_LEVENSHTEIN.md) (edit distance) and [SMITH_WATERMAN.md](SMITH_WATERMAN.md) (Smith-Waterman).

## Quick Comparison

| | Edit Distance (default) | Smith-Waterman |
|---|---|---|
| **Design philosophy** | Penalty-driven (count errors) | Bonus-driven (reward good alignments) |
| **Core algorithm** | Damerau-Levenshtein | Smith-Waterman local alignment |
| **Scoring pipeline** | Multi-phase: exact, prefix, substring, subsequence, acronym | Single DP pass + acronym fallback |
| **Typo handling** | Native transposition support | No transposition operation |
| **Prefix awareness** | Explicit prefix scoring phase | No prefix concept (treats all substrings equally) |
| **Multi-word queries** | Treated monolithically | Atom splitting with AND semantics |
| **Throughput** | ~32M candidates/sec | ~66M candidates/sec |
| **Coverage (272K corpus)** | 197/197 queries | 187/197 queries |

## Usage

```swift
// Default: Edit Distance mode (recommended for most use cases)
let matcher = FuzzyMatcher()

// Smith-Waterman mode
let matcher = FuzzyMatcher(config: .smithWaterman)
```

Both modes use the same `score(_:against:buffer:)` API. The only difference is the config passed at construction time.

## Edit Distance Mode (Default)

The default mode uses **Damerau-Levenshtein edit distance** with a multi-phase scoring pipeline. It is designed for **interactive search where users type imprecisely** -- misspelled names, partial prefixes, ticker symbols, and abbreviations.

### How it works

The scoring pipeline runs five phases in order, taking the best score:

1. **Exact match** -- case-insensitive equality check (score 1.0)
2. **Prefix** -- edit distance against the start of the candidate, with a prefix weight bonus
3. **Substring** -- edit distance against any substring of the candidate
4. **Subsequence** -- gap-based alignment fallback for scattered matches
5. **Acronym** -- word-initial character matching (e.g., "bms" matches "Bristol-Myers Squibb")

Before any of these phases, three prefilters reject candidates cheaply:
- Length bounds (O(1))
- Character bitmask (O(1))
- Trigram similarity (O(n))

### Strengths

- **Typo tolerance**: Damerau-Levenshtein counts transpositions as a single edit. Queries like "Berkhsire" (for Berkshire), "UntiedHealth" (for UnitedHealth), and "Exxon Moibl" (for Exxon Mobil) all match correctly. This is the mode's biggest differentiator -- Smith-Waterman and nucleo-style matchers miss all of these.

- **Prefix awareness**: The explicit prefix phase means "AA" finds "AA Alcoa Corporation" rather than a random derivative containing "AA" as a substring. Progressive typing (A, AA, AAP, AAPL) produces intuitive results at every keystroke.

- **Short query handling**: Single-character and 2-3 character queries return the most relevant compact match, not whichever long string happens to contain the query.

- **Full coverage**: Recovers matches on 197/197 test queries, including heavily misspelled multi-word names.

### Weaknesses

- **Slower throughput**: The multi-phase pipeline with three prefilters costs ~2x more than Smith-Waterman per candidate.

- **Multi-word queries**: Treats "ishares usd treasury" as a single monolithic string, which can produce lower-confidence matches than SW's word-by-word alignment.

- **Substring ranking**: When a keyword appears inside many long fund names (e.g., "Bond" in 500+ bond funds), the ranking among them is less meaningful than SW's alignment-based scoring.

## Smith-Waterman Mode

The Smith-Waterman mode uses **bonus-driven local alignment**, similar to the algorithms used by [nucleo](https://github.com/helix-editor/nucleo) and [fzf](https://github.com/junegunn/fzf). Instead of counting errors, it awards points for each matched character and adds bonuses for desirable alignment properties.

### How it works

A single DP pass scores the best local alignment of the query within the candidate:

1. **Bitmask prefilter** -- strict tolerance 0 (all query characters must appear in the candidate)
2. **Lowercase + bonus precomputation** -- merged O(n) pass computing tiered boundary bonuses
3. **Smith-Waterman DP** -- three-state recurrence (match, gap, consecutive bonus)
4. **Score normalization** -- raw integer score mapped to 0.0-1.0
5. **Acronym fallback** -- word-initial matching competes with the SW score for short queries

For multi-word queries, each word is scored independently with AND semantics (all words must match).

### Strengths

- **Throughput**: ~66M candidates/sec -- ~2x faster than edit distance mode. The single DP pass with integer arithmetic is very cache-friendly.

- **Multi-word queries**: Atom splitting with AND semantics handles "ishares usd treasury" and "vanguard ftse europe" naturally, with each word scored independently against the candidate.

- **Long descriptive matches**: Local alignment excels at finding queries embedded within long product names. "High Yield Corporate Bond" is found within 80-character fund descriptions.

- **Alignment with nucleo/fzf**: 182/197 top-1 agreement with nucleo, making results familiar to users of editors and CLI tools that use these algorithms.

### Weaknesses

- **No transposition support**: Typos involving swapped characters ("Berkhsire", "UntiedHealth", "Exxon Moibl") produce no results at all. This is the mode's biggest limitation -- 10 queries that ED handles easily are completely missed.

- **No prefix concept**: Smith-Waterman finds the best local alignment anywhere in the string. A prefix match is no better than a mid-string match. This means short queries like "GS" or "BA" return derivative instruments (with long symbol codes containing "GS") instead of Goldman Sachs or Boeing.

- **Derivative/option bias**: Long derivative symbol strings (e.g., "BAM N6 8.6 AOBAM 2606D000000F") contain many characters, giving SW more opportunity to find high-scoring alignments. This systematically pushes plain equities below derivatives for short queries.

- **Lower coverage**: 187/197 queries return results, vs 197/197 for edit distance.

## Choosing a Mode

| Use case | Recommended mode |
|----------|-----------------|
| User-facing search box with typo tolerance | **Edit Distance** (default) |
| Progressive typing / autocomplete | **Edit Distance** |
| Ticker symbol lookup | **Edit Distance** |
| Multi-word product search ("ishares usd treasury") | **Smith-Waterman** |
| Code editor file/symbol finder | **Smith-Waterman** |
| Maximum throughput with acceptable quality | **Smith-Waterman** |
| Matching abbreviations to full names | Either (both have acronym matching) |

**When in doubt, use the default (edit distance)**. It handles the widest range of query patterns and never fails on typos. Switch to Smith-Waterman when you specifically need multi-word AND semantics or higher throughput and your users are unlikely to make transposition typos.

## Category-by-Category Quality

Tested on a 272K financial instruments corpus with 197 queries across 9 categories:

| Category | Queries | Top-1 Agreement | Better Mode |
|----------|---------|-----------------|-------------|
| Exact symbol | 26 | 17/26 | ED (avoids derivative noise) |
| Exact name | 35 | 25/35 | Slight ED edge |
| Exact ISIN | 6 | 6/6 | Tie |
| Prefix / progressive typing | 33 | 9/33 | ED (prefix awareness) |
| Typo / misspelling | 44 | 9/44 | ED (transposition handling) |
| Keyword / substring | 22 | 0/22 | Mixed (different ranking strategies) |
| Multi-word descriptive | 15 | 4/15 | Slight SW edge |
| Symbol with spaces | 4 | 4/4 | Tie |
| Abbreviation | 12 | 5/12 | Mixed (both have acronym matching) |

Overall top-1 agreement between modes: **79/197 (40%)**. They are complementary algorithms that excel in different scenarios.

## Highlighting Matched Characters

Both modes support highlighting via `highlight(_:against:)`, which returns `[Range<String.Index>]` of matched character positions for UI display. The highlight method is completely separate from the scoring hot path and uses full-matrix DP traceback variants to recover alignment positions.

### Behavior by Mode

| Aspect | Edit Distance | Smith-Waterman |
|--------|---------------|----------------|
| **Highlight pipeline** | Multi-phase: prefix → substring → subsequence → acronym → ED traceback | Single SW DP traceback + acronym fallback |
| **Typo highlighting** | Highlights substituted positions (shows where user "meant") | No typo support — query chars must exist in candidate |
| **Transposition highlighting** | Both swapped positions highlighted | N/A |
| **Multi-word queries** | Monolithic alignment | Per-atom highlighting (one SW pass per word) |
| **Acronym highlighting** | Word-initial characters highlighted | Word-initial characters highlighted |

### Usage

```swift
let matcher = FuzzyMatcher()           // ED mode
let swMatcher = FuzzyMatcher(config: .smithWaterman)

// Both modes use the same API
if let ranges = matcher.highlight("getUserById", against: "getuser") {
    // ranges covers "getUser" in "getUserById"
}

// ED mode handles typos — SW mode would return nil for this query
if let ranges = matcher.highlight("Berkshire", against: "Berkhsire") {
    // ranges covers "Berkshire" (transposition corrected)
}
```

### Consistency with Scoring

The `highlight()` method is designed to be consistent with `score()`: if `score()` returns a match, `highlight()` should also return ranges for that candidate. Both methods use the same normalization (case folding, diacritic stripping, confusable normalization) so highlight positions map correctly back to the original string.

See [COMPARISON.md](COMPARISON.md) for full per-query results and top-3 analysis.
