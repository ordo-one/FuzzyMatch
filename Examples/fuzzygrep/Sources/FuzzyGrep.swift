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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import AsyncAlgorithms
import FuzzyMatch
import Foundation

// MARK: - Tagged types for ordered parallel pipeline

struct TaggedChunk: Sendable {
    let sequenceNumber: Int
    let lines: [String]
}

struct TaggedResult: Sendable {
    let sequenceNumber: Int
    let lines: [String]
}

/// Transfers a ~Copyable MPSC source into a Sendable closure.
/// Each instance is consumed exactly once via `take()`.
private final class SourceBox: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<
        MultiProducerSingleConsumerAsyncChannel<TaggedResult, Never>.Source
    >

    init(_ source: consuming MultiProducerSingleConsumerAsyncChannel<TaggedResult, Never>.Source) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: source)
    }

    func take() -> MultiProducerSingleConsumerAsyncChannel<TaggedResult, Never>.Source {
        let source = pointer.move()
        pointer.deallocate()
        return source
    }
}

@main
struct FuzzyGrep {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)

        var args = Array(CommandLine.arguments.dropFirst())

        // Parse -score option
        var minScore = 0.85
        if let idx = args.firstIndex(of: "-score") {
            guard idx + 1 < args.count, let value = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("Error: -score requires a value between 0.0 and 1.0\n".utf8))
                Foundation.exit(1)
            }
            guard value >= 0.0, value <= 1.0 else {
                FileHandle.standardError.write(
                    Data("Error: score must be between 0.0 and 1.0, got \(value)\n".utf8))
                Foundation.exit(1)
            }
            minScore = value
            args.removeSubrange(idx...idx + 1)
        }

        guard let queryString = args.first else {
            FileHandle.standardError.write(
                Data("Usage: fuzzygrep <query> [--sw] [-score 0.0-1.0]\n".utf8))
            Foundation.exit(1)
        }

        let useSmithWaterman = args.contains("--sw")
        let config = MatchConfig(
            minScore: minScore,
            algorithm: useSmithWaterman ? .smithWaterman() : .editDistance()
        )
        let matcher = FuzzyMatcher(config: config)
        let query = matcher.prepare(queryString)

        let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let workerChannels = (0..<workerCount).map { _ in AsyncChannel<TaggedChunk>() }

        // MPSC channel: workers → writer
        var channelAndSource = MultiProducerSingleConsumerAsyncChannel<TaggedResult, Never>.makeChannel(
            backpressureStrategy: .watermark(low: workerCount, high: workerCount * 4)
        )
        var resultChannel = channelAndSource.takeChannel()

        // Create one additional source per worker, then drop the original
        var boxes: [SourceBox] = []
        boxes.reserveCapacity(workerCount)
        for _ in 0..<workerCount {
            boxes.append(SourceBox(channelAndSource.source.makeAdditionalSource()))
        }
        _ = consume channelAndSource

        await withTaskGroup(of: Void.self) { group in
            // Reader: distributes stdin chunks round-robin to workers
            group.addTask {
                await readStdin(into: workerChannels)
            }

            // Workers: score lines, send results to MPSC channel
            for i in 0..<workerCount {
                let box = boxes[i]
                let input = workerChannels[i]
                group.addTask {
                    await matchWorker(
                        from: input, sourceBox: box,
                        matcher: matcher, query: query)
                }
            }

            // Writer: reorder results by sequence number and write to stdout
            var nextExpected = 0
            var pending: [Int: [String]] = [:]
            var outputBuf = Data()

            while let result = await resultChannel.next() {
                if result.sequenceNumber == nextExpected {
                    if !result.lines.isEmpty {
                        appendLines(result.lines, to: &outputBuf)
                        if !writeToStdout(outputBuf) { Foundation.exit(0) }
                        outputBuf.removeAll(keepingCapacity: true)
                    }
                    nextExpected += 1
                    while let buffered = pending.removeValue(forKey: nextExpected) {
                        if !buffered.isEmpty {
                            appendLines(buffered, to: &outputBuf)
                            if !writeToStdout(outputBuf) { Foundation.exit(0) }
                            outputBuf.removeAll(keepingCapacity: true)
                        }
                        nextExpected += 1
                    }
                } else {
                    pending[result.sequenceNumber] = result.lines
                }
            }
        }
    }
}

// MARK: - Pipeline stages

/// Reads stdin in 256 KB blocks, splits into lines, distributes chunks round-robin across worker channels.
private func readStdin(into workerChannels: [AsyncChannel<TaggedChunk>],
                       chunkSize: Int = 4096) async {
    let handle = FileHandle.standardInput
    let newline = UInt8(ascii: "\n")
    let workerCount = workerChannels.count
    var remainder: [UInt8] = []
    var lines: [String] = []
    lines.reserveCapacity(chunkSize)
    var sequenceNumber = 0

    while true {
        let data = handle.readData(ofLength: 262_144)
        if data.isEmpty { break }

        let scanStart = remainder.count
        data.withUnsafeBytes { remainder.append(contentsOf: $0) }

        var lineStart = 0
        for i in scanStart..<remainder.count {
            if remainder[i] == newline {
                lines.append(String(decoding: remainder[lineStart..<i], as: UTF8.self))
                lineStart = i + 1
                if lines.count >= chunkSize {
                    let chunk = TaggedChunk(sequenceNumber: sequenceNumber, lines: lines)
                    await workerChannels[sequenceNumber % workerCount].send(chunk)
                    sequenceNumber += 1
                    lines = []
                    lines.reserveCapacity(chunkSize)
                }
            }
        }
        if lineStart > 0 {
            remainder.removeSubrange(0..<lineStart)
        }
    }

    if !remainder.isEmpty {
        lines.append(String(decoding: remainder, as: UTF8.self))
    }
    if !lines.isEmpty {
        let chunk = TaggedChunk(sequenceNumber: sequenceNumber, lines: lines)
        await workerChannels[sequenceNumber % workerCount].send(chunk)
    }
    for channel in workerChannels {
        channel.finish()
    }
}

/// Scores each line against the query, sends results to the MPSC channel.
private func matchWorker(
    from input: AsyncChannel<TaggedChunk>,
    sourceBox: SourceBox,
    matcher: FuzzyMatcher,
    query: FuzzyQuery
) async {
    var source = sourceBox.take()
    var buffer = matcher.makeBuffer()

    for await chunk in input {
        var matched: [String] = []
        for line in chunk.lines {
            if matcher.score(line, against: query, buffer: &buffer) != nil {
                matched.append(line)
            }
        }
        let result = TaggedResult(sequenceNumber: chunk.sequenceNumber, lines: matched)
        do {
            try await source.send(result)
        } catch {
            break
        }
    }
    source.finish()
}

private func appendLines(_ lines: [String], to buffer: inout Data) {
    for line in lines {
        buffer.append(contentsOf: line.utf8)
        buffer.append(UInt8(ascii: "\n"))
    }
}

/// Writes data to stdout using POSIX write(2). Returns false on broken pipe / error.
private func writeToStdout(_ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = write(STDOUT_FILENO, base + offset, buffer.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}
