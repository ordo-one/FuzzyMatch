// ===----------------------------------------------------------------------===//
//
// This source file is part of the FuzzyMatch open source project
//
// Copyright (c) 2026 Ordo One, AB. and the FuzzyMatch project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
// ===----------------------------------------------------------------------===//

extension FuzzyMatcher {
    /// Returns ranges of matched characters in the candidate for UI highlighting.
    ///
    /// Separate from ``score(_:against:buffer:)`` — call only for visible results
    /// (typically ~10-20), not the full corpus. Returns `nil` if the candidate
    /// doesn't match the query.
    ///
    /// The returned ranges are coalesced and sorted, suitable for SwiftUI `Text`
    /// or `NSAttributedString` formatting. Adjacent matched positions are merged
    /// into single ranges, and combining diacritical marks (U+0300–U+036F) are
    /// included in the preceding character's range.
    ///
    /// ## Matching Behavior
    ///
    /// **Edit distance mode** tries phases in priority order, returning the first
    /// successful one:
    ///
    /// 1. **Exact prefix** (distance 0) — contiguous range at the start
    /// 2. **Exact substring** (distance 0) — contiguous range, word-boundary preferred
    /// 3. **Subsequence alignment** — scattered character positions via DP
    /// 4. **Acronym** — word-initial character positions
    /// 5. **Edit distance traceback** (distance > 0) — Damerau-Levenshtein alignment
    ///    with full traceback, handling typos (substitutions), missing characters,
    ///    extra characters, and transpositions. Matched *and* substituted candidate
    ///    positions are highlighted; extra query characters are absorbed.
    ///
    /// **Smith-Waterman mode** runs:
    ///
    /// 1. **Exact match** — full string range
    /// 2. **Smith-Waterman DP** — local alignment with traceback. For multi-word
    ///    queries, each atom is aligned independently and positions are merged.
    /// 3. **Acronym fallback** — word-initial positions for short queries
    ///
    /// ## Examples
    ///
    /// Highlighting an exact substring:
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("mod")
    ///
    /// if let ranges = matcher.highlight("format:modern", against: query) {
    ///     // ranges highlight "mod" in "modern", not scattered across the string
    ///     var text = AttributedString("format:modern")
    ///     for range in ranges {
    ///         let start = AttributedString.Index(range.lowerBound, within: text)!
    ///         let end = AttributedString.Index(range.upperBound, within: text)!
    ///         text[start..<end].foregroundColor = .accentColor
    ///     }
    /// }
    /// ```
    ///
    /// Highlighting a query with a typo (edit distance mode):
    /// ```swift
    /// let matcher = FuzzyMatcher()
    ///
    /// // "getusar" has a typo ('a' instead of 'e') — highlights "getUser"
    /// let ranges = matcher.highlight("getUserById", against: "getusar")!
    /// // ranges covers "getUser" — the substituted 'e' is highlighted
    ///
    /// // "modrn" is missing the 'e' — highlights "mod" + "rn"
    /// let ranges2 = matcher.highlight("format:modern", against: "modrn")!
    /// // Two ranges: "mod" and "rn", skipping the unmatched 'e'
    /// ```
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to highlight.
    ///   - query: A prepared query from ``prepare(_:)``.
    /// - Returns: Coalesced, sorted ranges of matched characters, or `nil` if no match.
    public func highlight(
        _ candidate: String,
        against query: FuzzyQuery
    ) -> [Range<String.Index>]? {
        let queryLength = query.lowercased.count
        if queryLength == 0 {
            return []
        }

        var mutableCandidate = candidate
        return mutableCandidate.withUTF8 { candidateUTF8 in
            highlightImpl(candidateUTF8, candidate: candidate, against: query)
        }
    }

    /// Convenience overload accepting a raw query string.
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to highlight.
    ///   - query: The query string to match against.
    /// - Returns: Coalesced, sorted ranges of matched characters, or `nil` if no match.
    public func highlight(
        _ candidate: String,
        against query: String
    ) -> [Range<String.Index>]? {
        highlight(candidate, against: prepare(query))
    }

    // MARK: - Implementation

    /// Core highlight implementation operating on UTF-8 bytes.
    private func highlightImpl(
        _ candidateUTF8: UnsafeBufferPointer<UInt8>,
        candidate: String,
        against query: FuzzyQuery
    ) -> [Range<String.Index>]? {
        let candidateLength = candidateUTF8.count
        let queryLength = query.lowercased.count

        if candidateLength == 0 {
            return nil
        }

        // Build normalization mapping: normalized byte index → original byte offset
        let (normalizedBytes, mapping, isASCII) = buildNormalizationMapping(candidateUTF8)
        let normalizedLength = normalizedBytes.count

        // Exact match check
        if normalizedLength == queryLength {
            var isExact = true
            for i in 0..<queryLength {
                if normalizedBytes[i] != query.lowercased[i] {
                    isExact = false
                    break
                }
            }
            if isExact {
                let start = candidate.startIndex
                let end = candidate.endIndex
                return [start..<end]
            }
        }

        // Get normalized positions based on algorithm
        let normalizedPositions: [Int]?

        switch query.config.algorithm {
        case .editDistance(let edConfig):
            normalizedPositions = highlightEditDistance(
                normalizedBytes: normalizedBytes,
                candidateUTF8: candidateUTF8,
                isASCII: isASCII,
                query: query,
                edConfig: edConfig
            )

        case .smithWaterman(let swConfig):
            normalizedPositions = highlightSmithWaterman(
                normalizedBytes: normalizedBytes,
                candidateUTF8: candidateUTF8,
                isASCII: isASCII,
                query: query,
                swConfig: swConfig
            )
        }

        guard let positions = normalizedPositions else { return nil }

        // Map normalized positions back to original string ranges
        return mapPositionsToRanges(
            positions: positions,
            mapping: mapping,
            candidateUTF8: candidateUTF8,
            candidate: candidate
        )
    }

    // MARK: - Normalization Mapping

    /// Builds a normalization mapping that mirrors `lowercaseUTF8()` but tracks
    /// the original byte offset for each normalized byte.
    ///
    /// `mapping[normalizedIndex]` gives the original byte offset of the source
    /// character that produced that normalized byte.
    private func buildNormalizationMapping(
        _ source: UnsafeBufferPointer<UInt8>
    ) -> (normalizedBytes: [UInt8], mapping: [Int], isASCII: Bool) {
        let count = source.count
        var normalized = [UInt8](repeating: 0, count: count)
        var mapping = [Int](repeating: 0, count: count)
        let isASCII = source.allSatisfy { $0 < 0x80 }

        if isASCII {
            for i in 0..<count {
                normalized[i] = confusableASCIIToCanonical(lowercaseASCII(source[i]))
                mapping[i] = i
            }
            return (normalized, mapping, true)
        }

        var i = 0
        var outIdx = 0
        while i < count {
            let byte = source[i]

            // Skip combining diacritical marks
            if i + 1 < count && isCombiningMark(lead: byte, second: source[i + 1]) {
                i += 2
            } else if byte == 0xC3 && i + 1 < count {
                let lowered = lowercaseLatinExtended(source[i + 1])
                let ascii = latin1ToASCII(lowered)
                if ascii != 0 {
                    // 2 source bytes → 1 output byte
                    normalized[outIdx] = ascii
                    mapping[outIdx] = i
                    outIdx += 1
                } else {
                    normalized[outIdx] = byte
                    mapping[outIdx] = i
                    normalized[outIdx + 1] = lowered
                    mapping[outIdx + 1] = i
                    outIdx += 2
                }
                i += 2
            } else if (byte == 0xCE || byte == 0xCF) && i + 1 < count {
                let (newLead, newSecond) = lowercaseGreek(lead: byte, second: source[i + 1])
                normalized[outIdx] = newLead
                mapping[outIdx] = i
                normalized[outIdx + 1] = newSecond
                mapping[outIdx + 1] = i
                outIdx += 2
                i += 2
            } else if (byte == 0xD0 || byte == 0xD1) && i + 1 < count {
                let (newLead, newSecond) = lowercaseCyrillic(lead: byte, second: source[i + 1])
                normalized[outIdx] = newLead
                mapping[outIdx] = i
                normalized[outIdx + 1] = newSecond
                mapping[outIdx + 1] = i
                outIdx += 2
                i += 2
            } else if (byte == 0xC2 || byte == 0xCA) && i + 1 < count {
                let ascii = confusable2ByteToASCII(lead: byte, second: source[i + 1])
                if ascii != 0 {
                    normalized[outIdx] = ascii
                    mapping[outIdx] = i
                    outIdx += 1
                } else {
                    normalized[outIdx] = byte
                    mapping[outIdx] = i
                    normalized[outIdx + 1] = source[i + 1]
                    mapping[outIdx + 1] = i
                    outIdx += 2
                }
                i += 2
            } else if byte == 0xE2 && i + 2 < count {
                let ascii = confusable3ByteToASCII(second: source[i + 1], third: source[i + 2])
                if ascii != 0 {
                    normalized[outIdx] = ascii
                    mapping[outIdx] = i
                    outIdx += 1
                } else {
                    normalized[outIdx] = byte
                    mapping[outIdx] = i
                    normalized[outIdx + 1] = source[i + 1]
                    mapping[outIdx + 1] = i
                    normalized[outIdx + 2] = source[i + 2]
                    mapping[outIdx + 2] = i
                    outIdx += 3
                }
                i += 3
            } else {
                normalized[outIdx] = confusableASCIIToCanonical(lowercaseASCII(byte))
                mapping[outIdx] = i
                outIdx += 1
                i += 1
            }
        }

        // Truncate to actual length
        if outIdx < count {
            normalized.removeSubrange(outIdx..<count)
            mapping.removeSubrange(outIdx..<count)
        }

        return (normalized, mapping, false)
    }

    // MARK: - Edit Distance Highlight

    /// Finds match positions using the edit distance pipeline phases.
    private func highlightEditDistance(
        normalizedBytes: [UInt8],
        candidateUTF8: UnsafeBufferPointer<UInt8>,
        isASCII: Bool,
        query: FuzzyQuery,
        edConfig: EditDistanceConfig
    ) -> [Int]? {
        let queryLength = query.lowercased.count
        let normalizedLength = normalizedBytes.count

        return normalizedBytes.withUnsafeBufferPointer { candidateSpan in
            query.lowercased.withUnsafeBufferPointer { querySpan in
                let boundaryMask = computeBoundaryMaskCompressed(
                    originalBytes: candidateUTF8, isASCII: isASCII
                )

                // Try prefix match first
                var edState = EditDistanceState(maxQueryLength: queryLength)
                let prefixDist = prefixEditDistance(
                    query: querySpan,
                    candidate: candidateSpan,
                    state: &edState,
                    maxEditDistance: query.effectiveMaxEditDistance
                )

                if let dist = prefixDist, dist == 0 {
                    // Exact prefix: return positions 0..<queryLength
                    return Array(0..<queryLength)
                }

                // Try substring exact match
                let substringDist = substringEditDistance(
                    query: querySpan,
                    candidate: candidateSpan,
                    state: &edState,
                    maxEditDistance: query.effectiveMaxEditDistance
                )

                if let dist = substringDist, dist == 0 {
                    // Find the best contiguous substring location
                    let start = findContiguousSubstring(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: boundaryMask
                    )
                    if start >= 0 {
                        return (0..<queryLength).map { start + $0 }
                    }
                }

                // Use DP-optimal alignment for subsequence/fuzzy positions
                var matchPositions = [Int](repeating: 0, count: queryLength)

                if queryLength <= 4 {
                    let posCount = findMatchPositions(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: boundaryMask,
                        positions: &matchPositions
                    )
                    if posCount == queryLength {
                        // For short queries with exact substring, try contiguous
                        if substringDist == 0 {
                            let firstPos = matchPositions[0]
                            let lastPos = matchPositions[posCount - 1]
                            if lastPos - firstPos + 1 != queryLength {
                                let start = findContiguousSubstring(
                                    query: querySpan,
                                    candidate: candidateSpan,
                                    boundaryMask: boundaryMask
                                )
                                if start >= 0 {
                                    return (0..<queryLength).map { start + $0 }
                                }
                            }
                        }
                        return Array(matchPositions[0..<posCount])
                    }
                    // Greedy failed (boundary preference can skip viable positions).
                    // Fall back to DP-optimal alignment which considers all options.
                    if normalizedLength <= 512 {
                        var alignState = AlignmentState(
                            maxQueryLength: queryLength,
                            maxCandidateLength: normalizedLength
                        )
                        let (dpCount, _) = optimalAlignment(
                            query: querySpan,
                            candidate: candidateSpan,
                            boundaryMask: boundaryMask,
                            positions: &matchPositions,
                            state: &alignState,
                            config: edConfig
                        )
                        if dpCount == queryLength {
                            return Array(matchPositions[0..<dpCount])
                        }
                    }
                } else if normalizedLength <= 512 {
                    var alignState = AlignmentState(
                        maxQueryLength: queryLength,
                        maxCandidateLength: normalizedLength
                    )
                    let (posCount, _) = optimalAlignment(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: boundaryMask,
                        positions: &matchPositions,
                        state: &alignState,
                        config: edConfig
                    )
                    if posCount == queryLength {
                        return Array(matchPositions[0..<posCount])
                    }
                } else {
                    let posCount = findMatchPositions(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: boundaryMask,
                        positions: &matchPositions
                    )
                    if posCount == queryLength {
                        return Array(matchPositions[0..<posCount])
                    }
                }

                // Try acronym
                if let acronymPositions = findAcronymPositions(
                    querySpan: querySpan,
                    candidateSpan: candidateSpan,
                    boundaryMask: boundaryMask,
                    candidateLength: normalizedLength
                ) {
                    return acronymPositions
                }

                // ED traceback for queries with typos (substitutions, missing/extra
                // chars, transpositions). This is the last resort — subsequence and
                // acronym paths failed, meaning not all query chars exist in candidate.
                // Guard: distance must be less than query length (full substitution
                // of every character is degenerate and not worth highlighting).
                let edDist = prefixDist ?? substringDist
                if let dist = edDist, dist > 0, dist < queryLength {
                    return editDistancePositions(
                        query: querySpan,
                        candidate: candidateSpan,
                        maxEditDistance: dist
                    )
                }

                return nil
            }
        }
    }

    // MARK: - Smith-Waterman Highlight

    /// Finds match positions using the Smith-Waterman algorithm.
    private func highlightSmithWaterman(
        normalizedBytes: [UInt8],
        candidateUTF8: UnsafeBufferPointer<UInt8>,
        isASCII: Bool,
        query: FuzzyQuery,
        swConfig: SmithWatermanConfig
    ) -> [Int]? {
        let queryLength = query.lowercased.count
        let normalizedLength = normalizedBytes.count

        // Compute per-position bonuses (mirrors scoreSmithWatermanImpl merged pass)
        var bonusArray = [Int32](repeating: 0, count: normalizedLength)
        computeSWBonuses(
            normalizedBytes: normalizedBytes,
            candidateUTF8: candidateUTF8,
            isASCII: isASCII,
            config: swConfig,
            bonus: &bonusArray
        )

        return normalizedBytes.withUnsafeBufferPointer { candidateSpan in
            query.lowercased.withUnsafeBufferPointer { querySpan in
                bonusArray.withUnsafeBufferPointer { bonusSpan in
                    if query.atoms.count > 1 {
                        // Multi-atom: run per atom, concatenate
                        var allPositions: [Int] = []
                        for atom in query.atoms {
                            let atomQuery = UnsafeBufferPointer(
                                rebasing: querySpan[atom.start..<(atom.start + atom.length)]
                            )
                            guard let atomPositions = smithWatermanPositions(
                                query: atomQuery,
                                candidate: candidateSpan,
                                bonus: bonusSpan,
                                config: swConfig
                            ) else {
                                return nil
                            }
                            allPositions.append(contentsOf: atomPositions)
                        }
                        allPositions.sort()
                        return allPositions
                    }

                    // Single query
                    if let positions = smithWatermanPositions(
                        query: querySpan,
                        candidate: candidateSpan,
                        bonus: bonusSpan,
                        config: swConfig
                    ) {
                        return positions
                    }

                    // Acronym fallback for short queries
                    if queryLength >= 2 && queryLength <= 8 {
                        let boundaryMask = computeBoundaryMaskCompressed(
                            originalBytes: candidateUTF8, isASCII: isASCII
                        )
                        return findAcronymPositions(
                            querySpan: querySpan,
                            candidateSpan: candidateSpan,
                            boundaryMask: boundaryMask,
                            candidateLength: normalizedLength
                        )
                    }

                    return nil
                }
            }
        }
    }

    /// Computes per-position SW bonuses matching the scoreSmithWatermanImpl merged pass.
    private func computeSWBonuses(
        normalizedBytes: [UInt8],
        candidateUTF8: UnsafeBufferPointer<UInt8>,
        isASCII: Bool,
        config: SmithWatermanConfig,
        bonus: inout [Int32]
    ) {
        let bonusBoundaryVal = Int32(config.bonusBoundary)
        let bonusBoundaryWhitespaceVal = Int32(config.bonusBoundaryWhitespace)
        let bonusBoundaryDelimiterVal = Int32(config.bonusBoundaryDelimiter)
        let bonusCamelCaseVal = Int32(config.bonusCamelCase)
        let normalizedLength = normalizedBytes.count

        // We need to compute bonuses on the original bytes (for camelCase detection)
        // but indexed by normalized positions. This mirrors the merged pass logic.
        if isASCII {
            var prevByte: UInt8 = 0
            for i in 0..<normalizedLength {
                let byte = candidateUTF8[i]
                let posBonus: Int32
                if i == 0 {
                    posBonus = bonusBoundaryWhitespaceVal
                } else {
                    let currIsUpper = byte >= 0x41 && byte <= 0x5A
                    let currIsLower = byte >= 0x61 && byte <= 0x7A
                    let currIsDigit = byte >= 0x30 && byte <= 0x39
                    let currIsWhitespace = byte == 0x20 || byte == 0x09

                    if currIsWhitespace {
                        posBonus = bonusBoundaryWhitespaceVal
                    } else if !(currIsUpper || currIsLower || currIsDigit) {
                        posBonus = bonusBoundaryVal
                    } else {
                        let prevIsWhitespace = prevByte == 0x20 || prevByte == 0x09
                        if prevIsWhitespace {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if prevByte == 0x2F || prevByte == 0x3A
                            || prevByte == 0x3B || prevByte == 0x7C {
                            posBonus = bonusBoundaryDelimiterVal
                        } else {
                            let prevIsLower = prevByte >= 0x61 && prevByte <= 0x7A
                            if prevIsLower && currIsUpper {
                                posBonus = bonusCamelCaseVal
                            } else {
                                let prevIsDigit = prevByte >= 0x30 && prevByte <= 0x39
                                if !prevIsDigit && currIsDigit {
                                    posBonus = bonusCamelCaseVal
                                } else {
                                    let prevIsUpper = prevByte >= 0x41 && prevByte <= 0x5A
                                    let prevIsAlnum = prevIsLower || prevIsUpper || prevIsDigit
                                    posBonus = (!prevIsAlnum && !prevIsWhitespace) ? bonusBoundaryVal : 0
                                }
                            }
                        }
                    }
                }
                bonus[i] = posBonus
                prevByte = byte
            }
        } else {
            // Multi-byte: use original bytes for camelCase, track source position
            var prevByte: UInt8 = 0
            var srcIdx = 0
            var outIdx = 0
            let srcCount = candidateUTF8.count
            while srcIdx < srcCount && outIdx < normalizedLength {
                let byte = candidateUTF8[srcIdx]

                if srcIdx + 1 < srcCount && isCombiningMark(lead: byte, second: candidateUTF8[srcIdx + 1]) {
                    srcIdx += 2
                } else if byte == 0xC3 && srcIdx + 1 < srcCount {
                    let lowered = lowercaseLatinExtended(candidateUTF8[srcIdx + 1])
                    let ascii = latin1ToASCII(lowered)
                    if ascii != 0 {
                        bonus[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        prevByte = candidateUTF8[srcIdx + 1]
                        outIdx += 1
                    } else {
                        bonus[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        if outIdx + 1 < normalizedLength {
                            bonus[outIdx + 1] = 0
                        }
                        prevByte = candidateUTF8[srcIdx + 1]
                        outIdx += 2
                    }
                    srcIdx += 2
                } else if (byte == 0xCE || byte == 0xCF) && srcIdx + 1 < srcCount {
                    bonus[outIdx] = multiBytePositionBonus(
                        outIdx: outIdx, prevByte: prevByte,
                        bonusBoundaryVal: bonusBoundaryVal,
                        bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                        bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                    )
                    if outIdx + 1 < normalizedLength {
                        bonus[outIdx + 1] = 0
                    }
                    prevByte = candidateUTF8[srcIdx + 1]
                    outIdx += 2
                    srcIdx += 2
                } else if (byte == 0xD0 || byte == 0xD1) && srcIdx + 1 < srcCount {
                    bonus[outIdx] = multiBytePositionBonus(
                        outIdx: outIdx, prevByte: prevByte,
                        bonusBoundaryVal: bonusBoundaryVal,
                        bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                        bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                    )
                    if outIdx + 1 < normalizedLength {
                        bonus[outIdx + 1] = 0
                    }
                    prevByte = candidateUTF8[srcIdx + 1]
                    outIdx += 2
                    srcIdx += 2
                } else if (byte == 0xC2 || byte == 0xCA) && srcIdx + 1 < srcCount {
                    let ascii = confusable2ByteToASCII(lead: byte, second: candidateUTF8[srcIdx + 1])
                    if ascii != 0 {
                        let posBonus: Int32
                        if outIdx == 0 {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if ascii == 0x20 {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else {
                            posBonus = bonusBoundaryVal
                        }
                        bonus[outIdx] = posBonus
                        prevByte = ascii
                        outIdx += 1
                    } else {
                        bonus[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        if outIdx + 1 < normalizedLength {
                            bonus[outIdx + 1] = 0
                        }
                        prevByte = candidateUTF8[srcIdx + 1]
                        outIdx += 2
                    }
                    srcIdx += 2
                } else if byte == 0xE2 && srcIdx + 2 < srcCount {
                    let ascii = confusable3ByteToASCII(second: candidateUTF8[srcIdx + 1], third: candidateUTF8[srcIdx + 2])
                    if ascii != 0 {
                        let posBonus: Int32
                        if outIdx == 0 {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else {
                            posBonus = bonusBoundaryVal
                        }
                        bonus[outIdx] = posBonus
                        prevByte = ascii
                        outIdx += 1
                    } else {
                        bonus[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        if outIdx + 1 < normalizedLength {
                            bonus[outIdx + 1] = 0
                        }
                        if outIdx + 2 < normalizedLength {
                            bonus[outIdx + 2] = 0
                        }
                        prevByte = candidateUTF8[srcIdx + 2]
                        outIdx += 3
                    }
                    srcIdx += 3
                } else {
                    let posBonus: Int32
                    if outIdx == 0 {
                        posBonus = bonusBoundaryWhitespaceVal
                    } else {
                        let currIsUpper = byte >= 0x41 && byte <= 0x5A
                        let currIsLower = byte >= 0x61 && byte <= 0x7A
                        let currIsDigit = byte >= 0x30 && byte <= 0x39
                        let currIsWhitespace = byte == 0x20 || byte == 0x09

                        if currIsWhitespace {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if !(currIsUpper || currIsLower || currIsDigit) {
                            posBonus = bonusBoundaryVal
                        } else {
                            let prevIsWhitespace = prevByte == 0x20 || prevByte == 0x09
                            if prevIsWhitespace {
                                posBonus = bonusBoundaryWhitespaceVal
                            } else if prevByte == 0x2F || prevByte == 0x3A
                                || prevByte == 0x3B || prevByte == 0x7C {
                                posBonus = bonusBoundaryDelimiterVal
                            } else {
                                let prevIsLower = prevByte >= 0x61 && prevByte <= 0x7A
                                if prevIsLower && currIsUpper {
                                    posBonus = bonusCamelCaseVal
                                } else {
                                    let prevIsDigit = prevByte >= 0x30 && prevByte <= 0x39
                                    if !prevIsDigit && currIsDigit {
                                        posBonus = bonusCamelCaseVal
                                    } else {
                                        let prevIsAlnum = (prevByte >= 0x41 && prevByte <= 0x5A)
                                            || (prevByte >= 0x61 && prevByte <= 0x7A)
                                            || prevByte == 0xC3
                                            || prevByte == 0xCE || prevByte == 0xCF
                                            || prevByte == 0xD0 || prevByte == 0xD1
                                            || (prevByte >= 0x80 && prevByte <= 0xBF)
                                            || prevIsDigit
                                        posBonus = (prevIsAlnum || prevIsWhitespace) ? 0 : bonusBoundaryVal
                                    }
                                }
                            }
                        }
                    }
                    bonus[outIdx] = posBonus
                    prevByte = byte
                    outIdx += 1
                    srcIdx += 1
                }
            }
        }
    }

    // MARK: - Acronym Position Finder

    /// Finds positions matching word-initial characters (acronym pattern).
    private func findAcronymPositions(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        boundaryMask: UInt64,
        candidateLength: Int
    ) -> [Int]? {
        let queryLength = querySpan.count
        guard queryLength >= 2 && queryLength <= 8 else { return nil }

        // Collect word-initial positions and their bytes
        var initials: [(pos: Int, byte: UInt8)] = []
        let limit = min(candidateLength, 64)
        for i in 0..<limit {
            if (boundaryMask & (1 << i)) != 0 {
                initials.append((pos: i, byte: candidateSpan[i]))
            }
        }
        if candidateLength > 64 {
            for i in 64..<candidateLength {
                if isWordBoundary(at: i, in: candidateSpan) {
                    initials.append((pos: i, byte: candidateSpan[i]))
                }
            }
        }

        guard initials.count >= queryLength else { return nil }

        // Subsequence match of query against word initials
        var positions: [Int] = []
        var qi = 0
        for initial in initials {
            if qi < queryLength && querySpan[qi] == initial.byte {
                positions.append(initial.pos)
                qi += 1
            }
        }

        return qi == queryLength ? positions : nil
    }

    // MARK: - Position → Range Mapping

    /// Maps normalized byte positions back to `Range<String.Index>` in the original string.
    private func mapPositionsToRanges(
        positions: [Int],
        mapping: [Int],
        candidateUTF8: UnsafeBufferPointer<UInt8>,
        candidate: String
    ) -> [Range<String.Index>] {
        guard !positions.isEmpty else { return [] }

        let utf8View = candidate.utf8
        let candidateLength = candidateUTF8.count
        var rawRanges: [(lower: Int, upper: Int)] = []

        for normalizedPos in positions {
            guard normalizedPos < mapping.count else { continue }

            let originalByteOffset = mapping[normalizedPos]

            // Determine the full extent of the original character at this offset
            let charStart = originalByteOffset
            var charEnd = charStart + 1

            if charStart < candidateLength {
                let byte = candidateUTF8[charStart]
                if byte < 0x80 {
                    charEnd = charStart + 1
                } else if byte < 0xC0 {
                    // Continuation byte — shouldn't happen at char start, but be safe
                    charEnd = charStart + 1
                } else if byte < 0xE0 {
                    charEnd = min(charStart + 2, candidateLength)
                } else if byte < 0xF0 {
                    charEnd = min(charStart + 3, candidateLength)
                } else {
                    charEnd = min(charStart + 4, candidateLength)
                }

                // Extend past any following combining marks
                while charEnd < candidateLength {
                    if charEnd + 1 < candidateLength
                        && isCombiningMark(lead: candidateUTF8[charEnd], second: candidateUTF8[charEnd + 1]) {
                        charEnd += 2
                    } else {
                        break
                    }
                }
            }

            rawRanges.append((lower: charStart, upper: charEnd))
        }

        // Sort by start position
        rawRanges.sort { $0.lower < $1.lower }

        // Coalesce adjacent/overlapping ranges
        var coalesced: [(lower: Int, upper: Int)] = []
        for range in rawRanges {
            if let last = coalesced.last, range.lower <= last.upper {
                coalesced[coalesced.count - 1].upper = max(last.upper, range.upper)
            } else {
                coalesced.append(range)
            }
        }

        // Convert byte offsets to String.Index
        let startIndex = utf8View.startIndex
        return coalesced.compactMap { range in
            let lower = utf8View.index(startIndex, offsetBy: range.lower, limitedBy: utf8View.endIndex)
                ?? utf8View.endIndex
            let upper = utf8View.index(startIndex, offsetBy: range.upper, limitedBy: utf8View.endIndex)
                ?? utf8View.endIndex
            guard lower < upper else { return nil }
            return lower..<upper
        }
    }
}
