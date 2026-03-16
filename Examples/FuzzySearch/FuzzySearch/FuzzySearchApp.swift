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
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    viewModel.openFile()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button(viewModel.showInspector ? "Hide Inspector" : "Show Inspector") {
                    withAnimation {
                        viewModel.showInspector.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
                ToolbarItem(placement: .principal) {
                    Picker("Algorithm", selection: $viewModel.algorithmChoice) {
                        ForEach(AlgorithmChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Matching algorithm")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.showInspector.toggle()
                    } label: {
                        Label("Toggle Inspector", systemImage: "info.circle")
                    }
                }
            }
            .inspector(isPresented: $viewModel.showInspector) {
                ConfigurationPanel(viewModel: viewModel)
                    .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
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

// MARK: - Configuration Panel

struct ConfigurationPanel: View {
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        Form {
            generalSection

            switch viewModel.algorithmChoice {
            case .editDistance:
                editDistanceSection
            case .smithWaterman:
                smithWatermanSection
            }

            Section {
                Button("Reset to Defaults") {
                    viewModel.resetToDefaults()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            ParameterSlider(
                label: "Min Score",
                value: $viewModel.minScore,
                range: 0...1,
                step: 0.05,
                format: "%.2f"
            )
            ParameterStepper(
                label: "Results Limit",
                value: $viewModel.resultsLimit,
                range: 5...100
            )
        }
    }

    // MARK: Edit Distance

    @ViewBuilder
    private var editDistanceSection: some View {
        Section("Distance Limits") {
            ParameterStepper(
                label: "Max Edit Distance",
                value: $viewModel.edConfig.maxEditDistance,
                range: 0...5
            )
            ParameterStepper(
                label: "Long Query Max ED",
                value: $viewModel.edConfig.longQueryMaxEditDistance,
                range: 0...5
            )
            ParameterStepper(
                label: "Long Query Threshold",
                value: $viewModel.edConfig.longQueryThreshold,
                range: 1...50
            )
        }

        Section("Weights") {
            ParameterSlider(
                label: "Prefix",
                value: $viewModel.edConfig.prefixWeight,
                range: 0...3,
                step: 0.1,
                format: "%.1f"
            )
            ParameterSlider(
                label: "Substring",
                value: $viewModel.edConfig.substringWeight,
                range: 0...3,
                step: 0.1,
                format: "%.1f"
            )
            ParameterSlider(
                label: "Acronym",
                value: $viewModel.edConfig.acronymWeight,
                range: 0...3,
                step: 0.1,
                format: "%.1f"
            )
        }

        Section("Bonuses") {
            ParameterSlider(
                label: "Word Boundary",
                value: $viewModel.edConfig.wordBoundaryBonus,
                range: 0...0.5,
                step: 0.01,
                format: "%.3f"
            )
            ParameterSlider(
                label: "Consecutive",
                value: $viewModel.edConfig.consecutiveBonus,
                range: 0...0.3,
                step: 0.005,
                format: "%.3f"
            )
            ParameterSlider(
                label: "First Match",
                value: $viewModel.edConfig.firstMatchBonus,
                range: 0...0.5,
                step: 0.01,
                format: "%.3f"
            )
            ParameterStepper(
                label: "First Match Range",
                value: $viewModel.edConfig.firstMatchBonusRange,
                range: 1...50
            )
        }

        Section("Penalties") {
            ParameterSlider(
                label: "Length Penalty",
                value: $viewModel.edConfig.lengthPenalty,
                range: 0...0.02,
                step: 0.001,
                format: "%.4f"
            )
            Picker("Gap Model", selection: $viewModel.gapPenaltyKind) {
                ForEach(GapPenaltyKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.gapPenaltyKind {
            case .none:
                EmptyView()
            case .linear:
                ParameterSlider(
                    label: "Per Character",
                    value: $viewModel.gapLinearRate,
                    range: 0...0.1,
                    step: 0.001,
                    format: "%.3f"
                )
            case .affine:
                ParameterSlider(
                    label: "Gap Open",
                    value: $viewModel.gapAffineOpen,
                    range: 0...0.2,
                    step: 0.005,
                    format: "%.3f"
                )
                ParameterSlider(
                    label: "Gap Extend",
                    value: $viewModel.gapAffineExtend,
                    range: 0...0.05,
                    step: 0.001,
                    format: "%.4f"
                )
            }
        }
    }

    // MARK: Smith-Waterman

    @ViewBuilder
    private var smithWatermanSection: some View {
        Section("Scoring") {
            ParameterStepper(
                label: "Score Match",
                value: $viewModel.swConfig.scoreMatch,
                range: 1...50
            )
            ParameterStepper(
                label: "Gap Start Penalty",
                value: $viewModel.swConfig.penaltyGapStart,
                range: 0...20
            )
            ParameterStepper(
                label: "Gap Extend Penalty",
                value: $viewModel.swConfig.penaltyGapExtend,
                range: 0...20
            )
        }

        Section("Bonuses") {
            ParameterStepper(
                label: "Consecutive",
                value: $viewModel.swConfig.bonusConsecutive,
                range: 0...30
            )
            ParameterStepper(
                label: "Boundary",
                value: $viewModel.swConfig.bonusBoundary,
                range: 0...30
            )
            ParameterStepper(
                label: "Whitespace Boundary",
                value: $viewModel.swConfig.bonusBoundaryWhitespace,
                range: 0...30
            )
            ParameterStepper(
                label: "Delimiter Boundary",
                value: $viewModel.swConfig.bonusBoundaryDelimiter,
                range: 0...30
            )
            ParameterStepper(
                label: "camelCase",
                value: $viewModel.swConfig.bonusCamelCase,
                range: 0...30
            )
            ParameterStepper(
                label: "First Char Multiplier",
                value: $viewModel.swConfig.bonusFirstCharMultiplier,
                range: 1...10
            )
        }

        Section("Behavior") {
            Toggle("Split Spaces", isOn: $viewModel.swConfig.splitSpaces)
        }
    }
}

// MARK: - Reusable Controls

struct ParameterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
        }
    }
}

struct ParameterStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
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
