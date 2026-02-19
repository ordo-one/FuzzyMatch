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

// Lightweight polyfill for Swift 6.2's Span<T>.
// Provides the same subscript/count/extracting API surface used by the library.
// Only compiled by pre-6.2 compilers; Swift 6.2+ uses the real stdlib Span.

#if !compiler(>=6.2)

@usableFromInline
internal struct Span<Element>: @unchecked Sendable {
    @usableFromInline let pointer: UnsafePointer<Element>
    @usableFromInline let count: Int

    @inlinable
    init(_ buffer: UnsafeBufferPointer<Element>) {
        // Use a non-nil sentinel for empty buffers (count==0 means no indexing occurs)
        pointer = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        count = buffer.count
    }

    @inlinable
    subscript(index: Int) -> Element {
        pointer[index]
    }

    @inlinable
    func extracting(_ range: Range<Int>) -> Span {
        Span(UnsafeBufferPointer(start: pointer + range.lowerBound, count: range.count))
    }
}

extension Array {
    @usableFromInline
    var span: Span<Element> {
        @inlinable get {
            withUnsafeBufferPointer { Span($0) }
        }
    }
}

#endif
