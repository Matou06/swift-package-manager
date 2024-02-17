//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(SwiftPMInternal)
import Basics
import Dispatch
import protocol Foundation.LocalizedError
import LLBuildManifest
import PackageModel
import SPMBuildCore
import SPMLLBuild

import protocol TSCBasic.OutputByteStream
import struct TSCBasic.RegEx
import class TSCBasic.ThreadSafeOutputByteStream

#if canImport(llbuildSwift)
typealias LLBuildBuildSystemDelegate = llbuildSwift.BuildSystemDelegate
#else
typealias LLBuildBuildSystemDelegate = llbuild.BuildSystemDelegate
#endif

/// Convenient llbuild build system delegate implementation
final class BuildOperationBuildSystemDelegateHandler {
    private let outputStream: ThreadSafeOutputByteStream
    private let progressAnimation: ProgressAnimationProtocol
    var commandFailureHandler: (() -> Void)?
    private let logLevel: Basics.Diagnostic.Severity
    private weak var delegate: SPMBuildCore.BuildSystemDelegate?
    private let buildSystem: SPMBuildCore.BuildSystem
    private let queue = DispatchQueue(label: "org.swift.swiftpm.build-delegate")
    private var taskTracker: CommandTaskTracker
    private var errorMessagesByTarget: [String: [String]] = [:]
    private let observabilityScope: ObservabilityScope
    private var cancelled: Bool = false

    /// Swift parsers keyed by llbuild command name.
    private var swiftParsers: [String: SwiftCompilerOutputParser] = [:]

    /// Buffer to accumulate non-swift output until command is finished
    private var nonSwiftMessageBuffers: [String: [UInt8]] = [:]

    /// The build execution context.
    private let buildExecutionContext: BuildExecutionContext

    init(
        buildSystem: SPMBuildCore.BuildSystem,
        buildExecutionContext: BuildExecutionContext,
        outputStream: OutputByteStream,
        progressAnimation: ProgressAnimationProtocol,
        logLevel: Basics.Diagnostic.Severity,
        observabilityScope: ObservabilityScope,
        delegate: SPMBuildCore.BuildSystemDelegate?
    ) {
        self.buildSystem = buildSystem
        self.buildExecutionContext = buildExecutionContext
        // FIXME: Implement a class convenience initializer that does this once they are supported
        // https://forums.swift.org/t/allow-self-x-in-class-convenience-initializers/15924
        self.outputStream = outputStream as? ThreadSafeOutputByteStream ?? ThreadSafeOutputByteStream(outputStream)
        self.progressAnimation = progressAnimation
        self.taskTracker = .init(progressAnimation: progressAnimation)
        self.logLevel = logLevel
        self.observabilityScope = observabilityScope
        self.delegate = delegate

        let swiftParsers = buildExecutionContext.buildDescription?.swiftCommands.mapValues { tool in
            SwiftCompilerOutputParser(targetName: tool.moduleName, delegate: self)
        } ?? [:]
        self.swiftParsers = swiftParsers

        self.taskTracker.onTaskProgressUpdateText = { progressText, _ in
            self.queue.async {
                self.delegate?.buildSystem(self.buildSystem, didUpdateTaskProgress: progressText)
            }
        }
    }
}

extension BuildOperationBuildSystemDelegateHandler {
    func buildStart(
        configuration: BuildConfiguration,
        action: String
    ) {
        queue.sync {
            self.progressAnimation.clear()
            self.outputStream.send("\(action) for \(configuration == .debug ? "debugging" : "production")...\n")
            self.outputStream.flush()
        }
    }

    func buildComplete(
        success: Bool,
        duration: DispatchTimeInterval,
        action: String,
        subsetDescriptor: String? = nil
    ) {
        let subsetString: String
        if let subsetDescriptor {
            subsetString = "of \(subsetDescriptor) "
        } else {
            subsetString = ""
        }

        queue.sync {
            self.progressAnimation.complete(success: success)
            if success {
                self.progressAnimation.clear()
                let message = cancelled ? "\(action) \(subsetString)cancelled!" : "\(action) \(subsetString)complete!"
                self.outputStream.send("\(message) (\(duration.descriptionInSeconds))\n")
                self.outputStream.flush()
            }
        }
    }
}

// MARK: llbuildSwift.BuildSystemDelegate
extension BuildOperationBuildSystemDelegateHandler: LLBuildBuildSystemDelegate {
    var fs: SPMLLBuild.FileSystem? { nil }

    func lookupTool(_ name: String) -> Tool? {
        switch name {
        case TestDiscoveryTool.name:
            return InProcessTool(buildExecutionContext, type: TestDiscoveryCommand.self)
        case TestEntryPointTool.name:
            return InProcessTool(buildExecutionContext, type: TestEntryPointCommand.self)
        case PackageStructureTool.name:
            return InProcessTool(buildExecutionContext, type: PackageStructureCommand.self)
        case CopyTool.name:
            return InProcessTool(buildExecutionContext, type: CopyCommand.self)
        case WriteAuxiliaryFile.name:
            return InProcessTool(buildExecutionContext, type: WriteAuxiliaryFileCommand.self)
        default:
            return nil
        }
    }

    func hadCommandFailure() {
        self.commandFailureHandler?()
    }

    func handleDiagnostic(_ diagnostic: SPMLLBuild.Diagnostic) {
        switch diagnostic.kind {
        case .note:
            self.observabilityScope.emit(info: diagnostic.message)
        case .warning:
            self.observabilityScope.emit(warning: diagnostic.message)
        case .error:
            self.observabilityScope.emit(error: diagnostic.message)
        @unknown default:
            self.observabilityScope.emit(info: diagnostic.message)
        }
    }

    func commandStatusChanged(_ command: SPMLLBuild.Command, kind: CommandStatusKind) {
        guard command.shouldShowStatus else { return }

        let targetName = self.swiftParsers[command.name]?.targetName
        let now = ContinuousClock.now

        queue.async {
            self.taskTracker.commandStatusChanged(
                command,
                kind: kind,
                targetName: targetName,
                time: now)
        }
    }

    func commandPreparing(_ command: SPMLLBuild.Command) {
        queue.async {
            self.delegate?.buildSystem(self.buildSystem, willStartCommand: BuildSystemCommand(command))
        }
    }

    func shouldCommandStart(_: SPMLLBuild.Command) -> Bool { true }

    func commandStarted(_ command: SPMLLBuild.Command) {
        guard command.shouldShowStatus else { return }

        let targetName = self.swiftParsers[command.name]?.targetName
        let now = ContinuousClock.now

        queue.async {
            self.delegate?.buildSystem(self.buildSystem, didStartCommand: BuildSystemCommand(command))

            if self.logLevel.isVerbose {
                self.progressAnimation.clear()
                self.outputStream.send("\(command.verboseDescription)\n")
                self.outputStream.flush()
            }

            self.taskTracker.commandStarted(
                command,
                targetName: targetName,
                time: now)
        }
    }

    func commandFinished(_ command: SPMLLBuild.Command, result: CommandResult) {
        guard command.shouldShowStatus else { return }

        let targetName = self.swiftParsers[command.name]?.targetName
        let now = ContinuousClock.now

        queue.async {
            if result == .cancelled {
                self.cancelled = true
                self.delegate?.buildSystemDidCancel(self.buildSystem)
            }

            self.delegate?.buildSystem(self.buildSystem, didFinishCommand: BuildSystemCommand(command))

            self.taskTracker.commandFinished(command, result: result, targetName: targetName, time: now)
        }
    }

    func commandHadError(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(error: message)
    }

    func commandHadNote(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(info: message)
    }

    func commandHadWarning(_ command: SPMLLBuild.Command, message: String) {
        self.observabilityScope.emit(warning: message)
    }

    func commandCannotBuildOutputDueToMissingInputs(
        _ command: SPMLLBuild.Command,
        output: BuildKey,
        inputs: [BuildKey]
    ) {
        self.observabilityScope.emit(.missingInputs(output: output, inputs: inputs))
    }

    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) {
        self.observabilityScope.emit(.multipleProducers(output: output, commands: commands))
    }

    func commandProcessStarted(_ command: SPMLLBuild.Command, process: ProcessHandle) {}

    func commandProcessHadError(_ command: SPMLLBuild.Command, process: ProcessHandle, message: String) {
        self.observabilityScope.emit(.commandError(command: command, message: message))
    }

    func commandProcessHadOutput(_ command: SPMLLBuild.Command, process: ProcessHandle, data: [UInt8]) {
        guard command.shouldShowStatus else { return }

        if let swiftParser = swiftParsers[command.name] {
            swiftParser.parse(bytes: data)
        } else {
            queue.async {
                self.nonSwiftMessageBuffers[command.name, default: []] += data
            }
        }
    }

    func commandProcessFinished(
        _ command: SPMLLBuild.Command,
        process: ProcessHandle,
        result: CommandExtendedResult
    ) {
        // FIXME: This should really happen at the command-level and is just a stopgap measure.
        let shouldFilterOutput = !self.logLevel.isVerbose && command.verboseDescription.hasPrefix("codesign ") && result.result != .failed
        queue.async {
            if let buffer = self.nonSwiftMessageBuffers[command.name], !shouldFilterOutput {
                self.progressAnimation.clear()
                self.outputStream.send(buffer)
                self.outputStream.flush()
                self.nonSwiftMessageBuffers[command.name] = nil
            }
        }

        switch result.result {
        case .cancelled:
            self.cancelled = true
            self.delegate?.buildSystemDidCancel(self.buildSystem)
        case .failed:
            // The command failed, so we queue up an asynchronous task to see if we have any error messages from the
            // target to provide advice about.
            queue.async {
                guard let target = self.swiftParsers[command.name]?.targetName else { return }
                guard let errorMessages = self.errorMessagesByTarget[target] else { return }
                for errorMessage in errorMessages {
                    // Emit any advice that's provided for each error message.
                    if let adviceMessage = self.buildExecutionContext.buildErrorAdviceProvider?.provideBuildErrorAdvice(
                        for: target,
                        command: command.name,
                        message: errorMessage
                    ) {
                        self.outputStream.send("note: \(adviceMessage)\n")
                        self.outputStream.flush()
                    }
                }
            }
        case .succeeded, .skipped:
            break
        @unknown default:
            break
        }
    }

    func cycleDetected(rules: [BuildKey]) {
        self.observabilityScope.emit(.cycleError(rules: rules))

        queue.async {
            self.delegate?.buildSystemDidDetectCycleInRules(self.buildSystem)
        }
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        false
    }

    /// Invoked right before running an action taken before building.
    func preparationStepStarted(_ name: String) {
        let now = ContinuousClock.now
        queue.async {
            self.taskTracker.buildPreparationStepStarted(name, time: now)
        }
    }

    /// Invoked when an action taken before building emits output.
    /// when verboseOnly is set to true, the output will only be printed in verbose logging mode
    func preparationStepHadOutput(_ name: String, output: String, verboseOnly: Bool) {
        queue.async {
            if !verboseOnly || self.logLevel.isVerbose {
                self.progressAnimation.clear()
                self.outputStream.send("\(output.spm_chomp())\n")
                self.outputStream.flush()
            }
        }
    }

    /// Invoked right after running an action taken before building. The result
    /// indicates whether the action succeeded, failed, or was cancelled.
    func preparationStepFinished(_ name: String, result: CommandResult) {
        let now = ContinuousClock.now
        queue.async {
            self.taskTracker.buildPreparationStepFinished(name, time: now)
        }
    }
}

// MARK: SwiftCompilerOutputParserDelegate
extension BuildOperationBuildSystemDelegateHandler: SwiftCompilerOutputParserDelegate {
    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didParse message: SwiftCompilerMessage) {
        let now = ContinuousClock.now

        queue.async {
            if self.logLevel.isVerbose, let text = message.verboseProgressText {
                self.progressAnimation.clear()
                self.outputStream.send("\(text)\n")
                self.outputStream.flush()
            }

            if let output = message.standardOutput {
                self.progressAnimation.clear()
                self.outputStream.send(output)
                self.outputStream.flush()

                // next we want to try and scoop out any errors from the output (if reasonable size, otherwise this
                // will be very slow), so they can later be passed to the advice provider in case of failure.
                if output.utf8.count < 1024 * 10 {
                    let regex = try! RegEx(pattern: #".*(error:[^\n]*)\n.*"#, options: .dotMatchesLineSeparators)
                    for match in regex.matchGroups(in: output) {
                        self.errorMessagesByTarget[parser.targetName] = (
                            self.errorMessagesByTarget[parser.targetName] ?? []
                        ) + [match[0]]
                    }
                }
            }

            self.taskTracker.swiftCompilerDidOutputMessage(
                message,
                targetName: parser.targetName,
                time: now)
        }
    }

    func swiftCompilerOutputParser(_ parser: SwiftCompilerOutputParser, didFailWith error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.observabilityScope.emit(.swiftCompilerOutputParsingError(message))
        self.commandFailureHandler?()
    }
}

/// Tracks tasks based on command status and swift compiler output.
private struct CommandTaskTracker {
    // FIXME: RAUHUL MERGE-BLOCKER plumb this through better somehow
    var progressAnimation: any ProgressAnimationProtocol2
    private var swiftTaskProgressTexts: [Int: String] = [:]
    /// The last task text before the task list was emptied.
    var onTaskProgressUpdateText: ((_ text: String, _ targetName: String?) -> Void)?

    init(progressAnimation: ProgressAnimationProtocol) {
        self.progressAnimation = progressAnimation as! ProgressAnimationProtocol2
    }

    mutating func commandStatusChanged(
        _ command: SPMLLBuild.Command,
        kind: CommandStatusKind,
        targetName: String?,
        time: ContinuousClock.Instant
    ) {
        let event: ProgressAnimation2TaskEvent
        switch kind {
        case .isScanning: event = .discovered
        case .isUpToDate: event = .completed(.skipped)
        case .isComplete: event = .completed(.succeeded)
        @unknown default:
            assertionFailure("unhandled command status kind \(kind) for command \(command)")
            return
        }
        let name = self.progressText(of: command, targetName: targetName)
        self.progressAnimation.update(
            task: .init(
                id: command.unstableId,
                name: name),
            event: event,
            at: time)
    }

    mutating func commandStarted(
        _ command: SPMLLBuild.Command,
        targetName: String?,
        time: ContinuousClock.Instant
    ) {
        let name = self.progressText(of: command, targetName: targetName)
        self.onTaskProgressUpdateText?(name, targetName)
        self.progressAnimation.update(
            task: .init(
                id: command.unstableId,
                name: name),
            event: .started,
            at: time)
    }

    mutating func commandFinished(
        _ command: SPMLLBuild.Command,
        result: CommandResult,
        targetName: String?,
        time: ContinuousClock.Instant
    ) {
        let name = self.progressText(of: command, targetName: targetName)
        self.onTaskProgressUpdateText?(name, targetName)
        let event: ProgressAnimation2TaskCompletionEvent
        switch result {
        case .succeeded: event = .succeeded
        case .failed: event = .failed
        case .cancelled: event = .cancelled
        case .skipped: event = .skipped
        @unknown default:
            assertionFailure("unhandled command result \(result) for command \(command)")
            return
        }
        self.progressAnimation.update(
            task: .init(
                id: command.unstableId,
                name: name),
            event: .completed(event),
            at: time)
    }

    mutating func swiftCompilerDidOutputMessage(
        _ message: SwiftCompilerMessage,
        targetName: String,
        time: ContinuousClock.Instant
    ) {
        switch message.kind {
        case .began(let info):
            if let task = self.progressText(of: message, targetName: targetName) {
                self.swiftTaskProgressTexts[info.pid] = task
//                self.progressAnimation.discovered(task: task, id: info.pid, at: time)
//                self.progressAnimation.running(task: task, id: info.pid, at: time)
            }

        case .finished(let info):
            if let task = self.swiftTaskProgressTexts[info.pid] {
                swiftTaskProgressTexts[info.pid] = nil
//                self.progressAnimation.succeeded(task: task, id: info.pid, at: time)
            }

        case .unparsableOutput, .signalled, .skipped:
            break
        }
    }

    func progressText(of command: SPMLLBuild.Command, targetName: String?) -> String {
        // Transforms descriptions like "Linking ./.build/x86_64-apple-macosx/debug/foo" into "Linking foo".
        if let firstSpaceIndex = command.description.firstIndex(of: " "),
           let lastDirectorySeparatorIndex = command.description.lastIndex(of: "/")
        {
            let action = command.description[..<firstSpaceIndex]
            let fileNameStartIndex = command.description.index(after: lastDirectorySeparatorIndex)
            let fileName = command.description[fileNameStartIndex...]

            if let targetName {
                return "\(action) \(targetName) \(fileName)"
            } else {
                return "\(action) \(fileName)"
            }
        } else {
            return command.description
        }
    }

    private func progressText(of message: SwiftCompilerMessage, targetName: String) -> String? {
        if case .began(let info) = message.kind {
            switch message.name {
            case "compile":
                if let sourceFile = info.inputs.first {
                    let sourceFilePath = try! AbsolutePath(validating: sourceFile)
                    return "Compiling \(targetName) \(sourceFilePath.components.last!)"
                }
            case "link":
                return "Linking \(targetName)"
            case "merge-module":
                return "Merging module \(targetName)"
            case "emit-module":
                return "Emitting module \(targetName)"
            case "generate-dsym":
                return "Generating \(targetName) dSYM"
            case "generate-pch":
                return "Generating \(targetName) PCH"
            default:
                break
            }
        }

        return nil
    }

    mutating func buildPreparationStepStarted(
        _ name: String,
        time: ContinuousClock.Instant
    ) {
        self.progressAnimation.update(
            task: .init(id: name.hash, name: name),
            event: .discovered,
            at: time)
        self.progressAnimation.update(
            task: .init(id: name.hash, name: name),
            event: .started,
            at: time)
    }

    mutating func buildPreparationStepFinished(
        _ name: String,
        time: ContinuousClock.Instant
    ) {
        self.progressAnimation.update(
            task: .init(id: name.hash, name: name),
            event: .completed(.succeeded),
            at: time)
    }
}

extension Basics.Diagnostic {
    fileprivate static func cycleError(rules: [BuildKey]) -> Self {
        .error("build cycle detected: " + rules.map(\.key).joined(separator: ", "))
    }

    fileprivate static func missingInputs(output: BuildKey, inputs: [BuildKey]) -> Self {
        let missingInputs = inputs.map(\.key).joined(separator: ", ")
        return .error("couldn't build \(output.key) because of missing inputs: \(missingInputs)")
    }

    fileprivate static func multipleProducers(output: BuildKey, commands: [SPMLLBuild.Command]) -> Self {
        let producers = commands.map(\.description).joined(separator: ", ")
        return .error("couldn't build \(output.key) because of multiple producers: \(producers)")
    }

    fileprivate static func commandError(command: SPMLLBuild.Command, message: String) -> Self {
        .error("command \(command.description) failed: \(message)")
    }

    fileprivate static func swiftCompilerOutputParsingError(_ error: String) -> Self {
        .error("failed parsing the Swift compiler output: \(error)")
    }
}

extension SPMLLBuild.Command {
    var unstableId: Int {
        var hasher = Hasher()
        hasher.combine(self)
        return hasher.finalize()
    }
}
