#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TSV_PATH="$REPO_ROOT/Resources/instruments-export.tsv"
QUERIES_PATH="$REPO_ROOT/Resources/queries.tsv"

# --- Parse flags ---
RUN_FM_ED=false
RUN_FM_SW=false
RUN_FM_ED_UTF8=false
RUN_FM_SW_UTF8=false
RUN_NUCLEO=false
RUN_RF_WR=false
RUN_RF_PR=false
RUN_IFRIT=false
RUN_CONTAINS=false
ANY_FLAG=false
SKIP_BUILD=false
ITERATIONS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fm)      RUN_FM_ED=true; RUN_FM_SW=true; ANY_FLAG=true; shift ;;
        --fm-ed)   RUN_FM_ED=true; ANY_FLAG=true; shift ;;
        --fm-sw)   RUN_FM_SW=true; ANY_FLAG=true; shift ;;
        --fm-ed-utf8) RUN_FM_ED_UTF8=true; ANY_FLAG=true; shift ;;
        --fm-sw-utf8) RUN_FM_SW_UTF8=true; ANY_FLAG=true; shift ;;
        --nucleo)  RUN_NUCLEO=true; ANY_FLAG=true; shift ;;
        --rf)      RUN_RF_WR=true; RUN_RF_PR=true; ANY_FLAG=true; shift ;;
        --rf-wratio)  RUN_RF_WR=true; ANY_FLAG=true; shift ;;
        --rf-partial) RUN_RF_PR=true; ANY_FLAG=true; shift ;;
        --ifrit)   RUN_IFRIT=true; ANY_FLAG=true; shift ;;
        --contains) RUN_CONTAINS=true; ANY_FLAG=true; shift ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--fm] [--fm-ed] [--fm-sw] [--fm-ed-utf8] [--fm-sw-utf8] [--nucleo] [--rf] [--rf-wratio] [--rf-partial] [--ifrit] [--contains] [--iterations N] [--skip-build]"
            echo "  Default (no flags): runs FM(ED), FM(SW), FM(ED,UTF-8), FM(SW,UTF-8), nucleo, RapidFuzz."
            echo "  --fm           Run FuzzyMatch (both Edit Distance and Smith-Waterman, String API)"
            echo "  --fm-ed        Run FuzzyMatch (Edit Distance, String API)"
            echo "  --fm-sw        Run FuzzyMatch (Smith-Waterman, String API)"
            echo "  --fm-ed-utf8   Run FuzzyMatch (Edit Distance, UTF-8 API)"
            echo "  --fm-sw-utf8   Run FuzzyMatch (Smith-Waterman, UTF-8 API)"
            echo "  --nucleo       Run nucleo"
            echo "  --rf           Run RapidFuzz (both WRatio and PartialRatio)"
            echo "  --rf-wratio    Run RapidFuzz WRatio only"
            echo "  --rf-partial   Run RapidFuzz PartialRatio only"
            echo "  --ifrit        Run Ifrit (very slow, defaults to 1 iteration)"
            echo "  --contains     Run String.contains() baseline (very slow, defaults to 1 iteration)"
            echo "  --iterations N Override number of timed iterations (default: 5 FM/nucleo, 3 RapidFuzz, 1 Ifrit/Contains)"
            echo "  --skip-build   Skip building harnesses (assume pre-built)"
            exit 0 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

ITER_ARGS=""
if [ -n "$ITERATIONS" ]; then
    ITER_ARGS="--iterations $ITERATIONS"
fi

# Default: run FM (String + UTF-8), nucleo, RapidFuzz (Ifrit and Contains are on-demand — too slow)
if [ "$ANY_FLAG" = false ]; then
    RUN_FM_ED=true
    RUN_FM_SW=true
    RUN_FM_ED_UTF8=true
    RUN_FM_SW_UTF8=true
    RUN_NUCLEO=true
    RUN_RF_WR=true
    RUN_RF_PR=true
    # Ifrit and Contains are on-demand only (very slow)
fi

if [ ! -f "$TSV_PATH" ]; then
    echo "Error: corpus file not found at $TSV_PATH"
    exit 1
fi

CORPUS_SIZE=$(wc -l < "$TSV_PATH" | tr -d ' ')
CORPUS_SIZE=$((CORPUS_SIZE - 1))  # subtract header

ENABLED=""
$RUN_FM_ED && ENABLED="$ENABLED FuzzyMatch(ED)"
$RUN_FM_SW && ENABLED="$ENABLED FuzzyMatch(SW)"
$RUN_FM_ED_UTF8 && ENABLED="$ENABLED FuzzyMatch(ED,UTF-8)"
$RUN_FM_SW_UTF8 && ENABLED="$ENABLED FuzzyMatch(SW,UTF-8)"
$RUN_NUCLEO && ENABLED="$ENABLED nucleo"
$RUN_RF_WR && ENABLED="$ENABLED RF(WRatio)"
$RUN_RF_PR && ENABLED="$ENABLED RF(Partial)"
$RUN_IFRIT && ENABLED="$ENABLED Ifrit"
$RUN_CONTAINS && ENABLED="$ENABLED Contains"

echo "============================================"
echo " Corpus Benchmark — FuzzyMatch vs nucleo vs RapidFuzz vs Ifrit vs Contains"
echo "============================================"
echo ""
echo "Corpus: $TSV_PATH ($CORPUS_SIZE candidates)"
echo "Running:$ENABLED"
echo ""

# --- Build selected ---
if [ "$SKIP_BUILD" = false ]; then
    if $RUN_FM_ED || $RUN_FM_SW || $RUN_FM_ED_UTF8 || $RUN_FM_SW_UTF8; then
        echo "Building FuzzyMatch benchmark (release)..."
        cd "$SCRIPT_DIR/bench-fuzzymatch"
        swift build -c release 2>&1 | tail -1
        echo ""
    fi

    if $RUN_NUCLEO; then
        echo "Building nucleo benchmark (release)..."
        cd "$SCRIPT_DIR/bench-nucleo"
        cargo build --release 2>&1 | tail -1
        echo ""
    fi

    if $RUN_RF_WR || $RUN_RF_PR; then
        echo "Building RapidFuzz benchmark..."
        cd "$SCRIPT_DIR/bench-rapidfuzz"
        make 2>&1 | tail -1
        echo ""
    fi

    if $RUN_IFRIT; then
        echo "Building Ifrit benchmark (release)..."
        cd "$SCRIPT_DIR/bench-ifrit"
        swift build -c release 2>&1 | tail -1
        echo ""
    fi

    if $RUN_CONTAINS; then
        echo "Building Contains baseline (release)..."
        cd "$SCRIPT_DIR/bench-contains"
        swift build -c release 2>&1 | tail -1
        echo ""
    fi
fi

# --- Run selected ---
NUCLEO_OUTPUT=""
RAPIDFUZZ_WR_OUTPUT=""
RAPIDFUZZ_PR_OUTPUT=""
FUZZYMATCH_OUTPUT=""
FUZZYMATCH_SW_OUTPUT=""
IFRIT_OUTPUT=""
CONTAINS_OUTPUT=""

if $RUN_NUCLEO; then
    echo "Running nucleo..."
    NUCLEO_OUTPUT=$(cd "$SCRIPT_DIR/bench-nucleo" && cargo run --release -- --tsv "$TSV_PATH" --queries "$QUERIES_PATH" $ITER_ARGS 2>/dev/null)
    echo "$NUCLEO_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

if $RUN_RF_WR; then
    echo "Running RapidFuzz (WRatio)..."
    RAPIDFUZZ_WR_OUTPUT=$(cd "$SCRIPT_DIR/bench-rapidfuzz" && ./bench-rapidfuzz --tsv "$TSV_PATH" --queries "$QUERIES_PATH" --scorer wratio $ITER_ARGS 2>/dev/null)
    echo "$RAPIDFUZZ_WR_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

if $RUN_RF_PR; then
    echo "Running RapidFuzz (PartialRatio)..."
    RAPIDFUZZ_PR_OUTPUT=$(cd "$SCRIPT_DIR/bench-rapidfuzz" && ./bench-rapidfuzz --tsv "$TSV_PATH" --queries "$QUERIES_PATH" --scorer partial_ratio $ITER_ARGS 2>/dev/null)
    echo "$RAPIDFUZZ_PR_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

if $RUN_FM_ED; then
    echo "Running FuzzyMatch (Edit Distance)..."
    FUZZYMATCH_OUTPUT=$(cd "$SCRIPT_DIR/bench-fuzzymatch" && swift run -c release bench-fuzzymatch --tsv "$TSV_PATH" --queries "$QUERIES_PATH" $ITER_ARGS 2>/dev/null)
    echo "$FUZZYMATCH_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

if $RUN_FM_SW; then
    echo "Running FuzzyMatch (Smith-Waterman)..."
    FUZZYMATCH_SW_OUTPUT=$(cd "$SCRIPT_DIR/bench-fuzzymatch" && swift run -c release bench-fuzzymatch --tsv "$TSV_PATH" --queries "$QUERIES_PATH" --sw $ITER_ARGS 2>/dev/null)
    echo "$FUZZYMATCH_SW_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

FUZZYMATCH_ED_UTF8_OUTPUT=""
FUZZYMATCH_SW_UTF8_OUTPUT=""

if $RUN_FM_ED_UTF8; then
    echo "Running FuzzyMatch (Edit Distance, UTF-8)..."
    FUZZYMATCH_ED_UTF8_OUTPUT=$(cd "$SCRIPT_DIR/bench-fuzzymatch" && swift run -c release bench-fuzzymatch --tsv "$TSV_PATH" --queries "$QUERIES_PATH" --utf8 $ITER_ARGS 2>/dev/null)
    echo "$FUZZYMATCH_ED_UTF8_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

if $RUN_FM_SW_UTF8; then
    echo "Running FuzzyMatch (Smith-Waterman, UTF-8)..."
    FUZZYMATCH_SW_UTF8_OUTPUT=$(cd "$SCRIPT_DIR/bench-fuzzymatch" && swift run -c release bench-fuzzymatch --tsv "$TSV_PATH" --queries "$QUERIES_PATH" --sw --utf8 $ITER_ARGS 2>/dev/null)
    echo "$FUZZYMATCH_SW_UTF8_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

# Contains is very slow — defaults to 1 iteration
if $RUN_CONTAINS; then
    echo "Running String.contains() baseline (slow — 1 iteration by default)..."
    CONTAINS_ITER_ARGS="${ITER_ARGS:-"--iterations 1"}"
    CONTAINS_OUTPUT=$(cd "$SCRIPT_DIR/bench-contains" && swift run -c release bench-contains --tsv "$TSV_PATH" --queries "$QUERIES_PATH" $CONTAINS_ITER_ARGS 2>/dev/null)
    echo "$CONTAINS_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

# Ifrit is very slow — defaults to 1 iteration
if $RUN_IFRIT; then
    echo "Running Ifrit (slow — 1 iteration by default)..."
    IFRIT_ITER_ARGS="${ITER_ARGS:-"--iterations 1"}"
    IFRIT_OUTPUT=$(cd "$SCRIPT_DIR/bench-ifrit" && swift run -c release bench-ifrit --tsv "$TSV_PATH" --queries "$QUERIES_PATH" $IFRIT_ITER_ARGS 2>/dev/null)
    echo "$IFRIT_OUTPUT" | grep -E "^(Total time|Throughput|Per-query)"
    echo ""
fi

# --- Save full outputs ---
if $RUN_FM_ED; then
    echo "$FUZZYMATCH_OUTPUT" > /tmp/bench-fuzzymatch-latest.txt
fi
if $RUN_FM_SW; then
    echo "$FUZZYMATCH_SW_OUTPUT" > /tmp/bench-fuzzymatch-sw-latest.txt
fi
if $RUN_FM_ED_UTF8; then
    echo "$FUZZYMATCH_ED_UTF8_OUTPUT" > /tmp/bench-fuzzymatch-ed-utf8-latest.txt
fi
if $RUN_FM_SW_UTF8; then
    echo "$FUZZYMATCH_SW_UTF8_OUTPUT" > /tmp/bench-fuzzymatch-sw-utf8-latest.txt
fi
if $RUN_NUCLEO; then
    echo "$NUCLEO_OUTPUT" > /tmp/bench-nucleo-latest.txt
fi
if $RUN_RF_WR; then
    echo "$RAPIDFUZZ_WR_OUTPUT" > /tmp/bench-rapidfuzz-wratio-latest.txt
fi
if $RUN_RF_PR; then
    echo "$RAPIDFUZZ_PR_OUTPUT" > /tmp/bench-rapidfuzz-partial-latest.txt
fi
if $RUN_IFRIT; then
    echo "$IFRIT_OUTPUT" > /tmp/bench-ifrit-latest.txt
fi
if $RUN_CONTAINS; then
    echo "$CONTAINS_OUTPUT" > /tmp/bench-contains-latest.txt
fi

# --- Comparison table (only when all are run) ---
if $RUN_FM_ED && $RUN_NUCLEO && $RUN_RF_WR && $RUN_RF_PR; then
    # --- Extract metadata from FuzzyMatch output ---
    NUM_QUERIES=$(echo "$FUZZYMATCH_OUTPUT" | grep "^Running " | sed 's/Running \([0-9]*\) queries/\1/')
    NUM_ITERATIONS=$(echo "$FUZZYMATCH_OUTPUT" | grep "^Iteration " | tail -1 | sed 's/Iteration \([0-9]*\):.*/\1/')

    echo "============================================"
    echo " Comparison Table"
    echo "============================================"
    echo ""
    echo "  Candidates:  $CORPUS_SIZE"
    echo "  Queries:     $NUM_QUERIES"
    echo "  Iterations:  $NUM_ITERATIONS"
    echo "  Per iteration: $NUM_QUERIES queries x $CORPUS_SIZE candidates = $(echo "$NUM_QUERIES * $CORPUS_SIZE" | bc) scorings"
    echo ""

    # Build file list for awk — include optional matchers if available
    AWK_FILES="/tmp/bench-fuzzymatch-latest.txt /tmp/bench-nucleo-latest.txt /tmp/bench-rapidfuzz-wratio-latest.txt /tmp/bench-rapidfuzz-partial-latest.txt"
    if $RUN_FM_SW; then
        AWK_FILES="$AWK_FILES /tmp/bench-fuzzymatch-sw-latest.txt"
    fi
    if $RUN_IFRIT; then
        AWK_FILES="$AWK_FILES /tmp/bench-ifrit-latest.txt"
    fi
    if $RUN_CONTAINS; then
        AWK_FILES="$AWK_FILES /tmp/bench-contains-latest.txt"
    fi

    awk -v has_ifrit="$RUN_IFRIT" -v has_sw="$RUN_FM_SW" -v has_contains="$RUN_CONTAINS" '
BEGIN {
    n_cats = split("exact_symbol exact_name exact_isin prefix typo substring multi_word symbol_spaces abbreviation", cats, " ")
}

# Extract total median from lines like:
# "Total time for 101 queries (min/median/max): 1725.4ms / 1725.6ms / 1730.3ms"
/^Total time/ {
    # Split on " / " to get the three values
    n = split($0, parts, " / ")
    if (n >= 2) {
        # parts[2] is like "1725.6ms"
        gsub(/ms.*/, "", parts[2])
        if (FILENAME == "/tmp/bench-fuzzymatch-latest.txt") fm_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-nucleo-latest.txt") nuc_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-rapidfuzz-wratio-latest.txt") rfw_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-rapidfuzz-partial-latest.txt") rfp_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-fuzzymatch-sw-latest.txt") sw_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-ifrit-latest.txt") ifrit_total = parts[2] + 0
        else if (FILENAME == "/tmp/bench-contains-latest.txt") cont_total = parts[2] + 0
    }
}

# Category summary lines: "exact_symbol   20  278.55  277.36  10540"
{
    for (i = 1; i <= n_cats; i++) {
        if ($1 == cats[i] && NF >= 5) {
            if (FILENAME == "/tmp/bench-fuzzymatch-latest.txt") {
                fm_med[$1] = $3 + 0
                fm_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-nucleo-latest.txt") {
                nuc_med[$1] = $3 + 0
                nuc_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-rapidfuzz-wratio-latest.txt") {
                rfw_med[$1] = $3 + 0
                rfw_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-rapidfuzz-partial-latest.txt") {
                rfp_med[$1] = $3 + 0
                rfp_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-fuzzymatch-sw-latest.txt") {
                sw_med[$1] = $3 + 0
                sw_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-ifrit-latest.txt") {
                ifrit_med[$1] = $3 + 0
                ifrit_matches[$1] = $5
            } else if (FILENAME == "/tmp/bench-contains-latest.txt") {
                cont_med[$1] = $3 + 0
                cont_matches[$1] = $5
            }
        }
    }
}

END {
    # Build format strings based on optional columns
    hdr = sprintf("%-20s %10s", "Category", "FuzzyMatch")
    sep_len = 80
    if (has_sw == "true") { hdr = hdr sprintf(" %15s", "FuzzyMatch(SW)"); sep_len += 16 }
    hdr = hdr sprintf(" %10s %12s %12s", "nucleo", "RF(WRatio)", "RF(Partial)")
    if (has_ifrit == "true") { hdr = hdr sprintf(" %10s", "Ifrit"); sep_len += 11 }
    if (has_contains == "true") { hdr = hdr sprintf(" %10s", "Contains"); sep_len += 11 }
    hdr = hdr sprintf(" %8s", "FM/nuc")
    if (has_sw == "true") { hdr = hdr sprintf(" %8s", "SW/nuc"); sep_len += 9 }
    if (has_contains == "true") { hdr = hdr sprintf(" %9s", "cont/FM"); sep_len += 10 }
    printf "%s\n", hdr
    for (i = 0; i < sep_len; i++) printf "-"; printf "\n"

    if (fm_total > 0 && nuc_total > 0 && rfw_total > 0 && rfp_total > 0) {
        fn_ratio = sprintf("%.1fx", fm_total / nuc_total)
        line = sprintf("%-20s %9.1fms", "TOTAL", fm_total)
        if (has_sw == "true") line = line sprintf(" %14.1fms", sw_total+0)
        line = line sprintf(" %9.1fms %11.1fms %11.1fms", nuc_total, rfw_total, rfp_total)
        if (has_ifrit == "true") line = line sprintf(" %9.1fms", ifrit_total+0)
        if (has_contains == "true") line = line sprintf(" %9.1fms", cont_total+0)
        line = line sprintf(" %8s", fn_ratio)
        if (has_sw == "true" && sw_total > 0) line = line sprintf(" %8s", sprintf("%.1fx", sw_total / nuc_total))
        if (has_contains == "true" && cont_total > 0) line = line sprintf(" %9s", sprintf("%.0fx", cont_total / fm_total))
        printf "%s\n", line
        for (i = 0; i < sep_len; i++) printf "-"; printf "\n"
    }

    for (i = 1; i <= n_cats; i++) {
        cat = cats[i]
        if (fm_med[cat] > 0 && nuc_med[cat] > 0) {
            fn_ratio = sprintf("%.1fx", fm_med[cat] / nuc_med[cat])
            line = sprintf("%-20s %9.1fms", cat, fm_med[cat])
            if (has_sw == "true") line = line sprintf(" %14.1fms", sw_med[cat]+0)
            line = line sprintf(" %9.1fms %11.1fms %11.1fms", nuc_med[cat], rfw_med[cat]+0, rfp_med[cat]+0)
            if (has_ifrit == "true") line = line sprintf(" %9.1fms", ifrit_med[cat]+0)
            if (has_contains == "true") line = line sprintf(" %9.1fms", cont_med[cat]+0)
            line = line sprintf(" %8s", fn_ratio)
            if (has_sw == "true" && sw_med[cat] > 0) line = line sprintf(" %8s", sprintf("%.1fx", sw_med[cat] / nuc_med[cat]))
            if (has_contains == "true" && cont_med[cat] > 0) line = line sprintf(" %9s", sprintf("%.0fx", cont_med[cat] / fm_med[cat]))
            printf "%s\n", line
        }
    }

    printf "\n"
    mhdr = sprintf("%-20s %12s", "Category", "FM(ED) match")
    msep_len = 72
    if (has_sw == "true") { mhdr = mhdr sprintf(" %15s", "FM(SW) matches"); msep_len += 16 }
    mhdr = mhdr sprintf(" %12s %12s %12s", "nuc matches", "RF(WR) match", "RF(PR) match")
    if (has_ifrit == "true") { mhdr = mhdr sprintf(" %12s", "Ifrit match"); msep_len += 13 }
    if (has_contains == "true") { mhdr = mhdr sprintf(" %12s", "Cont match"); msep_len += 13 }
    printf "%s\n", mhdr
    for (i = 0; i < msep_len; i++) printf "-"; printf "\n"
    for (i = 1; i <= n_cats; i++) {
        cat = cats[i]
        if (fm_matches[cat] != "") {
            line = sprintf("%-20s %12s", cat, fm_matches[cat])
            if (has_sw == "true") line = line sprintf(" %15s", sw_matches[cat])
            line = line sprintf(" %12s %12s %12s", nuc_matches[cat], rfw_matches[cat], rfp_matches[cat])
            if (has_ifrit == "true") line = line sprintf(" %12s", ifrit_matches[cat])
            if (has_contains == "true") line = line sprintf(" %12s", cont_matches[cat])
            printf "%s\n", line
        }
    }
}
' $AWK_FILES
fi

echo ""
echo "Full outputs saved to:"
$RUN_FM_ED && echo "  /tmp/bench-fuzzymatch-latest.txt"
$RUN_FM_SW && echo "  /tmp/bench-fuzzymatch-sw-latest.txt"
$RUN_FM_ED_UTF8 && echo "  /tmp/bench-fuzzymatch-ed-utf8-latest.txt"
$RUN_FM_SW_UTF8 && echo "  /tmp/bench-fuzzymatch-sw-utf8-latest.txt"
$RUN_NUCLEO && echo "  /tmp/bench-nucleo-latest.txt"
$RUN_RF_WR && echo "  /tmp/bench-rapidfuzz-wratio-latest.txt"
$RUN_RF_PR && echo "  /tmp/bench-rapidfuzz-partial-latest.txt"
$RUN_IFRIT && echo "  /tmp/bench-ifrit-latest.txt"
$RUN_CONTAINS && echo "  /tmp/bench-contains-latest.txt"
exit 0
