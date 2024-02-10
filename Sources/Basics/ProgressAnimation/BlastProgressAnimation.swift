//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import class TSCBasic.TerminalController
import protocol TSCBasic.WritableByteStream

extension ProgressAnimation {
    /// A modern progress animation that adapts to the provided output stream.
    @_spi(SwiftPMInternal_ProgressAnimation)
    public static func blast(
        stream: WritableByteStream,
        verbose: Bool
    ) -> any ProgressAnimationProtocol {
        Self.dynamic(
            stream: stream,
            verbose: verbose,
            ttyTerminalAnimationFactory: { Blast(terminal: $0) },
            dumbTerminalAnimationFactory: { SingleLinePercentProgressAnimation(stream: stream, header: nil) },
            defaultAnimationFactory: { MultiLineNinjaProgressAnimation(stream: stream) })
    }
}

extension FormatStyle where Self == Duration.UnitsFormatStyle {
    static var blast: Self {
        .units(
            width: .narrow,
            fractionalPart: .init(lengthLimits: 0...2))
    }
}

struct BlastTask: Equatable, Comparable {
    var name: String
    var start: ContinuousClock.Instant
    var state: BlastTaskState

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.start < rhs.start }
}

enum BlastTaskState {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
    case skipped

    var color: TerminalController.Color {
        switch self {
        case .pending: .yellow
        case .running: .cyan
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .gray
        case .skipped: .gray
        }
    }

    var symbol: String {
        #if os(macOS)
        switch self {
        case .pending: "􀍡 "
        case .running: "􀚁 "
        case .succeeded: "􀁢 "
        case .failed: "􀁠 "
        case .cancelled: "􀁞 "
        case .skipped: "􀕧 "
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

struct BlastTaskCounts {
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


    var pending: Int
    var running: Int
    var succeeded: Int
    var failed: Int
    var cancelled: Int
    var skipped: Int
    // Should be the sum of all other complete counts
    var completed: Int
    // Should be the sum of all other counts
    var total: Int

    func validate() {
        let completed = self.succeeded + self.failed + self.cancelled + self.skipped
        assert(completed == self.completed)
        let total = completed + self.running + self.pending
        assert(total == self.total)
    }
}

class Blast {
    var terminal: TerminalController
    var counts: BlastTaskCounts
    var drawnLines: Int
    var tasks: [Int: BlastTask]

    init(terminal: TerminalController) {
        self.terminal = terminal
        self.counts = .zero
        self.drawnLines = 0
        self.tasks = [:]
    }

    func log(_ message: String) {
#if BLAST_LOG || true
        fputs("\(message)\n", stderr)
#endif
    }
}

extension Blast: ProgressAnimationProtocol {
    func update(step: Int, total: Int, text: String) { }
}

extension Blast: ProgressAnimationProtocol2 {
    func discovered(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.pending(task: \(name), id: \(id), at: \(time))")
        guard !self.tasks.keys.contains(id) else {
            log(">> unexpected duplicate discovery of task with id: \(id) and name: \(name)")
            return
        }
        self.counts.pending += 1
        self.counts.total += 1

        self.tasks[id] = BlastTask(name: name, start: time, state: .pending)
        self.clear()
        self.draw()
    }

    func running(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.running(task: \(name), id: \(id), at: \(time))")
        guard var task = self.tasks[id] else {
            log(">> unexpected start of unknown task with id: \(id) and name: \(name)")
            return
        }
        guard task.state == .pending else {
            log(">> unexpected restart of task with id: \(id) and name: \(name) in state: \(task.state)")
            return
        }
        self.counts.pending -= 1
        self.counts.running += 1

        task.state = .running
        self.tasks[id] = task
        self.clear()
        self.draw()
    }

    func succeeded(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.succeeded(task: \(name), id: \(id), at: \(time))")
        guard var task = self.tasks[id] else {
            log(">> unexpected completion \(BlastTaskState.succeeded) of unknown task with id: \(id) and name: \(name)")
            return
        }
        switch task.state {
        case .pending:
            guard task.state == .running else {
                log(">> unexpected completion \(BlastTaskState.succeeded) of not running task with id: \(id) and name: \(name) in state: \(task.state)")
                return
            }
        case .running:
            self.counts.running -= 1
            self.counts.succeeded += 1
            self.counts.completed += 1

            task.state = .succeeded
            self.tasks[id] = task
            self.clear()
            self.drawTask(state: .succeeded, task: name, duration: task.start.duration(to: time))
            self.draw()
        case .succeeded, .failed, .cancelled, .skipped:
            // Already accounted for
            return
        }
    }

    func failed(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.failed(task: \(name), id: \(id), at: \(time))")
        guard var task = self.tasks[id] else {
            log(">> unexpected completion \(BlastTaskState.failed) of unknown task with id: \(id) and name: \(name)")
            return
        }
        guard task.state == .running else {
            log(">> unexpected completion \(BlastTaskState.failed) of not running task with id: \(id) and name: \(name) in state: \(task.state)")
            return
        }
        self.counts.running -= 1
        self.counts.failed += 1
        self.counts.completed += 1

        task.state = .failed
        self.tasks[id] = task
        self.clear()
        self.drawTask(state: .failed, task: name, duration: task.start.duration(to: time))
        self.draw()
    }

    func cancelled(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.cancelled(task: \(name), id: \(id), at: \(time))")
        guard var task = self.tasks[id] else {
            log(">> unexpected completion \(BlastTaskState.cancelled) of unknown task with id: \(id) and name: \(name)")
            return
        }
        guard task.state == .running else {
            log(">> unexpected completion \(BlastTaskState.cancelled) of not running task with id: \(id) and name: \(name) in state: \(task.state)")
            return
        }
        self.counts.running -= 1
        self.counts.cancelled += 1
        self.counts.completed += 1

        task.state = .cancelled
        self.tasks[id] = task
        self.clear()
        self.drawTask(state: .cancelled, task: name, duration: task.start.duration(to: time))
        self.draw()
    }

    func skipped(task name: String, id: Int, at time: ContinuousClock.Instant) {
        log("Blast.skipped(task: \(name), id: \(id), at: \(time))")
        guard var task = self.tasks[id] else {
            log(">> unexpected completion \(BlastTaskState.skipped) of unknown task with id: \(id) and name: \(name)")
            return
        }

        switch task.state {
        case .pending, .running:
            if task.state == .pending {
                self.counts.pending -= 1
            } else {
                self.counts.running -= 1
            }
            self.counts.skipped += 1
            self.counts.completed += 1

            task.state = .skipped
            self.tasks[id] = task
            self.clear()
            self.drawTask(state: .skipped, task: name, duration: task.start.duration(to: time))
            self.draw()
        case .succeeded, .failed, .cancelled, .skipped:
            // Already accounted for
            return
        }
    }

    func draw(state: BlastTaskState) {
        self.terminal.write(state.symbol, inColor: state.color)
    }

    func drawTask(
        state: BlastTaskState,
        task name: String,
        duration: ContinuousClock.Duration
    ) {
        self.terminal.write(state.symbol, inColor: state.color)
        self.terminal.write(" \(name)")
        self.terminal.write(" (\(duration.formatted(.blast)))", inColor: .white, bold: true)
        self.terminal.endLine()
    }

    func drawStats() {
        self.counts.validate()

        self.terminal.write("[", inColor: .white, bold: true)
        self.terminal.write("\(self.counts.completed)")
        self.terminal.write("/", inColor: .white, bold: true)
        self.terminal.write("\(self.counts.total)")
        self.terminal.write("] ", inColor: .white, bold: true)

        self.draw(state: .running)
        self.terminal.write(" \(self.counts.running), ")
        self.draw(state: .pending)
        self.terminal.write(" \(self.counts.pending), ")
        self.draw(state: .succeeded)
        self.terminal.write(" \(self.counts.succeeded), ")
        self.draw(state: .failed)
        self.terminal.write(" \(self.counts.failed), ")
        self.draw(state: .cancelled)
        self.terminal.write(" \(self.counts.cancelled), ")
        self.draw(state: .skipped)
        self.terminal.write(" \(self.counts.skipped)")
    }

    func draw() {
        self.drawStats()
        self.drawnLines += 1
        let tasks = self.tasks.values.filter { $0.state == .running }.sorted()
        for task in tasks {
            self.terminal.write("\n")
            self.draw(state: .running)
            self.terminal.write(" \(task.name)")
            self.drawnLines += 1
        }
        self.terminal.flush()
    }

    func complete(success: Bool) {
        self.clear()
        self.drawStats()
        self.terminal.endLine()
    }

    func clear() {
        guard self.drawnLines > 0 else { return }
        self.terminal.clearLine()
        for _ in 1..<self.drawnLines {
            self.terminal.moveCursor(up: 1)
            self.terminal.clearLine()
        }
        self.drawnLines = 0
    }
}
