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
    /// Returns the top matches from a sequence of items, matching against a string
    /// property extracted via key path, sorted by score descending.
    ///
    /// This is the generic counterpart of ``topMatches(_:against:limit:)-7q3wo``.
    /// Instead of requiring a sequence of strings, it accepts any sequence of items
    /// and a key path to the string property to match against.
    ///
    /// - Parameters:
    ///   - candidates: The items to search.
    ///   - keyPath: A key path to the string property to match against.
    ///   - query: A prepared query from ``prepare(_:)``.
    ///   - limit: Maximum number of results to return. Default is `10`.
    /// - Returns: An array of ``ItemMatchResult`` sorted by score descending,
    ///   containing at most `limit` elements.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct Instrument {
    ///     let ticker: String
    ///     let name: String
    /// }
    ///
    /// let instruments = [
    ///     Instrument(ticker: "AAPL", name: "Apple Inc"),
    ///     Instrument(ticker: "MSFT", name: "Microsoft Corporation"),
    ///     Instrument(ticker: "GOOG", name: "Alphabet Inc"),
    /// ]
    ///
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("apple")
    /// let results = matcher.topMatches(instruments, by: \.name, against: query, limit: 3)
    /// for result in results {
    ///     print("\(result.item.ticker): \(result.match.score)")
    /// }
    /// ```
    public func topMatches<Item>(
        _ candidates: some Sequence<Item>,
        by keyPath: KeyPath<Item, String>,
        against query: FuzzyQuery,
        limit: Int = 10
    ) -> [ItemMatchResult<Item>] {
        var buffer = makeBuffer()
        var results: [ItemMatchResult<Item>] = []
        results.reserveCapacity(limit)

        for candidate in candidates {
            guard let match = score(candidate[keyPath: keyPath], against: query, buffer: &buffer) else {
                continue
            }
            let result = ItemMatchResult(item: candidate, match: match)
            if results.count < limit {
                results.append(result)
                if results.count == limit {
                    results.sort { $0.match.score > $1.match.score }
                }
            } else if match.score > results[results.count - 1].match.score {
                results[results.count - 1] = result
                results.sort { $0.match.score > $1.match.score }
            }
        }

        if results.count < limit {
            results.sort { $0.match.score > $1.match.score }
        }

        return results
    }

    /// Returns all matching items sorted by score descending, matching against a
    /// string property extracted via key path.
    ///
    /// This is the generic counterpart of ``matches(_:against:)-1fvd5``.
    /// Instead of requiring a sequence of strings, it accepts any sequence of items
    /// and a key path to the string property to match against.
    ///
    /// - Parameters:
    ///   - candidates: The items to search.
    ///   - keyPath: A key path to the string property to match against.
    ///   - query: A prepared query from ``prepare(_:)``.
    /// - Returns: An array of ``ItemMatchResult`` sorted by score descending.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct Instrument {
    ///     let ticker: String
    ///     let name: String
    /// }
    ///
    /// let instruments = [
    ///     Instrument(ticker: "AAPL", name: "Apple Inc"),
    ///     Instrument(ticker: "MSFT", name: "Microsoft Corporation"),
    ///     Instrument(ticker: "GOOG", name: "Alphabet Inc"),
    /// ]
    ///
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("inc")
    /// let all = matcher.matches(instruments, by: \.name, against: query)
    /// // Returns matches for instruments whose names match "inc"
    /// ```
    public func matches<Item>(
        _ candidates: some Sequence<Item>,
        by keyPath: KeyPath<Item, String>,
        against query: FuzzyQuery
    ) -> [ItemMatchResult<Item>] {
        var buffer = makeBuffer()
        var results: [ItemMatchResult<Item>] = []

        for candidate in candidates {
            if let match = score(candidate[keyPath: keyPath], against: query, buffer: &buffer) {
                results.append(ItemMatchResult(item: candidate, match: match))
            }
        }

        results.sort { $0.match.score > $1.match.score }
        return results
    }

    /// Returns the top matches from a sequence of items, matching against a string
    /// property extracted via key path, sorted by score descending.
    ///
    /// This is a convenience method that handles query preparation internally.
    /// For scoring many queries against the same candidates, prefer the
    /// ``prepare(_:)`` + ``topMatches(_:by:against:limit:)-3o7g8`` pattern instead.
    ///
    /// - Parameters:
    ///   - candidates: The items to search.
    ///   - keyPath: A key path to the string property to match against.
    ///   - query: The query string to match against.
    ///   - limit: Maximum number of results to return. Default is `10`.
    /// - Returns: An array of ``ItemMatchResult`` sorted by score descending,
    ///   containing at most `limit` elements.
    public func topMatches<Item>(
        _ candidates: some Sequence<Item>,
        by keyPath: KeyPath<Item, String>,
        against query: String,
        limit: Int = 10
    ) -> [ItemMatchResult<Item>] {
        topMatches(candidates, by: keyPath, against: prepare(query), limit: limit)
    }

    /// Returns all matching items sorted by score descending, matching against a
    /// string property extracted via key path.
    ///
    /// This is a convenience method that handles query preparation internally.
    /// For scoring many queries against the same candidates, prefer the
    /// ``prepare(_:)`` + ``matches(_:by:against:)-8skx7`` pattern instead.
    ///
    /// - Parameters:
    ///   - candidates: The items to search.
    ///   - keyPath: A key path to the string property to match against.
    ///   - query: The query string to match against.
    /// - Returns: An array of ``ItemMatchResult`` sorted by score descending.
    public func matches<Item>(
        _ candidates: some Sequence<Item>,
        by keyPath: KeyPath<Item, String>,
        against query: String
    ) -> [ItemMatchResult<Item>] {
        matches(candidates, by: keyPath, against: prepare(query))
    }
}
