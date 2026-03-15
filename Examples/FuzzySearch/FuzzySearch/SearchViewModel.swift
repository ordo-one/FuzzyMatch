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

import AppKit
import FuzzyMatch
import SwiftUI

// MARK: - Data Models

struct Instrument: Identifiable, Sendable {
    let id: Int
    let symbol: String
    let name: String
    let isin: String
    let productClass: String
}

struct SearchResult: Identifiable {
    let id: Int
    let rank: Int
    let instrument: Instrument
    let score: Double
    let kind: MatchKind
    let highlightedName: AttributedString
}

enum AlgorithmChoice: String, CaseIterable, Identifiable {
    case editDistance = "Edit Distance"
    case smithWaterman = "Smith-Waterman"

    var id: Self { self }

    var config: MatchConfig {
        switch self {
        case .editDistance: .editDistance
        case .smithWaterman: .smithWaterman
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var results: [SearchResult] = []
    var searchTimeMS: Double?
    var corpusSize = 0
    var isLoading = true
    var errorMessage: String?
    var algorithmChoice: AlgorithmChoice = .editDistance {
        didSet {
            matcher = FuzzyMatcher(config: algorithmChoice.config)
            scheduleSearch()
        }
    }

    private var instruments: [Instrument] = []
    private var candidateNames: [String] = []
    private var nameToFirstIndex: [String: Int] = [:]
    private var searchTask: Task<Void, Never>?
    private var matcher = FuzzyMatcher()

    // MARK: - Corpus Loading

    /// Resolves the corpus path relative to this source file at compile time,
    /// so the app finds the data regardless of working directory (e.g. when launched from Xcode).
    private static let corpusURL: URL = {
        // #filePath → .../Examples/FuzzySearch/FuzzySearch/SearchViewModel.swift
        // Navigate up to the FuzzyMatch project root, then into Resources/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FuzzySearch/
            .deletingLastPathComponent()   // Examples/FuzzySearch/
            .deletingLastPathComponent()   // Examples/
            .deletingLastPathComponent()   // FuzzyMatch project root
            .appendingPathComponent("Resources/instruments-export.tsv")
    }()

    func loadCorpus() {
        isLoading = true

        let paths = [
            Self.corpusURL.path,
            "Resources/instruments-export.tsv",
            "../Resources/instruments-export.tsv",
        ]

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let data = try? String(contentsOf: url, encoding: .utf8) {
                parseCorpus(data)
                isLoading = false
                return
            }
        }

        // Fallback: open file panel
        let panel = NSOpenPanel()
        panel.title = "Select instruments-export.tsv"
        panel.message = "Locate the corpus file (Resources/instruments-export.tsv)"
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
            let data = try? String(contentsOf: url, encoding: .utf8)
        {
            parseCorpus(data)
        } else {
            errorMessage =
                "No corpus file loaded.\nRun from the FuzzyMatch project root:\n  swift run --package-path Examples FuzzySearch"
        }

        isLoading = false
    }

    private func parseCorpus(_ data: String) {
        let lines = data.split(separator: "\n").dropFirst()  // skip header
        instruments.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            let cols = line.split(separator: "\t", maxSplits: 3)
            guard cols.count >= 4 else { continue }
            instruments.append(
                Instrument(
                    id: i,
                    symbol: String(cols[0]),
                    name: String(cols[1]),
                    isin: String(cols[2]),
                    productClass: String(cols[3])
                ))
        }

        candidateNames = instruments.map(\.name)

        for (i, name) in candidateNames.enumerated() {
            if nameToFirstIndex[name] == nil {
                nameToFirstIndex[name] = i
            }
        }

        corpusSize = instruments.count
    }

    // MARK: - Search

    func scheduleSearch() {
        searchTask?.cancel()

        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searchTimeMS = nil
            return
        }

        let matcher = self.matcher
        let candidateNames = self.candidateNames
        let instruments = self.instruments
        let nameToFirstIndex = self.nameToFirstIndex

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            let (newResults, ms) = Self.performSearch(
                query: q,
                matcher: matcher,
                candidateNames: candidateNames,
                instruments: instruments,
                nameToFirstIndex: nameToFirstIndex
            )

            guard !Task.isCancelled else { return }
            self.results = newResults
            self.searchTimeMS = ms
        }
    }

    private nonisolated static func performSearch(
        query: String,
        matcher: FuzzyMatcher,
        candidateNames: [String],
        instruments: [Instrument],
        nameToFirstIndex: [String: Int]
    ) -> ([SearchResult], Double) {
        let clock = ContinuousClock()
        let start = clock.now

        let prepared = matcher.prepare(query)
        let topMatches = matcher.topMatches(candidateNames, against: prepared, limit: 20)

        let elapsed = clock.now - start
        let ms =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        let searchResults: [SearchResult] = topMatches.enumerated().compactMap { rank, matchResult in
            let highlighted = matcher.attributedHighlight(
                matchResult.candidate,
                against: prepared
            ) { container in
                container.foregroundColor = .orange
                container.font = .body.bold()
                container.underlineStyle = .single
                container.underlineColor = .orange
            }

            guard let idx = nameToFirstIndex[matchResult.candidate] else { return nil }

            return SearchResult(
                id: rank,
                rank: rank + 1,
                instrument: instruments[idx],
                score: matchResult.match.score,
                kind: matchResult.match.kind,
                highlightedName: highlighted ?? AttributedString(matchResult.candidate)
            )
        }

        return (searchResults, ms)
    }
}
