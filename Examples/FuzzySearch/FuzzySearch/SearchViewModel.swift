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
}

enum GapPenaltyKind: String, CaseIterable, Identifiable {
    case none = "None"
    case linear = "Linear"
    case affine = "Affine"
    var id: Self { self }
}

// MARK: - View Model

@MainActor
@Observable
final class SearchViewModel {
    // MARK: - Search State

    var query = ""
    var results: [SearchResult] = []
    var searchTimeMS: Double?
    var corpusSize = 0
    var isLoading = true
    var errorMessage: String?
    var dataSourceName = "instruments"

    // MARK: - UI State

    var showInspector = false

    // MARK: - Algorithm Selection

    var algorithmChoice: AlgorithmChoice = .editDistance {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    // MARK: - Shared Configuration

    var minScore: Double = 0.3 {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    var resultsLimit: Int = 25 {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    // MARK: - Edit Distance Configuration

    var edConfig = EditDistanceConfig.default {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    // Gap penalty decomposed for UI binding (GapPenalty is an enum with associated values)
    var gapPenaltyKind: GapPenaltyKind = .affine {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    var gapLinearRate: Double = 0.01 {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    var gapAffineOpen: Double = 0.03 {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    var gapAffineExtend: Double = 0.005 {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    // MARK: - Smith-Waterman Configuration

    var swConfig = SmithWatermanConfig.default {
        didSet {
            guard !suppressConfigUpdate else { return }
            configDidChange()
        }
    }

    // MARK: - Private

    private var instruments: [Instrument] = []
    private var candidateNames: [String] = []
    private var nameToFirstIndex: [String: Int] = [:]
    private var matcher = FuzzyMatcher()
    private var suppressConfigUpdate = false
    private var searchGeneration = 0

    // MARK: - Configuration Management

    func configDidChange() {
        let config: MatchConfig
        switch algorithmChoice {
        case .editDistance:
            var ed = edConfig
            switch gapPenaltyKind {
            case .none:
                ed.gapPenalty = .none
            case .linear:
                ed.gapPenalty = .linear(perCharacter: gapLinearRate)
            case .affine:
                ed.gapPenalty = .affine(open: gapAffineOpen, extend: gapAffineExtend)
            }
            config = MatchConfig(minScore: minScore, algorithm: .editDistance(ed))
        case .smithWaterman:
            config = MatchConfig(minScore: minScore, algorithm: .smithWaterman(swConfig))
        }
        matcher = FuzzyMatcher(config: config)
        scheduleSearch()
    }

    func resetToDefaults() {
        suppressConfigUpdate = true
        edConfig = .default
        swConfig = .default
        minScore = 0.3
        resultsLimit = 25
        gapPenaltyKind = .affine
        gapLinearRate = 0.01
        gapAffineOpen = 0.03
        gapAffineExtend = 0.005
        suppressConfigUpdate = false
        configDidChange()
    }

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
                dataSourceName = url.lastPathComponent
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

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? String(contentsOf: url, encoding: .utf8)
        else {
            return
        }

        resetData()

        let lines = data.split(separator: "\n", omittingEmptySubsequences: true)
        instruments.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            instruments.append(
                Instrument(id: i, symbol: "", name: String(line), isin: "", productClass: ""))
        }

        candidateNames = instruments.map(\.name)
        nameToFirstIndex = Dictionary(
            candidateNames.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        corpusSize = instruments.count
        dataSourceName = url.lastPathComponent
        isLoading = false
    }

    private func resetData() {
        instruments = []
        candidateNames = []
        nameToFirstIndex = [:]
        results = []
        searchTimeMS = nil
        query = ""
        errorMessage = nil
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
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searchTimeMS = nil
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        let matcher = self.matcher
        let candidateNames = self.candidateNames
        let instruments = self.instruments
        let nameToFirstIndex = self.nameToFirstIndex
        let resultsLimit = self.resultsLimit

        Task {
            let (newResults, ms) = Self.performSearch(
                query: q,
                matcher: matcher,
                candidateNames: candidateNames,
                instruments: instruments,
                nameToFirstIndex: nameToFirstIndex,
                resultsLimit: resultsLimit
            )

            guard generation == self.searchGeneration else { return }
            self.results = newResults
            self.searchTimeMS = ms
        }
    }

    private nonisolated static func performSearch(
        query: String,
        matcher: FuzzyMatcher,
        candidateNames: [String],
        instruments: [Instrument],
        nameToFirstIndex: [String: Int],
        resultsLimit: Int
    ) -> ([SearchResult], Double) {
        let clock = ContinuousClock()
        let start = clock.now

        let prepared = matcher.prepare(query)
        let topMatches = matcher.topMatches(candidateNames, against: prepared, limit: resultsLimit)

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
