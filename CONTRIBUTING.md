# Contributing

Contributions are welcome. Bug reports, performance improvements, and quality enhancements are particularly valued.

## Getting Started

```bash
swift build              # Debug build
swift test               # Run all tests
swift package --package-path Benchmarks benchmark  # Run benchmark suite (release build)
```

## Before Submitting a PR

1. **All tests pass** — `swift test` must be green.
2. **Benchmarks checked** — If your change touches the scoring pipeline, run `swift package --package-path Benchmarks benchmark` before and after. Include the comparison in your PR description. Do not submit performance changes that show no improvement.
3. **Lint clean** — The CI runs SwiftLint. Run it locally with `swiftlint` if you have it installed.
4. **Focused scope** — One concern per PR. Bug fix, feature, or refactor — not all three.

## Testing

Tests use the **Swift Testing** framework (`@Test` macro, `#expect()` assertions). Test files are in `Tests/FuzzyMatchTests/` and mirror the source structure:

- `EditDistanceTests.swift` — Core edit distance algorithm
- `SmithWatermanTests.swift` — Smith-Waterman alignment and scoring
- `PrefilterTests.swift` / `TrigramTests.swift` — Fast rejection
- `ScoringBonusTests.swift` / `WordBoundaryTests.swift` — Ranking (edit distance mode)
- `AcronymMatchTests.swift` — Word-initial abbreviation matching
- `HighlightTests.swift` — Highlight range extraction for UI display
- `EdgeCaseTests.swift` — Boundary conditions

Run a specific test suite:

```bash
swift test --filter EditDistanceTests
```

## Documentation

All public APIs must have DocC documentation (`///` comments). Include:
- A summary line
- Parameter descriptions
- Return value description
- A usage example for non-trivial APIs

Preview generated documentation:

```bash
swift package generate-documentation --target FuzzyMatch
```

## Code Style

- SwiftLint and SwiftFormat are configured in the repo. Follow the existing patterns.
- Don't add comments for self-evident code. Do add comments for non-obvious algorithmic choices.
- Don't add features or abstractions beyond what's needed for the current change.
- Public API additions need DocC documentation (triple-slash comments).

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/) for automated releases:

```
feat: add support for Unicode normalization
fix: correct boundary detection for digits after underscore
perf: vectorize bitmask prefilter
docs: update algorithm documentation for acronym matching
test: add edge cases for empty candidate strings
```

Breaking changes append `!`: `feat!: rename MatchConfig to ScoringConfig`

## Performance

The hot path (`score` method) is designed for zero heap allocations after buffer warmup. Changes that introduce per-call allocations need strong justification and benchmark evidence.

If your change affects scoring quality, run the comparison suite and include results:

```bash
bash Comparison/run-benchmarks.sh --fm --nucleo --rf
python3 Comparison/run-quality.py --fm --nucleo --rf --fzf
```

See [Comparison/README.md](Comparison/README.md) for full setup instructions and prerequisites.

## Questions

Open an issue for discussion before starting large changes. This saves everyone time.
