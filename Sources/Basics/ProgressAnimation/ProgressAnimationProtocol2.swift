//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// MARK: - ProgressAnimation2Task
@_spi(SwiftPMInternal)
public struct ProgressAnimation2Task {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

extension ProgressAnimation2Task: Equatable {}

extension ProgressAnimation2Task: Hashable {}

extension ProgressAnimation2Task: Identifiable {}

// MARK: - ProgressAnimation2TaskCounts
struct ProgressAnimation2TaskCounts {
    private(set) var pending: Int
    private(set) var running: Int
    private(set) var succeeded: Int
    private(set) var failed: Int
    private(set) var cancelled: Int
    private(set) var skipped: Int
    // Should be the sum of all other complete counts
    private(set) var completed: Int
    // Should be the sum of all other counts
    private(set) var total: Int
}

extension ProgressAnimation2TaskCounts {
    mutating func taskDiscovered() {
        self.pending += 1
        self.total += 1
    }

    mutating func taskStarted() {
        self.pending -= 1
        self.running += 1
    }

    mutating func taskSkipped() {
        self.pending -= 1
        self.skipped += 1
        self.completed += 1
    }

    mutating func taskCompleted(_ completionEvent: ProgressAnimation2TaskCompletionEvent) {
        self.running -= 1
        self.completed += 1
        switch completionEvent {
        case .succeeded:
            self.succeeded += 1
        case .failed:
            self.failed += 1
        case .cancelled:
            self.cancelled += 1
        case .skipped:
            self.skipped += 1
        }
    }
}

extension ProgressAnimation2TaskCounts {
    static var zero: Self {
        .init(
            pending: 0,
            running: 0,
            succeeded: 0,
            failed: 0,
            cancelled: 0,
            skipped: 0,
            completed: 0,
            total: 0)
    }
}

// MARK: - ProgressAnimation2TaskEvent
@_spi(SwiftPMInternal)
public enum ProgressAnimation2TaskEvent {
    case discovered
    case started
    case completed(ProgressAnimation2TaskCompletionEvent)
}

extension ProgressAnimation2TaskEvent {
    var color: (ANSITextStyle.Color, Bool) {
        switch self {
        case .discovered: (.yellow, false)
        case .started: (.cyan, false)
        case .completed(.succeeded): (.green, false)
        case .completed(.failed): (.red, false)
        case .completed(.cancelled): (.magenta, false)
        case .completed(.skipped): (.black, true)
        }
    }

    var symbol: String {
        #if os(macOS)
        switch self {
        case .discovered: "􀍡 "
        case .started: "􀚁 "
        case .completed(.succeeded): "􀁢 "
        case .completed(.failed): "􀁠 "
        case .completed(.cancelled): "􀁞 "
        case .completed(.skipped): "􀕧 "
        }
        #else
        switch self {
        case .pass: "✔"
        case .fail: "✘"
        case .skip: "⍉"
        }
        #endif
    }
}

extension ProgressAnimation2TaskEvent: Equatable {}

extension ProgressAnimation2TaskEvent: Hashable {}

// MARK: - ProgressAnimation2TaskCompletionEvent
@_spi(SwiftPMInternal)
public enum ProgressAnimation2TaskCompletionEvent {
    case succeeded
    case failed
    case cancelled
    case skipped
}

extension ProgressAnimation2TaskCompletionEvent: Equatable {}

extension ProgressAnimation2TaskCompletionEvent: Hashable {}

// MARK: - ProgressAnimationProtocol2
// TODO: This protocol could be extended to handle a task tree and represent the root task
@_spi(SwiftPMInternal)
public protocol ProgressAnimationProtocol2 {
    func update(
        task: ProgressAnimation2Task,
        event: ProgressAnimation2TaskEvent,
        at time: ContinuousClock.Instant)

    /// Complete the animation.
    func complete()

    /// Draw the animation.
    func draw()

    /// Clear the animation.
    func clear()
}
