# Prepare Release

When asked to "prepare release", execute the following steps. **Maximize parallelism** — benchmarks and quality runs are independent of each other and of the documentation review tasks, so launch them concurrently.

1. **Clean stale results**: Remove old benchmark and quality output files from `/tmp/` to ensure fresh data. **Ask the user for confirmation before deleting.**
   ```bash
   rm -f /tmp/bench-*-latest.txt /tmp/quality-*-latest.json
   ```
2. **Run all tests**: `swift test` — all tests must pass before proceeding.
3. **Build all harnesses** (sequential, one-time — prevents concurrent build races):
   ```bash
   swift build -c release --package-path Comparison/bench-fuzzymatch
   (cd Comparison/bench-nucleo && cargo build --release)
   make -C Comparison/bench-rapidfuzz
   (cd Comparison/quality-fuzzymatch && swift build -c release)
   (cd Comparison/quality-nucleo && cargo build --release)
   make -C Comparison/quality-rapidfuzz
   ```
4. **Run benchmarks and quality in parallel with `--skip-build`**: Launch each matcher/mode as a separate background process to utilize all cores. Both scripts support per-matcher flags (`--fm-ed`, `--fm-sw`, `--nucleo`, `--rf-wratio`, `--rf-partial`, `--fzf`) and `--skip-build` to skip the build step (already done in step 3). Use `--fm` or `--rf` as shorthand to run both modes of a matcher:

   **Performance benchmarks** (5 parallel processes):
   ```bash
   bash Comparison/run-benchmarks.sh --fm-ed --skip-build
   bash Comparison/run-benchmarks.sh --fm-sw --skip-build
   bash Comparison/run-benchmarks.sh --nucleo --skip-build
   bash Comparison/run-benchmarks.sh --rf-wratio --skip-build
   bash Comparison/run-benchmarks.sh --rf-partial --skip-build
   ```

   **Quality comparison** (6 parallel processes):
   ```bash
   python3 Comparison/run-quality.py --fm-ed --skip-build
   python3 Comparison/run-quality.py --fm-sw --skip-build
   python3 Comparison/run-quality.py --nucleo --skip-build
   python3 Comparison/run-quality.py --rf-wratio --skip-build
   python3 Comparison/run-quality.py --rf-partial --skip-build
   python3 Comparison/run-quality.py --fzf --skip-build
   ```

   All 11 processes can run concurrently. Use parallel subagents (Task tool with Bash) to launch them simultaneously. While benchmarks run, proceed with documentation review (steps 7-9).

   **Output files**: After parallel runs complete, results are available in `/tmp/`:
   - Performance: `/tmp/bench-fuzzymatch-latest.txt`, `/tmp/bench-fuzzymatch-sw-latest.txt`, `/tmp/bench-nucleo-latest.txt`, `/tmp/bench-rapidfuzz-wratio-latest.txt`, `/tmp/bench-rapidfuzz-partial-latest.txt`
   - Quality: `/tmp/quality-fuzzymatch-latest.json`, `/tmp/quality-fuzzymatch-sw-latest.json`, `/tmp/quality-nucleo-latest.json`, `/tmp/quality-rapidfuzz-wratio-latest.json`, `/tmp/quality-rapidfuzz-partial-latest.json`, `/tmp/quality-fzf-latest.json`

   Read these files to collate results for COMPARISON.md — do not re-run all matchers together just to generate the comparison table.

5. **Run microbenchmarks**: `swift package --package-path Benchmarks benchmark`. Update the microbenchmark table in README.md with fresh numbers.
6. **Update COMPARISON.md**: Once all benchmark and quality runs complete, replace performance and quality tables with fresh output. Update the hardware/OS info block.
7. **Review DAMERAU_LEVENSHTEIN.md and SMITH_WATERMAN.md**: Analyze the current implementation and ensure the algorithm documentation accurately reflects the code — update any sections that are out of date (prefilter pipeline, scoring logic, data structures, complexity analysis, etc.).
8. **Review README.md**: Ensure it reflects the current state of the project — performance claims, feature list, API examples, and any other content that may have changed.
9. **Update DocC documentation**: Review and update all DocC documentation (source-level `///` comments and any `.docc` catalog files) to accurately reflect the current API, parameters, return types, and behavior. Ensure new public APIs are documented and outdated descriptions are corrected.
10. **Report**: Summarize what was updated and any discrepancies found.

Note: Do NOT include Ifrit or Contains in the benchmark or quality runs unless explicitly requested by the user. Both are extremely slow to benchmark and would dominate the runtime. Use existing reference numbers for Ifrit and Contains in COMPARISON.md and only re-run when explicitly asked. Add a note in COMPARISON.md: "Note: Ifrit and Contains were not included in this run. Run with --ifrit --contains for a full comparison."

## fuzzygrep Benchmarks

The `Examples/` directory includes `fuzzygrep`, a parallel grep-like tool. To benchmark it:

### 1. Generate test files

```bash
{ echo "color"; awk 'BEGIN{for(i=1;i<=10000000;i++) print "line " i}'; echo "colour"; } > /tmp/fuzzygrep-10M.txt
{ echo "color"; awk 'BEGIN{for(i=1;i<=100000000;i++) print "line " i}'; echo "colour"; } > /tmp/fuzzygrep-100M.txt
{ echo "color"; awk 'BEGIN{for(i=1;i<=1000000000;i++) print "line " i}'; echo "colour"; } > /tmp/fuzzygrep-1B.txt
```

The 1B file takes several minutes to generate (~14 GB). Generate 10M and 100M first, run benchmarks on those while 1B generates in the background.

### 2. Build fuzzygrep

```bash
swift build --package-path Examples -c release
```

### 3. Run benchmarks

Use query `1235321 -score 0.5` to exercise the full matching pipeline (prefilter + scoring), not just prefilter rejection:

**Edit Distance mode (default):**
```bash
time .build/release/fuzzygrep 1235321 -score 0.5 < /tmp/fuzzygrep-10M.txt > /dev/null
time .build/release/fuzzygrep 1235321 -score 0.5 < /tmp/fuzzygrep-100M.txt > /dev/null
time .build/release/fuzzygrep 1235321 -score 0.5 < /tmp/fuzzygrep-1B.txt > /dev/null
```

**Smith-Waterman mode:**
```bash
time .build/release/fuzzygrep 1235321 --sw -score 0.5 < /tmp/fuzzygrep-10M.txt > /dev/null
time .build/release/fuzzygrep 1235321 --sw -score 0.5 < /tmp/fuzzygrep-100M.txt > /dev/null
time .build/release/fuzzygrep 1235321 --sw -score 0.5 < /tmp/fuzzygrep-1B.txt > /dev/null
```

Use `bash -c 'time ...' 2>&1` for clean output when capturing results programmatically. Run each size twice to verify stability. Update the fuzzygrep table in README.md with fresh numbers.
