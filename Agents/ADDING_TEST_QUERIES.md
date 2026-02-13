# Adding Test Queries

All benchmark and quality queries live in `Resources/queries.tsv` (4-column TSV: `query\tfield\tcategory\texpected_name`). This single file drives:
- Performance benchmarks (`Comparison/bench-fuzzymatch`, `bench-nucleo`, `bench-rapidfuzz`)
- Quality comparison (`Comparison/run-quality.py`) — including ground truth evaluation

To add a new query, append a line to `queries.tsv`:
```
Goldman Sachs	name	exact_name	Goldman Sachs
```

**Fields:**
- Column 1: `query` — the search text
- Column 2: `field` — which corpus field to search (`symbol`, `name`, or `isin`)
- Column 3: `category` — one of the 9 categories below
- Column 4: `expected_name` — ground truth expected result name (case-insensitive substring match against result names)

**Ground truth rules:**
- `expected_name` is matched as a **case-insensitive substring** against result `name` fields. This avoids brittleness from symbol prefixes (`4AAPL`) and name variations.
- **Top-N**: Top-1 for `exact_name`, `exact_isin`, `substring`, and `multi_word`. Top-5 for `typo`, `prefix`, and `abbreviation` — these categories produce many equally-valid candidates (tied edit distances, ambiguous short prefixes, literal substring matches competing with acronyms) where the correct result anywhere in the top 5 is a success for search UX.
- **`_SKIP_`**: Use for queries with no definitive expected answer — exact symbol lookups (any instrument with the matching symbol is valid), symbol-with-spaces derivatives, and single-char/short ambiguous prefix queries.
- When adding a query, **always include the expected_name column**.

Valid fields: `symbol`, `name`, `isin`

Categories (9):
- `exact_symbol` — user knows the exact ticker (AAPL, JPM, SHEL)
- `exact_name` — user types company name, proper or lowercase (Goldman Sachs, apple, berkshire hathaway)
- `exact_isin` — ISIN lookup, full or partial prefix (US0378331005, US59491)
- `prefix` — progressive typing, first few chars (gol, berks, ishare, AA)
- `typo` — misspellings: transpositions, dropped chars, adjacent keys, doubled chars (Goldamn, blakstone, Voeing, Gooldman)
- `substring` — keyword that appears within longer names (DAX, Bond, ETF, iShares, High Yield)
- `multi_word` — multi-word descriptive search for fund products (ishares usd treasury, vanguard ftse europe)
- `symbol_spaces` — derivative-style symbols with spaces (AP7 X6)
- `abbreviation` — first letter of each word in long company names (icag for International Consolidated Airlines Group, bms for Bristol-Myers Squibb)

No other files need editing — all harnesses load queries from the TSV at runtime (they ignore the 4th column).
