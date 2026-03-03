# Assembly Vision (`@_assemblyVision`)

A guide for using Swift's `@_assemblyVision` attribute to inspect compiler optimization decisions in FuzzyMatch hot paths.

## What is `@_assemblyVision`?

`@_assemblyVision` is an underscored Swift compiler attribute that emits **optimization remarks** during release builds. It annotates source lines with what the compiler actually does: inlining decisions, generic specialization, ARC retain/release calls, and which standard library operations remain as function calls vs. being optimized away.

This is the primary tool for answering: *"Is the compiler generating the code I think it is?"*

## How to Use It

### 1. Add the attribute to ONE function at a time

```swift
@_assemblyVision
@inlinable
func smithWatermanScore(...) -> Int32 {
    // ...
}
```

Annotate only one function per build to keep the output readable. If you annotate many functions at once, the output can be thousands of lines and hard to parse.

### 2. Clean build in release mode

```bash
swift package clean && swift build -c release 2> /tmp/av_output.txt
```

The remarks go to stderr. Redirect to a file for analysis.

### 3. Analyze the output

The output contains source-annotated remarks. Key remark types to look for:

#### Positive (things working well)
- **`"X" inlined into "Y" (cost = N, benefit = M)`** — Function was inlined. Higher benefit/cost ratio is better.
- **`Specialized function "X" with type ...`** — Generic function was specialized for a concrete type (no dynamic dispatch).
- **`Pure call. Always profitable to inline "X"`** — Trivial function always inlined.

#### Concerning (potential optimization issues)
- **`Not profitable to inline function "X" (cost = N, benefit = M)`** — Compiler chose NOT to inline. If this is a hot-path function, consider `@inline(__always)` or restructuring.
- **`Specialized function "Swift.Array.subscript.modify"`** — Array write with bounds check + COW uniqueness check. In tight inner loops, consider `withUnsafeMutableBufferPointer` to eliminate these.
- **`release of type 'Builtin.BridgeObject'`** — ARC release operation. Critical if inside an inner loop; fine at function entry/exit or in `ensureCapacity` paths.
- **`release of type 'any Error'`** — Error path cleanup, usually from `withUnsafeTemporaryAllocation`. Not a runtime concern unless in a tight loop.

### 4. Remove the attribute when done

`@_assemblyVision` is for investigation only. Never commit it.

## Quick Analysis Commands

```bash
# Count unique remark types (most common first)
grep "remark:" /tmp/av_output.txt | sed 's/.*remark: //' | sort | uniq -c | sort -rn

# Find ARC traffic (retain/release)
grep -E "remark:.*(retain|release)" /tmp/av_output.txt

# Find failed inlining decisions
grep "Not profitable to inline" /tmp/av_output.txt

# Find Array bounds-check overhead
grep "Array.subscript.modify" /tmp/av_output.txt

# Per-file remark summary
grep "MyFile.swift" /tmp/av_output.txt | grep "remark:" | sed 's/.*remark: //' | sort | uniq -c | sort -rn
```

## Hot Path Functions to Investigate

When doing performance work, these are the key functions to annotate (one at a time):

| Priority | Function | File | Why |
|----------|----------|------|-----|
| 1 | `smithWatermanScore()` | SmithWaterman.swift | Hottest inner loop (SW mode) |
| 2 | `substringEditDistance()` | EditDistance.swift | Hottest inner loop (ED mode) |
| 3 | `scoreSmithWatermanImpl()` | FuzzyMatcher+SmithWaterman.swift | SW orchestrator + merged lowercase+bonus pass |
| 4 | `prefixEditDistance()` | EditDistance.swift | ED prefix DP |
| 5 | `computeCharBitmaskWithASCIICheck()` | Prefilters.swift | Runs on every candidate |
| 6 | `lowercaseUTF8()` | Prefilters.swift | ED lowercasing pass |
| 7 | `scoreImpl()` | FuzzyMatcher.swift | ED orchestrator |
| 8 | `optimalAlignment()` | ScoringBonuses.swift | ED bonus alignment DP |

## Baseline Analysis (March 2026, Swift 6.2.4)

Last full analysis found the following state:

### Clean (no issues)

- **SW DP inner loop** (`smithWatermanScore`): Uses `withUnsafeMutableBufferPointer` — no bounds checks, no ARC traffic in inner loop. All Span subscript reads optimized.
- **ED DP inner loops** (`prefixEditDistance`, `substringEditDistance`): Array subscript modify calls are present but inlined with high benefit (cost=11, benefit=300+). A flat-buffer `withUnsafeMutableBufferPointer` approach was benchmarked and caused ~11% regression because the closure boundary prevented cross-function inlining of ED functions into `scoreImpl`.
- **All ARC releases** are at `ensureCapacity` boundaries or function exit — none inside inner loops.
- **All generics specialized** — no dynamic dispatch anywhere in hot paths.
- **All small helpers inlined** — `lowercaseASCII`, `min`, `rotateRows`, `isCombiningMark`, `confusableASCIIToCanonical`, etc.

### Known trade-offs

- **`computeCharBitmaskWithASCIICheck` not inlined** into callers (cost=36-40, benefit=18-20). It's a tight O(n) loop that runs on every candidate. The function call overhead is small relative to the loop body.
- **`lowercaseUTF8` not inlined** (cost=469-544). Too large, as expected. Called once per candidate that passes bitmask prefilter.
- **`latin1ToASCII` not inlined** in SW multi-byte path (cost=38, benefit=30). Only affects non-ASCII candidates.
- **`scoreAcronym` nearly at inlining threshold** (cost=295-328, benefit=293-294). Close call — monitor if the function grows.
- **SW merged lowercase+bonus pass** uses `Array.subscript.modify` for `candidateStorage.bytes[i]` and `candidateStorage.bonus[i]` writes (64 + 32 occurrences). These include bounds checks. A `withUnsafeMutableBufferPointer` wrapper could eliminate them, but would need benchmarking to ensure the closure boundary doesn't hurt inlining.

### Summary

The codebase is well-optimized at the compiler level. The main remaining overhead is Array bounds checks in the SW merged lowercase+bonus pass and ED DP rows. The ED case was already benchmarked and the current approach won. The SW merged pass is the most promising area for further investigation.
