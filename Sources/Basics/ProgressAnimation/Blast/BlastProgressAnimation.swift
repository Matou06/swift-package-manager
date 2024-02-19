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
import class TSCBasic.BufferedOutputByteStream
import protocol TSCBasic.WritableByteStream

extension ProgressAnimation {
    /// A modern progress animation that adapts to the provided output stream.
    @_spi(SwiftPMInternal)
    public static func blast(
        stream: WritableByteStream,
        verbose: Bool
    ) -> some ProgressAnimationProtocol {
        _ = TerminalController(stream: stream)
        return BlastProgressAnimation(
            stream: stream,
            redraw: BlastTerminal.supportsRedrawing(stream: stream) && !verbose,
            colorize: BlastTerminal.supportsColors(stream: stream))
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
    var id: Int { self.underlying.id }
    var underlying: ProgressAnimation2Task
    var start: ContinuousClock.Instant
    var state: ProgressAnimation2TaskEvent

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.start < rhs.start }
}

class BlastProgressAnimation {
    // Dependencies
    var terminal: BlastTerminalController

    // Configuration
    var redraw: Bool

    // Internal state
    var counts: ProgressAnimation2TaskCounts
    var drawnLines: Int
    var tasks: [Int: BlastTask]

    init(stream: WritableByteStream, redraw: Bool, colorize: Bool) {
        self.terminal = BlastTerminalController(stream: stream, colorize: colorize)
        self.redraw = redraw
        self.counts = .zero
        self.drawnLines = 0
        self.tasks = [:]
    }
}

extension BlastProgressAnimation: ProgressAnimationProtocol {
    func update(step: Int, total: Int, text: String) { }
    func complete(success: Bool) { self._complete() }
}

extension BlastProgressAnimation: ProgressAnimationProtocol2 {
    func update(task: ProgressAnimation2Task, event: ProgressAnimation2TaskEvent, at time: ContinuousClock.Instant) {
        switch event {
        case .discovered:
            guard self.tasks[task.id] == nil else {
                assertionFailure("unexpected duplicate discovery of task \(task)")
                return
            }

            self.tasks[task.id] = BlastTask(underlying: task, start: time, state: .discovered)
            self.counts.taskDiscovered()

            self._clear()
            self._draw()
            self._flush()

        case .started:
            guard var task = self.tasks[task.id] else {
                assertionFailure("unexpected start of unknown task \(task)")
                return
            }
            guard task.state == .discovered else {
                assertionFailure("unexpected restart of task \(task) in state: \(task.state)")
                return
            }

            task.state = .started
            task.start = time
            self.tasks[task.id] = task
            self.counts.taskStarted()

            self._clear()
            self._draw()
            self._flush()

        case .completed(let completionEvent):
            guard var task = self.tasks[task.id] else {
                assertionFailure("unexpected \(event) of unknown task \(task)")
                return
            }
            switch task.state {
            // Skipped is special, tasks can be skipped and never started
            case .discovered where completionEvent == .skipped:
                task.state = event
                self.tasks[task.id] = task
                self.counts.taskSkipped()

                let duration = task.start.duration(to: time)
                self._clear()
                self._draw(task: task, duration: duration)
                self._draw()
                self._flush()

            case .discovered:
                assertionFailure("unexpected \(event) of not started task \(task)")
                return

            case .started:
                task.state = event
                self.tasks[task.id] = task
                self.counts.taskCompleted(completionEvent)

                let duration = task.start.duration(to: time)
                self._clear()
                self._draw(task: task, duration: duration)
                self._draw()
                self._flush()

            case .completed:
                // Already accounted for
                return
            }
        }
    }

    func draw() {
        self._draw()
        self._flush()
    }

    func complete() {
        self._complete()
        self._flush()
    }

    func clear() {
        self._clear()
        self._flush()
    }
}

extension BlastProgressAnimation {
    func _draw(event: ProgressAnimation2TaskEvent) {
        if event.color.1 {
            self.terminal.text(styles: .brightForegroundColor(event.color.0))
        } else {
            self.terminal.text(styles: .foregroundColor(event.color.0))
        }
        self.terminal.write(event.symbol)
    }

    func _draw(task: BlastTask, duration: ContinuousClock.Duration?) {
        self._draw(event: task.state)
        self.terminal.text(styles: .reset)
        self.terminal.write(" \(task.underlying.name)")
        if let duration {
            self.terminal.text(styles: .foregroundColor(.white), .bold)
            self.terminal.write(" (\(duration.formatted(.blast)))")
            self.terminal.text(styles: .reset)
        }
        self.terminal.newLine()
    }

    func _draw(state: ProgressAnimation2TaskEvent, count: Int, last: Bool) {
        self._draw(event: state)
        self.terminal.write(" \(count)")
        if !last {
            self.terminal.text(styles: .reset)
            self.terminal.write(", ")
        }
    }

    func _drawStates() {
        self.terminal.text(styles: .foregroundColor(.white), .bold)
        self.terminal.write("[\(self.counts.completed)/\(self.counts.total)] ")
        self.terminal.text(styles: .reset)
        self._draw(state: .started, count: self.counts.running, last: false)
        self._draw(state: .discovered, count: self.counts.pending, last: false)
        self._draw(state: .completed(.succeeded), count: self.counts.succeeded, last: false)
        self._draw(state: .completed(.failed), count: self.counts.failed, last: false)
        self._draw(state: .completed(.cancelled), count: self.counts.cancelled, last: false)
        self._draw(state: .completed(.skipped), count: self.counts.skipped, last: true)
        self.terminal.text(styles: .reset)
    }

    func _draw() {
        guard self.redraw else { return }
        assert(self.drawnLines == 0)
        let tasks = self.tasks.values.filter { $0.state == .started }.sorted()
        for task in tasks {
            self._draw(task: task, duration: nil)
            self.drawnLines += 1
        }
        self._drawStates()
        self.drawnLines += 1
    }

    func _complete() {
        self._clear()
        self._drawStates()
        self.terminal.newLine()
    }

    func _clear() {
        guard self.redraw else { return }
        guard self.drawnLines > 0 else { return }
        self.terminal.eraseLine(.entire)
        self.terminal.carriageReturn()
        for _ in 1..<self.drawnLines {
            self.terminal.moveCursorPrevious(lines: 1)
            self.terminal.eraseLine(.entire)
        }
        self.drawnLines = 0
    }

    func _flush() {
        self.terminal.flush()
    }
}
