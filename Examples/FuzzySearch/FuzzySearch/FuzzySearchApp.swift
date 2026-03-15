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

import FuzzyMatch
import SwiftUI

@main
struct FuzzySearchApp: App {
    @State private var viewModel = SearchViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    viewModel.openFile()
                }
                .keyboardShortcut("o")
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ContentUnavailableView {
                        ProgressView()
                    } description: {
                        Text("Loading corpus...")
                    }
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if viewModel.query.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text(
                            "\(viewModel.corpusSize.formatted()) entries loaded from \(viewModel.dataSourceName)"
                        )
                    )
                } else if viewModel.results.isEmpty && viewModel.searchTimeMS != nil {
                    ContentUnavailableView.search(text: viewModel.query)
                } else {
                    resultsList
                }
            }
            .navigationTitle("FuzzySearch")
            .searchable(
                text: $viewModel.query,
                prompt: "Search \(viewModel.corpusSize.formatted()) entries..."
            )
            .onChange(of: viewModel.query) { _, _ in
                viewModel.scheduleSearch()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Algorithm", selection: $viewModel.algorithmChoice) {
                        ForEach(AlgorithmChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Matching algorithm")
                }
            }
            .task {
                viewModel.loadCorpus()
            }
        }
    }

    private var resultsList: some View {
        List {
            ForEach(viewModel.results) { result in
                ResultRow(result: result)
            }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            if let ms = viewModel.searchTimeMS {
                Label(
                    "\(viewModel.results.count) results",
                    systemImage: "list.number"
                )
                Label(
                    String(format: "%.1f ms", ms),
                    systemImage: "clock"
                )
            }
            Spacer()
            Text(viewModel.algorithmChoice.rawValue)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Result Row

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            // Rank badge
            Text("\(result.rank)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.secondary))

            // Main content
            VStack(alignment: .leading, spacing: 3) {
                Text(result.highlightedName)
                    .font(.body)

                if !result.instrument.symbol.isEmpty {
                    HStack(spacing: 12) {
                        Label(result.instrument.symbol, systemImage: "tag")
                        Label(result.instrument.isin, systemImage: "number")
                        Label(result.instrument.productClass, systemImage: "square.grid.2x2")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer()

            // Score and match kind
            VStack(alignment: .trailing, spacing: 3) {
                Text(result.score, format: .percent.precision(.fractionLength(1)))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.secondary)

                Text(result.kind.description.capitalized)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(kindColor.opacity(0.12))
                    )
                    .foregroundStyle(kindColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindColor: Color {
        switch result.kind {
        case .exact: .green
        case .prefix: .blue
        case .substring: .purple
        case .acronym: .orange
        case .alignment: .teal
        @unknown default: .gray
        }
    }
}
