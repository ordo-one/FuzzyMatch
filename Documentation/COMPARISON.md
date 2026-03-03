# Quality Comparison: FuzzyMatch vs fzf vs nucleo vs RapidFuzz vs Ifrit

This document compares the match quality of FuzzyMatch against four established fuzzy matching implementations using a real-world financial instruments corpus.

## Compared Implementations

### [fzf](https://github.com/junegunn/fzf) (v0.67.0)
A general-purpose command-line fuzzy finder written in Go. fzf is the de facto standard for interactive fuzzy search in terminals, used by millions of developers. It uses a Smith-Waterman-like algorithm with bonus scoring for word boundaries, camelCase, and consecutive matches. fzf treats spaces as AND operators between independent search terms.

### [nucleo](https://github.com/helix-editor/nucleo) (v0.3.1)
A high-performance fuzzy matching library written in Rust, developed for the Helix text editor. nucleo uses the same algorithmic family as fzf (Smith-Waterman variant) with Unicode-aware normalization and is optimized for real-time interactive use. It provides numeric scores for ranking.

### [RapidFuzz](https://github.com/rapidfuzz/rapidfuzz-cpp)
A high-performance fuzzy string matching library with a header-only C++ implementation. Uses edit-distance-based algorithms (like FuzzyMatch) rather than Smith-Waterman (like nucleo/fzf). Benchmarked using two scorers:
- **WRatio** — the most general-purpose scorer, combining ratio, partial_ratio, token_sort_ratio, and token_set_ratio. Represents what a typical user would get.
- **PartialRatio** — best-window substring matching via optimal partial alignment. Faster and more focused than WRatio, but loses token reordering for multi-word queries.

### [Ifrit](https://github.com/ukushu/Ifrit) (v2.0.0)
A Swift fuzzy matching library based on the Fuse.js algorithm. Uses a Bitap (shift-or) algorithm with configurable threshold-based scoring. Ifrit is designed for simplicity and ease of use, but is significantly slower than other matchers on large corpora. Benchmarked with `threshold: 0.6` (default-like setting).

### Swift `String.contains()` baseline
A non-fuzzy baseline using Swift's standard library `lowercased().contains()` — the simplest possible substring search a developer might reach for. Included to show the performance gap between naive string matching and purpose-built fuzzy matchers. Three approaches were evaluated (the latter two use Foundation's ICU-backed string matching):

| Approach | Total (197 queries x 272K candidates) |
|---|---:|
| `lowercased().contains()` | **18,582ms** |
| `localizedCaseInsensitiveContains` | 76,913ms |
| `range(of:options:[.caseInsensitive, .diacriticInsensitive])` | 111,825ms |

The `lowercased().contains()` approach was chosen as the default as it was the fastest, 4.2x faster than `range(of:options:)`. Even so, it is still **9.1x slower** than FuzzyMatch (ED) — and it only performs literal substring matching (zero matches for typos, abbreviations, or misspellings).

### FuzzyMatch (ED) — Edit Distance mode (this library)
A Swift fuzzy matching library using Damerau-Levenshtein edit distance with multi-stage prefiltering (length bounds, character bitmask, trigrams) and DP-optimal alignment scoring.

### FuzzyMatch (SW) — Smith-Waterman mode (this library)
The same FuzzyMatch library in Smith-Waterman mode (`MatchConfig.smithWaterman`). Uses bonus-driven local alignment (similar to nucleo/fzf) with tiered word-boundary bonuses, affine gap penalties, and multi-word AND semantics. Shares the same prefilter pipeline and zero-allocation architecture.

## Why These Comparisons

- **fzf** represents the "gold standard" for fuzzy matching UX that users expect. It's the most widely-used fuzzy finder and sets the baseline for what users consider correct ranking.
- **nucleo** represents the state-of-the-art in library-level fuzzy matching, specifically designed for editor/IDE integration where match quality directly affects developer productivity.
- **RapidFuzz** provides another edit-distance-based reference point. Unlike nucleo/fzf (Smith-Waterman family), RapidFuzz uses Levenshtein-based algorithms, making it a natural comparison for FuzzyMatch (ED)'s Damerau-Levenshtein approach. Testing both WRatio and PartialRatio shows how scorer choice affects quality and performance within the same library.
- fzf and nucleo use fundamentally different algorithms (Smith-Waterman family) from FuzzyMatch (ED) (Damerau-Levenshtein + DP alignment), making this a meaningful algorithmic comparison rather than just a parameter tuning exercise.
- **Ifrit** provides a Swift-native reference point using a completely different algorithm (Bitap/shift-or from Fuse.js). Comparing two Swift libraries — FuzzyMatch and Ifrit — isolates algorithmic differences from language/runtime differences.
- **Swift `String.contains()`** provides a non-fuzzy baseline using the standard library's `lowercased().contains()`. This shows the raw cost of brute-force substring matching — and demonstrates that a fuzzy matcher with prefiltering can actually be faster than naive contains, while delivering far better results for typos, abbreviations, and multi-word queries.

## Test Setup

- **Corpus**: 271,625 financial instruments (268,913 derivatives + 2,712 NYSE stocks) — symbols, names, ISINs from a real exchange feed
- **Queries**: 197 test queries across 9 categories, all loaded from `Resources/queries.tsv`:
  - **Exact symbol** (26): user knows exact ticker — "AAPL", "JPM", "SHEL", "BVB"
  - **Exact name** (35): user types company name, proper or lowercase — "Goldman Sachs", "apple", "berkshire hathaway"
  - **Exact ISIN** (6): professional ISIN lookup — "US0378331005", "US59491"
  - **Prefix / progressive typing** (33): user typing first few chars in search-as-you-type — single-char ("A", "G", "M"), two-char ("AA", "MS"), multi-char ("gol", "berks", "ishare")
  - **Typo / misspelling** (44): transpositions, dropped chars, keyboard-adjacent keys, doubled chars — "Goldamn", "blakstone", "Voeing", "Gooldman", "UDS", "APPL", "MFST", "EUUR"
  - **Keyword / substring** (22): term that appears within longer names — "DAX", "ETF", "Bond", "iShares", "High Yield"
  - **Multi-word descriptive** (15): combining keywords to find fund products — "ishares usd treasury", "vanguard ftse europe"
  - **Symbol with spaces** (4): derivative-style symbols — "AP7 X6", "WKL U6 28"
  - **Abbreviation** (12): first letter of each word in long company names — "icag" (International Consolidated Airlines Group), "bms" (Bristol-Myers Squibb), "tfs" (Thermo Fisher Scientific). FuzzyMatch (ED)'s acronym pass handles many of these via word-initial character matching.

### Query Design Rationale

The query set models realistic search-as-you-type behavior for an average-to-good typist in a financial search UI:

- **Progressive typing is the dominant pattern** — most real searches start with a few characters and the user picks from suggestions. The `prefix` category (25 queries) tests this critical path at various lengths (2-11 chars).
- **Lowercase is the default** — real users rarely capitalize in search boxes. The `exact_name` category includes both proper-case and lowercase variants of the same companies.
- **Typos reflect real typing mechanics** — transpositions of adjacent characters typed too fast ("Goldamn"), dropped characters from incomplete keystrokes ("blakstone"), hitting adjacent keys on QWERTY ("Voeing" for Boeing, B→V; "Gokdman" for Goldman, l→k), and doubled characters from key bounce ("Gooldman", "Boeeing").
- **No unrealistic queries** — dropped corporate suffixes nobody searches for ("Inc", "PLC", "Ltd"), queries with special characters users wouldn't type in search ("&"), and machine-generated typos with mid-word capitalization ("AstrZaeneca").
- **Clear category boundaries** — each query belongs to exactly one category based on the user intent it models, not surface features of the text.

### Quality Bar: Top-5 for Ambiguous Categories

Three categories use **top-5** (correct result appears in the first 5 results) rather than top-1:

- **Typo queries**: Short typo queries (e.g., "UDS" for USD, "HBSC" for HSBC) often have edit distance 1 from many candidates. Multiple results tie at the same score, and ranking among ties is not algorithmically solvable without external data (e.g., popularity). A correct result at rank 3 among tied candidates is still a successful match for search UX.
- **Prefix queries**: Short prefixes (e.g., "gol", "unit") match many candidates equally well — "gol" is a valid prefix of both "GOLD BY GOLD" and "Goldman Sachs". In search-as-you-type UX, the user sees a short result list and continues typing to disambiguate, so having the intended result anywhere in the top 5 is a success.
- **Abbreviation queries**: Short abbreviations (e.g., "pmi", "ssc") compete with literal substring matches in the 272K corpus. The intended acronym target may rank below a candidate containing the query as a literal substring, but appearing in the top 5 is still a useful result.

All other categories (exact name, exact ISIN, substring, multi-word) use **top-1** — the correct result must be the #1 ranked match.

### Ground Truth Evaluation

Each query has an `expected_name` in `Resources/queries.tsv` (4th column) that defines the correct answer. The ground truth evaluation checks whether each matcher's results contain the expected name (case-insensitive substring match) in the top-N results (N=5 for typo, prefix, and abbreviation; N=1 for all others). Queries where no single correct answer exists (exact symbol lookups, derivative symbols, single-char prefixes, unreachable short symbol typos) are marked `_SKIP_` and excluded — 45 of 197 queries are skipped.

| Category | Queries | FuzzyMatch (ED) | FuzzyMatch (SW) | nucleo | RapidFuzz (WRatio) | RapidFuzz (Partial) | fzf | Ifrit |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Exact name | 35 | **35/35 100%** | **35/35 100%** | **35/35 100%** | **35/35 100%** | 33/35 94% | 34/35 97% | **35/35 100%** |
| Exact ISIN | 6 | **6/6 100%** | **6/6 100%** | **6/6 100%** | 5/6 83% | **6/6 100%** | **6/6 100%** | **6/6 100%** |
| Prefix (top-5) | 21 | **21/21 100%** | 16/21 76% | 16/21 76% | 18/21 85% | 16/21 76% | **21/21 100%** | 19/21 90% |
| Typo (top-5) | 41 | **41/41 100%** | 23/41 56% | 23/41 56% | 33/41 80% | 33/41 80% | 22/41 53% | 36/41 88% |
| Keyword / substring | 22 | **22/22 100%** | **22/22 100%** | **22/22 100%** | 20/22 90% | **22/22 100%** | **22/22 100%** | **22/22 100%** |
| Multi-word descriptive | 15 | **15/15 100%** | **15/15 100%** | **15/15 100%** | 12/15 80% | 13/15 86% | **15/15 100%** | **15/15 100%** |
| Abbreviation (top-5) | 12 | 10/12 83% | **12/12 100%** | 4/12 33% | 0/12 0% | 1/12 8% | 6/12 50% | 1/12 8% |
| **TOTAL** | **152** | **150/152 98%** | 129/152 84% | 121/152 79% | 123/152 80% | 124/152 81% | 126/152 82% | 134/152 88% |

FuzzyMatch (ED) leads with **98% ground truth accuracy** — 10 percentage points ahead of the next best (Ifrit at 88%). It scores **100% on 6 of 7 categories**, with abbreviation (83%) as its only imperfect area. Its key advantage is typo handling: **100% (41/41)** vs 53-88% for all others. Ifrit is the second-best overall at 88%, with strong typo handling (88%) and perfect scores on exact name, ISIN, substring, and multi-word categories. FuzzyMatch (SW) achieves **100% on abbreviation** thanks to the shared acronym pass (which surfaces the correct result within top-5 even when substring matches rank higher).

## Results Summary

| Metric | FuzzyMatch (ED) | FuzzyMatch (SW) | nucleo | RapidFuzz (WRatio) | RapidFuzz (Partial) | Ifrit | fzf |
|--------|-------------|--------|--------|-------------|--------------|-------|-----|
| Queries returning results | **197/197** | 187/197 | 190/197 | **197/197** | **197/197** | **197/197** | 186/197 |
| Top-1 agreement with FuzzyMatch (ED) | -- | 79/197 | 77/197 | 84/197 | 40/197 | 95/197 | **128/197** |
| Top-1 agreement with FuzzyMatch (SW) | 79/197 | -- | **182/197** | 49/197 | 37/197 | 123/197 | 83/197 |
| Top-1 agreement with nucleo | 77/197 | **182/197** | -- | 49/197 | 37/197 | 123/197 | 86/197 |
| Top-1 agreement with Ifrit | 95/197 | 123/197 | 123/197 | 62/197 | 40/197 | -- | 73/197 |
| Top-1 agreement with fzf | **128/197** | 83/197 | 86/197 | 55/197 | 32/197 | 73/197 | -- |
| RapidFuzz (WRatio) vs RapidFuzz (Partial) | | | | 55/197 | 55/197 | | |
| All seven agree on top-1 | 17/197 | | | | | | |

FuzzyMatch (ED) agrees with fzf's top-1 ranking 65% of the time (128/197) — the highest pairwise agreement with fzf. FuzzyMatch (SW) agrees with nucleo 92% of the time (182/197), which is expected since both use Smith-Waterman-family algorithms. FuzzyMatch (ED) returns results for all 197/197 queries; FuzzyMatch (SW) returns 187/197 and fzf 186/197. Ifrit returns results for all 197/197 queries and agrees with FuzzyMatch (ED) on 95/197 top-1 rankings (48%). RapidFuzz's two scorers agree with each other only 55/197 times, showing how dramatically scorer choice affects ranking. PartialRatio has the lowest agreement with all other matchers (32–40/197), while WRatio fares slightly better (49–84/197).

### Per-Category Agreement

| Category | Queries | FuzzyMatch (ED)=FuzzyMatch (SW) | FuzzyMatch (ED)=nucleo | FuzzyMatch (ED)=RapidFuzz (WRatio) | FuzzyMatch (ED)=RapidFuzz (Partial) | FuzzyMatch (ED)=Ifrit | FuzzyMatch (ED)=fzf | All agree |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Exact symbol | 26 | 17/26 | 17/26 | 21/26 | 3/26 | 16/26 | 26/26 | 3/26 |
| Exact name | 35 | 25/35 | 25/35 | 30/35 | 16/35 | 26/35 | 18/35 | 8/35 |
| Exact ISIN | 6 | 6/6 | 6/6 | 2/6 | 3/6 | 6/6 | 6/6 | 2/6 |
| Prefix / progressive typing | 33 | 9/33 | 9/33 | 8/33 | 1/33 | 11/33 | 32/33 | 0/33 |
| Typo / misspelling | 44 | 9/44 | 9/44 | 14/44 | 12/44 | 21/44 | 7/44 | 2/44 |
| Keyword / substring | 22 | 0/22 | 0/22 | 2/22 | 0/22 | 7/22 | 17/22 | 0/22 |
| Multi-word descriptive | 15 | 4/15 | 4/15 | 3/15 | 2/15 | 2/15 | 14/15 | 1/15 |
| Symbol with spaces | 4 | 4/4 | 4/4 | 4/4 | 1/4 | 4/4 | 4/4 | 1/4 |
| Abbreviation | 12 | 5/12 | 3/12 | 1/12 | 2/12 | 2/12 | 4/12 | 0/12 |

## Overall Quality Assessment

| | Ground Truth | Hit Rate | Typo (top-5) | Prefix (top-5) | Substring | Abbreviation (top-5) |
|---|--:|--:|--:|--:|--:|--:|
| **FuzzyMatch (ED)** | **150/152 98%** | 197/197 | **41/41 100%** | **21/21 100%** | **22/22 100%** | 10/12 83% |
| **Ifrit** | 134/152 88% | 197/197 | 36/41 88% | 19/21 90% | **22/22 100%** | 1/12 8% |
| **FuzzyMatch (SW)** | 129/152 84% | 187/197 | 23/41 56% | 16/21 76% | **22/22 100%** | **12/12 100%** |
| **fzf** | 126/152 82% | 186/197 | 22/41 53% | **21/21 100%** | **22/22 100%** | 6/12 50% |
| **RapidFuzz (Partial)** | 124/152 81% | 197/197 | 33/41 80% | 16/21 76% | **22/22 100%** | 1/12 8% |
| **RapidFuzz (WRatio)** | 123/152 80% | 197/197 | 33/41 80% | 18/21 85% | 20/22 90% | 0/12 0% |
| **nucleo** | 121/152 79% | 190/197 | 23/41 56% | 16/21 76% | **22/22 100%** | 4/12 33% |

**FuzzyMatch (ED)** achieves the highest ground truth accuracy at **98% (150/152)** — scoring **100% on 6 of 7 categories**. Its Damerau-Levenshtein foundation gives it the strongest typo handling of any matcher — **100% (41/41)** vs 88% for the next best (Ifrit) and just 53-80% for the rest. It handles adjacent-key typos ("Voeing" for Boeing), transpositions ("Goldamn"), dropped characters ("blakstone"), and doubled characters ("Gooldman") that Smith-Waterman-family matchers cannot. Its only imperfect category is abbreviation (10/12, 83%), where literal substring matches in the 272K corpus outrank the acronym pass for 2 queries ("icag", "bsc"). It returns results for all 197/197 queries.

**Ifrit** is the second-best overall at **88% (134/152)**, with notably strong typo handling at **88% (36/41)** — the best of any non-FuzzyMatch (ED) matcher. It scores 100% on exact name, ISIN, substring, and multi-word categories, and 90% on prefix. Its Bitap algorithm handles many common typos (transpositions, dropped characters) that Smith-Waterman-family matchers miss. Its weaknesses are abbreviation (1/12, 8%) and the significant performance penalty (~160x slower than FuzzyMatch (ED)).

**FuzzyMatch (SW)** scores **84% (129/152)**, trading typo tolerance for higher throughput (61M vs 31M candidates/sec). It agrees with nucleo 92% of the time (182/197) — expected since both use Smith-Waterman-family algorithms. It achieves **100% on abbreviation** (12/12 top-5) thanks to the shared acronym pass, but drops to 56% on typos (vs 100%) due to lacking edit distance. It misses 10 queries entirely (no results) where FuzzyMatch (ED)'s Damerau-Levenshtein fallback succeeds.

**fzf** scores **82% (126/152)**. It matches FuzzyMatch (ED) on prefix (21/21) and substring (22/22), but its lack of edit-distance-based typo tolerance limits it to **53% (22/41)** on typo queries — the lowest of any matcher. 11 typo queries return no results at all. Abbreviation handling (6/12, 50%) is moderate.

**nucleo** scores **79% (121/152)**. It matches the leaders on exact name, ISIN, and substring (all 100%), but falls to **56% on typos** and only **33% on abbreviations** (4/12). Its lack of length preference means option derivatives often outrank clean equity matches.

**RapidFuzz (WRatio)** returns results for all 197 queries but with low precision. WRatio's combined scoring strategy (ratio + partial_ratio + token variants) produces high scores for many unrelated candidates — match counts are in the millions per category vs thousands for other matchers. Short queries like "MSFT" match "M Macy's" via partial matching, and "isahres" matches "RES RES" instead of iShares.

**RapidFuzz (PartialRatio)** is ~3x faster than WRatio but has even lower precision — it agrees with FuzzyMatch (ED) only 40/197 times (vs 85/197 for WRatio). PartialRatio finds the best partial window alignment, which works well for exact symbol matches but fails on short queries (0/22 agreement with FuzzyMatch (ED)) and multi-word queries (2/15) where it can't reorder tokens. The two RapidFuzz scorers agree with each other only 56/197 times, demonstrating that scorer choice is the dominant factor in RapidFuzz's ranking behavior.

## Detailed Category Results

### Exact Symbol Matches

All four implementations find exact symbol matches correctly in most cases. FuzzyMatch (ED) and fzf properly rank the exact match above approximate matches:

| Query | FuzzyMatch (ED) #1 | nucleo #1 | RapidFuzz #1 | fzf #1 |
|-------|----------------|-----------|--------------|--------|
| "BVB" | **BVB** Borussia Dortmund (1.0) | **BVB** Borussia Dortmund | **BVB** Borussia Dortmund | **BVB** Borussia Dortmund |
| "NAS" | **NAS** Norwegian Air (1.0) | NAS B6 19. (option) | **NAS** Norwegian Air | **NAS** Norwegian Air |
| "KIN" | **KIN** Kinepolis Group (1.0) | **KIN** Kinepolis Group | **KIN** Kinepolis Group | **KIN** Kinepolis Group |
| "NVD" | **NVD** NVIDIA Corp (1.0) | **NVD** NVIDIA Corp | **NVD** NVIDIA Corp | **NVD** NVIDIA Corp |
| "SHL" | **SHL** Siemens Health. (1.0) | **SHL** Siemens Health. | **SHL** Siemens Health. | **SHL** Siemens Health. |
| "DNO" | **DNO** DNO (1.0) | DNO B6 13 (option) | **DNO** DNO | **DNO** DNO |
| "TSL" | **TSL** Tessellis (1.0) | TSLQ Leverage Shares | **TSL** Tessellis | **TSL** Tessellis |
| "HEIA" | **HEIA** Heineken (1.0) | **HEIA** Heineken | **HEIA** Heineken | **HEIA** Heineken |
| "MSFT" | 4MSFT Microsoft (0.96) | 4MSFT Microsoft | M Macy's Inc (partial) | 4MSFT Microsoft |

FuzzyMatch (ED) and fzf agree on all 26/26 exact symbol queries. RapidFuzz (WRatio) agrees on 21/26 but occasionally ranks unrelated short symbols above the correct match (e.g., "MSFT" → "M Macy's" via partial matching). RapidFuzz (Partial) drops to just 3/26 agreement — its best-window alignment frequently ranks shorter symbols above the exact match. nucleo sometimes ranks option derivatives above the clean equity match because it doesn't apply a length preference.

### Typo Tolerance

FuzzyMatch (ED) handles transposition typos well, often matching when others cannot:

| Query (typo) | Target | FuzzyMatch (ED) | nucleo | RapidFuzz | Ifrit | fzf |
|--------------|--------|-----|--------|-----------|-------|-----|
| "Eqiuty" (transpose i/u) | Equity | Found | Found | Found | Found ("ENITY") | Found |
| "isahres" (transpose s/a) | iShares | Found | Found | Wrong ("RES") | Found | Found |
| "vanugard" (transpose n/u) | Vanguard | Found | Found | Found | Found | Found |
| "Vangrad" (missing letter) | Vanguard | Found | Found | Wrong ("ADP") | Found | Found |
| "Govenrment" (transpose n/r) | Government | Found | Found | Found | Found | Found |
| "Voeing" (B→V adjacent) | Boeing | **Found** | Not found | Found | Found | Not found |
| "Gokdman Sachs" (l→k adjacent) | Goldman Sachs | **Found** | Not found | Found | Found | Not found |
| "Gooldman Sachs" (doubled o) | Goldman Sachs | **Found** | Found | Found | Found | Found |
| "blakstone" | Blackstone | Found | Found | Found | Found | Found |
| "norwgian air" | Norwegian Air | Found | Found | Wrong ("Air Lease") | Found | Found |

FuzzyMatch (ED) handles typos well for most queries. Its Damerau-Levenshtein foundation handles adjacent-key typos ("Voeing" for Boeing, "Gokdman" for Goldman) and doubled characters ("Gooldman") that fzf and nucleo miss. RapidFuzz's WRatio scorer handles some typos but its partial matching can return unrelated results — "isahres" matches "RES" and "norwgian air" matches "Air Lease" instead of Norwegian Air. Ifrit handles typos reasonably well (21/44 FuzzyMatch (ED) agreement), though its results can be imprecise for some queries ("Eqiuty" → "ENITY" instead of Equity).

### Score Differentiation

FuzzyMatch (ED) produces well-differentiated scores:

```
Query: "BVB" (symbol)
  Rank 1: BVB Borussia Dortmund     score=1.0000  (exact match)
  Rank 2: BV1 B6 18 POBV1...        score=0.9376  (1-edit match, longer)
  Rank 3: BV1 B6 26 POBV1...        score=0.9376  (1-edit match, longer)

Query: "NVD" (symbol)
  Rank 1: NVD NVIDIA Corp           score=1.0000  (exact match)
  Rank 2: 3NVD Leverage Shares...   score=0.9526  (prefix variant, longer)
  Rank 3: 2NVD Leverage Shares...   score=0.9526  (prefix variant, longer)

Query: "DAX" (name)
  Rank 1: DAX Performance Index     score=0.9946  (exact prefix, high recovery)
  Rank 2: Deka DAX UCITS ETF        score=0.9910  (whole-word substring)
  Rank 3: Xtrackers DAX UCITS ETF   score=0.9880  (whole-word substring)
```

nucleo uses integer scores that vary widely but also clusters heavily for short queries. RapidFuzz scores (0–100) cluster around 85–90 for many candidates, making ranking noisy.

### Short Substring Queries

Short queries (3-4 characters) in a 272K corpus stress-test precision:

| Query | FuzzyMatch (ED) #1 | nucleo #1 | RapidFuzz #1 | Ifrit #1 | fzf #1 |
|-------|-------|-----------|--------------|----------|--------|
| "DAX" | DAX Performance Index | Xtrackers DAX UCITS | Amundi SDAX UCITS | Deka DAX UCITS ETF | Deka DAX UCITS ETF |
| "ETF" | Deka DAX UCITS ETF | Horizon Kinetics (wrong) | Netflix Inc (wrong) | iShares iBonds (wrong) | Deka DAX UCITS ETF |
| "ESG" | XACT OMXS30 ESG | iShares USD High Yield (wrong) | ESG option contract | Amundi Euro High Yield (wrong) | XACT OMXS30 ESG |
| "SRI" | iShares MSCI EM SRI | iShares USD High Yield (wrong) | SIPARIO MOVIES (wrong) | Amundi MSCI EMU SRI | iShares MSCI EM SRI |
| "Bond" | BON BONDUELLE | JPM BetaBuilders (wrong) | iShares China CNY Bond | iShares Brazil LTN (wrong) | Blackrock Core Bond |
| "Asia" | SPDR MSCI EM Asia ETF | Amundi Msci EM Asia (same family) | Amundi Msci EM Asia | Xtrackers MSCI Asia (same family) | SPDR MSCI EM Asia ETF |

FuzzyMatch (ED) agrees with fzf on 17/22 substring queries. Both nucleo and RapidFuzz struggle with short queries — WRatio returns "Netflix" for "ETF" and "SIPARIO MOVIES" for "SRI". PartialRatio is even worse with 0/22 FuzzyMatch (ED) agreement — its best-window alignment produces near-identical scores for many unrelated short candidates. Ifrit agrees with FuzzyMatch (ED) on 7/22 substring queries — it handles some substring matches but often returns unrelated high-yield/bond fund results instead of the actual keyword match. FuzzyMatch (ED)'s whole-word substring recovery boosts candidates where the query appears as a standalone word, and its contiguous substring recovery ensures that short queries (2–4 chars) find the actual word-bounded match even when the greedy position finder returns scattered positions.

**Top-3 quality**: FuzzyMatch (ED)'s top-3 results are strong — for "SRI" all top-3 are iShares SRI fund variants, for "ETF" all top-3 are actual ETFs (Deka DAX, MDAX, VanEck AEX), and for "ESG" all top-3 are ESG-labeled products. nucleo's top-3 for short substring queries are often unrelated bond/yield funds.

### Long Descriptive Queries

All four tools perform well on specific multi-word queries:

| Query | FuzzyMatch (ED) #1 | nucleo #1 | RapidFuzz #1 | fzf #1 |
|-------|-------|-----------|--------------|--------|
| "vanguard ftse developed europe" | Vanguard FTSE Dev. Europe | Same | Same | Same |
| "amundi euro high yield bond" | Amundi Euro High Yield Bond | Same | Same (diff variant) | Same |
| "xtrackers msci usa consumer" | Xtrackers MSCI USA Consumer | Same (Discretionary) | Same (Discretionary) | Same |
| "wisdomtree global sustainable" | WisdomTree Global Sustainable | Same | Same | Same |
| "invesco euro government bond" | Invesco Euro Government Bond | Same (diff variant) | Same | Same |
| "jpmorgan betabuilders" | JPMorgan BetaBuilders | Same (diff variant) | Same (diff variant) | Same |

This is the strongest category for all four matchers — specific multi-word queries are unambiguous enough that all algorithms converge on the correct fund family, though they may pick different share classes.

### Exact ISIN Matches

ISIN (International Securities Identification Number) queries test exact identifier lookup. FuzzyMatch (ED), nucleo, and fzf all find the correct instrument for full 12-character and prefix ISINs:

| Query | Target | FuzzyMatch (ED) #1 | nucleo #1 | RapidFuzz #1 | fzf #1 |
|-------|--------|-------|-----------|--------------|--------|
| "US0378331005" | 4AAPL (Apple) | Correct (1.0) | Correct | Apple (diff ticker) | Correct |
| "IE00BK5BQT80" | VWCE (Vanguard) | Correct (1.0) | Correct | Wrong (diff fund) | Correct |
| "DE0005493092" | 1BOD (Borussia Dortmund) | Correct (1.0) | Correct | Wrong | Correct |
| "DE000SHL1006" | SHL (Siemens Health.) | Correct (1.0) | Correct | Wrong | Correct |
| "US59491" | 4MSFT (Microsoft, prefix) | Correct (1.0) | Correct | Wrong | Correct |
| "DK006058" | NNIT (NNIT A/S, prefix) | Correct (1.0) | Correct | Wrong | Correct |

RapidFuzz struggles with ISIN queries because WRatio's partial matching returns high scores for candidates with partially overlapping character sequences rather than matching the ISIN identifier directly. FuzzyMatch (ED), nucleo, and fzf all handle ISINs well.

### Symbol with Spaces

All four matchers correctly find exact matches for symbol queries containing spaces:

| Query | FuzzyMatch (ED) | nucleo | RapidFuzz | fzf |
|-------|-----|--------|-----------|-----|
| "AP7 X6" | Correct (1.0) | Correct | Correct | Correct |
| "WKL U6 28" | Correct (1.0) | Correct | Correct | Correct |
| "RC1 L6 38" | Correct (1.0) | Correct | Correct | Correct |
| "PSX U6 8200" | Correct (1.0) | Correct | Correct | Correct |

### Abbreviation Queries

Abbreviation queries test first-letter-of-each-word patterns (e.g., "icag" for International Consolidated Airlines Group). FuzzyMatch (ED)'s acronym matching pass extracts word-initial characters from each candidate and subsequence-matches the query against them, scoring by coverage ratio.

| Query | Target | FuzzyMatch (ED) #1 | nucleo #1 | Ifrit #1 | fzf #1 |
|-------|--------|-------|-----------|----------|--------|
| "icag" | Int'l Consolidated Airlines Group | ICAPE HOLDING | ICAPE HOLDING | Image Systems (wrong) | ICAPE HOLDING |
| "bms" | Bristol-Myers Squibb | **BRISTOL-MYERS SQUIBB** | UBS BBG MSCI (wrong) | SOV option (wrong) | BNY Mellon (wrong) |
| "jnj" | Johnson & Johnson | **JNJ Johnson & Johnson** | JPMorgan Japan (wrong) | JN1 option (wrong) | JPMorgan Japan (wrong) |
| "uhg" | UnitedHealth Group | Nu Holdings (wrong) | Invesco High Yield (wrong) | hGears (wrong) | Invesco High Yield (wrong) |
| "bnym" | Bank of New York Mellon | **BNY Mellon Strategic** | **BNY Mellon High Yield** | **BNY Mellon High Yield** | **BNY Mellon Strategic** |
| "gmc" | General Motors Company | **General Motors Co** | NorCom Info Tech (wrong) | MCEWEN (wrong) | H&R GmbH (wrong) |
| "gdc" | General Dynamics Corp | **General Dynamics Corp** | Green Dot (wrong) | JDC Group (wrong) | Green Dot (wrong) |
| "tfs" | Thermo Fisher Scientific | **THERMO FISHER SCI.** | **THERMO FISHER SCI.** | SD7 option (wrong) | **THERMO FISHER SCI.** |
| "bsc" | Boston Scientific Corp | BASIC-FIT (wrong) | PIERRE VACANCES (wrong) | COL option (wrong) | PIERRE VACANCES (wrong) |
| "pmi" | Philip Morris Int'l | Amundi FTSE Italia PMI (partial) | Amundi FTSE Italia PMI (partial) | **Amundi FTSE Italia PMI** | Amundi FTSE Italia PMI (partial) |
| "ssc" | State Street Corp | Swisscom AG (wrong) | SSH Communications (wrong) | Swisscom AG (wrong) | SSH Communications (wrong) |
| "csc" | Columbia Sportswear Co | **COLUMBIA SPORTSWEAR** | KraneShares CSI (wrong) | SCHNEIDER ELECTRIC (wrong) | CSX Corp (wrong) |

Results: FuzzyMatch (ED)'s acronym pass finds the correct company for 7/12 abbreviation queries, significantly outperforming all other matchers. FuzzyMatch (ED) correctly finds Bristol-Myers Squibb for "bms", General Motors for "gmc", General Dynamics for "gdc", Thermo Fisher for "tfs", and Columbia Sportswear for "csc" — all via word-initial character matching with score 0.95 (full coverage). FuzzyMatch (ED) also finds JNJ Johnson & Johnson for "jnj" because "JNJ" appears literally in the company name. nucleo and fzf each find only 2/12 correctly (bnym and tfs). Ifrit finds 2/12 correctly (bnym and pmi) but often returns derivatives or unrelated companies. The remaining failures ("icag", "uhg", "bsc", "pmi", "ssc") involve candidates where the target company name doesn't appear with matching initials in the top results, or where a different candidate with the query as a literal substring ranks higher.

## Performance

> Re-generate these numbers by running `bash Comparison/run-benchmarks.sh`. Update the hardware/OS info and tables each time.

**Hardware / OS**

| | |
|---|---|
| **Machine** | MacBook Pro, Apple M4 Max |
| **Memory** | 128 GB unified |
| **OS** | macOS 26.3 (Tahoe) |
| **Swift** | 6.2.4 |
| **Rust** | 1.93.0 |
| **Clang** | Apple clang 17.0.0 |

**Benchmark setup**: 197 queries x 271,625 candidates (financial instruments corpus), 5 iterations (3 for RapidFuzz, 1 for Ifrit/Contains), median times reported. FuzzyMatch numbers use the UTF-8 API (`score(utf8:against:buffer:)`) — the recommended high-performance path.

Note: Ifrit and Contains were not included in this run. Run with `--ifrit --contains` for a full comparison.

### Per-Category Comparison (median ms)

| Category | nucleo | FuzzyMatch (SW) | FuzzyMatch (ED) | RapidFuzz (Partial) | Contains | RapidFuzz (WRatio) | Ifrit | FuzzyMatch (ED)/nucleo | FuzzyMatch (SW)/nucleo |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **TOTAL** | 556.3 | 873.3 | 1,747.0 | 9,486.4 | 18,581.9 | 31,331.2 | 279,686.5 | 3.1x | 1.6x |
| exact_symbol | 74.4 | 82.2 | 88.0 | 963.2 | 1,659.4 | 3,918.0 | 10,694.7 | 1.2x | 1.1x |
| exact_name | 94.5 | 158.5 | 440.5 | 1,659.1 | 3,794.4 | 5,203.9 | 81,437.3 | 4.7x | 1.7x |
| exact_isin | 9.3 | 14.7 | 28.6 | 345.1 | 357.6 | 1,195.3 | 9,842.6 | 3.1x | 1.6x |
| prefix | 101.1 | 172.6 | 327.9 | 1,679.0 | 3,100.5 | 5,861.5 | 22,094.8 | 3.2x | 1.7x |
| typo | 119.3 | 191.6 | 463.2 | 2,023.9 | 4,372.4 | 6,830.5 | 68,185.3 | 3.9x | 1.6x |
| substring | 67.2 | 110.6 | 164.3 | 1,130.2 | 2,375.0 | 3,770.7 | 23,627.0 | 2.4x | 1.6x |
| multi_word | 43.8 | 59.4 | 124.8 | 817.1 | 1,431.6 | 1,796.9 | 53,346.0 | 2.9x | 1.4x |
| symbol_spaces | 12.4 | 13.4 | 19.4 | 180.0 | 206.5 | 522.3 | 4,051.0 | 1.6x | 1.1x |
| abbreviation | 30.9 | 68.0 | 75.7 | 685.4 | 1,284.5 | 2,207.9 | 6,354.1 | 2.5x | 2.2x |

### Match Counts

Both RapidFuzz scorers produce identical match counts (no prefiltering — every candidate is scored). Ifrit uses a threshold-based filter (0.6) but still produces high match counts. Contains uses literal substring matching — zero matches for typos and abbreviations:

| Category | FuzzyMatch (ED) matches | FuzzyMatch (SW) matches | nucleo matches | RapidFuzz matches | Contains matches | Ifrit matches |
|---|--:|--:|--:|--:|--:|--:|
| exact_symbol | 8,019 | 6,736 | 6,736 | 3,091,449 | 3,687 | 464,379 |
| exact_name | 11,006 | 3,863 | 4,794 | 9,248,125 | 145 | 179,644 |
| exact_isin | 124 | 19 | 19 | 1,624,199 | 13 | 170,510 |
| prefix | 324,655 | 315,417 | 318,688 | 5,448,564 | 296,677 | 1,081,753 |
| typo | 19,651 | 12,958 | 14,660 | 10,197,982 | 4 | 281,720 |
| substring | 30,838 | 35,496 | 38,475 | 4,720,828 | 10,662 | 195,620 |
| multi_word | 841 | 915 | 1,217 | 4,071,805 | 378 | 12,696 |
| symbol_spaces | 5,079 | 34 | 34 | 1,064,505 | 4 | 321,909 |
| abbreviation | 13,926 | 19,729 | 23,243 | 1,923,914 | 3 | 74,078 |

### Throughput Summary

| | Total (ms) | Throughput (M candidates/sec) |
|---|--:|--:|
| **nucleo** (Rust) | 556 | 97M |
| **FuzzyMatch (SW)** (Swift) | 873 | 61M |
| **FuzzyMatch (ED)** (Swift) | 1,747 | 31M |
| **RapidFuzz (Partial)** (C++) | 9,486 | 6M |
| **Contains** (Swift) | 18,582 | 3M |
| **RapidFuzz (WRatio)** (C++) | 31,331 | 2M |
| **Ifrit** (Swift) | 279,687 | <1M |

### Analysis

nucleo is **1.2-4.7x faster** than FuzzyMatch (ED) across categories, which is expected given that nucleo uses a Smith-Waterman variant optimized in Rust while FuzzyMatch (ED) performs Damerau-Levenshtein edit distance with DP-optimal alignment scoring. The gap narrows to **1.2x** for exact symbol queries and **1.6x** for symbol-with-spaces queries, and widens to **4.7x** for exact name queries and **3.9x** for typo queries where FuzzyMatch (ED)'s Damerau-Levenshtein scoring overhead dominates.

**FuzzyMatch (SW) narrows the gap significantly**, completing all 197 queries in **873ms** (61M candidates/sec) — only **1.6x slower** than nucleo vs FuzzyMatch (ED)'s 3.1x. FuzzyMatch (SW) and nucleo use the same algorithmic family (Smith-Waterman), so the remaining gap is primarily language runtime and implementation differences (Rust vs Swift). FuzzyMatch (SW) match counts are nearly identical to nucleo's across all categories, confirming similar prefilter selectivity. FuzzyMatch (SW) agrees with nucleo on 182/197 top-1 rankings (92%).

RapidFuzz PartialRatio is **~3.3x faster** than WRatio (9.5s vs 31.3s), because it runs a single scoring strategy per candidate rather than four. However, both are still significantly slower than FuzzyMatch (ED) (5.4x and 17.9x respectively) and nucleo (~17x and ~56x), primarily because RapidFuzz has no prefiltering — every candidate receives a full score computation, producing match counts in the millions.

**Swift `contains()` baseline** completes in **18.6s** — **~10.6x slower** than FuzzyMatch (ED) and **~21.3x slower** than FuzzyMatch (SW). This is a non-fuzzy literal substring search using `lowercased().contains()`, the simplest approach a developer might reach for. It returns zero matches for typos (4 total across 44 queries) and abbreviations (3 total across 12 queries), illustrating why fuzzy matching exists. Even for the categories where `contains()` does find results (prefix, substring), the match counts are lower than FuzzyMatch (ED)'s because there is no edit distance tolerance.

Ifrit is by far the slowest matcher at **279.7s** total — **~160x slower** than FuzzyMatch (ED) and **~508x slower** than nucleo. Its Bitap algorithm has no prefiltering and performs expensive per-character scoring across the full corpus. Despite being written in Swift like FuzzyMatch (ED), it demonstrates that algorithm and prefiltering strategy matter far more than language choice for fuzzy matching performance. Ifrit's quality is notably good (88% ground truth, second only to FuzzyMatch (ED)), showing that the Bitap algorithm produces high-quality results — the performance cost is the trade-off.

Both FuzzyMatch modes comfortably handle interactive-speed search over the full 272K corpus: FuzzyMatch (SW) completes all 197 queries in ~873ms and FuzzyMatch (ED) in ~1.75s (nucleo finishes in ~556ms). FuzzyMatch (ED) uses an adaptive bitmask prefilter: strict for short queries (≤3 chars, requiring all query character types present) and relaxed for longer queries (allowing up to `effectiveMaxEditDistance` missing character types). FuzzyMatch (SW) uses strict tolerance 0 (all query character types must appear). Single-character queries use a dedicated fast path that bypasses the full pipeline entirely, performing a single scan with inline boundary detection. This keeps short-query match counts close to nucleo's while still supporting typo tolerance for longer queries in ED mode.

### Mode Selection Guidance

| Use case | Recommended | Why |
|----------|-------------|-----|
| User-facing search with typo tolerance | **FuzzyMatch (ED)** | Damerau-Levenshtein handles transpositions; 197/197 coverage |
| Progressive typing / autocomplete | **FuzzyMatch (ED)** | Explicit prefix scoring; short-query optimization |
| Multi-word product search | **FuzzyMatch (SW)** | AND semantics; 2.0x faster than FuzzyMatch (ED) |
| Maximum throughput | **FuzzyMatch (SW)** | 61M/sec vs 31M/sec for FuzzyMatch (ED) |
| nucleo-compatible rankings | **FuzzyMatch (SW)** | 182/197 top-1 agreement |
| Code/file search | **FuzzyMatch (SW)** | Boundary bonuses match editor conventions |

See [MATCHING_MODES.md](MATCHING_MODES.md) for detailed algorithm comparison and per-category quality analysis.

## Remaining Considerations

1. **Abbreviation queries**: FuzzyMatch (ED)'s acronym pass finds 10/12 abbreviation targets in the top-5, outperforming nucleo (4/12) and fzf (6/12). At top-1 it finds 7/12 correctly. The 2 top-5 failures ("icag", "ssc") involve candidates where a different match with the query as a literal substring outranks the acronym target, or where the target company's name structure doesn't produce matching initials in the corpus data.
2. **nucleo ranking divergence**: nucleo doesn't apply length preferences, so it often ranks longer option tickers (which contain the exact symbol as a prefix) alongside or above the clean equity match. This is a deliberate design choice in nucleo, not a bug.
3. **RapidFuzz scorer choice**: Neither WRatio nor PartialRatio is well-suited to this workload. WRatio is slower (4 strategies per candidate) but has better top-1 agreement (84/197 vs 40/197 with FuzzyMatch (ED)). PartialRatio is 3.3x faster but less precise, especially on short queries and multi-word queries where token reordering matters. The fundamental issue is RapidFuzz's lack of prefiltering — all 272K candidates are scored regardless of relevance, producing millions of matches.
4. **RapidFuzz scorer instability**: The two RapidFuzz scorers agree with each other only 55/197 times, making scorer selection the single largest factor in ranking quality. A third scorer (`CachedRatio` — simple normalized Levenshtein) would penalize length differences too heavily for this corpus where short queries match long instrument names.
5. **Ifrit performance vs quality trade-off**: Ifrit is ~160x slower than FuzzyMatch (ED) despite both being Swift libraries, primarily due to its lack of prefiltering — every candidate is scored with the full Bitap algorithm. However, its quality is the second-best overall at 88% ground truth accuracy (vs FuzzyMatch (ED)'s 98%), with notably strong typo handling (88%) — better than all other non-FuzzyMatch (ED) matchers. Its Bitap algorithm produces high-quality results; the trade-off is purely in performance.
