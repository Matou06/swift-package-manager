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
import Foundation
import LLBuildManifest
import PackageModel
import SPMBuildCore
import SPMLLBuild

import struct TSCBasic.ByteString
import struct TSCBasic.Format
import class TSCBasic.LocalFileOutputByteStream
import protocol TSCBasic.OutputByteStream
import enum TSCBasic.ProcessEnv
import struct TSCBasic.RegEx
import class TSCBasic.ThreadSafeOutputByteStream

import class TSCUtility.IndexStore
import class TSCUtility.IndexStoreAPI

class CustomLLBuildCommand: SPMLLBuild.ExternalCommand {
    let context: BuildExecutionContext

    required init(_ context: BuildExecutionContext) {
        self.context = context
    }

    func getSignature(_: SPMLLBuild.Command) -> [UInt8] {
        []
    }

    func execute(
        _: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        fatalError("subclass responsibility")
    }
}

extension IndexStore.TestCaseClass.TestMethod {
    fileprivate var allTestsEntry: String {
        let baseName = name.hasSuffix("()") ? String(name.dropLast(2)) : name

        return "(\"\(baseName)\", \(isAsync ? "asyncTest(\(baseName))" : baseName))"
    }
}

final class TestDiscoveryCommand: CustomLLBuildCommand, TestBuildCommand {
    private func write(
        tests: [IndexStore.TestCaseClass],
        forModule module: String,
        fileSystem: Basics.FileSystem,
        path: AbsolutePath
    ) throws {

        let testsByClassNames = Dictionary(grouping: tests, by: { $0.name }).sorted(by: { $0.key < $1.key })

        var content = "import XCTest\n"
        content += "@testable import \(module)\n"

        for iterator in testsByClassNames {
            // 'className' provides uniqueness for derived class.
            let className = iterator.key
            let testMethods = iterator.value.flatMap(\.testMethods)
            content +=
                #"""

                fileprivate extension \#(className) {
                    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                    static let __allTests__\#(className) = [
                        \#(testMethods.map { $0.allTestsEntry }.joined(separator: ",\n        "))
                    ]
                }

                """#
        }

        content +=
        #"""
        @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
        func __\#(module)__allTests() -> [XCTestCaseEntry] {
            return [
                \#(testsByClassNames.map { "testCase(\($0.key).__allTests__\($0.key))" }
                    .joined(separator: ",\n        "))
            ]
        }
        """#

        try fileSystem.writeFileContents(path, string: content)
    }

    private func execute(fileSystem: Basics.FileSystem, tool: TestDiscoveryTool) throws {
        let outputs = tool.outputs.compactMap { try? AbsolutePath(validating: $0.name) }

        switch self.context.productsBuildParameters.testingParameters.library {
        case .swiftTesting:
            for file in outputs {
                try fileSystem.writeIfChanged(path: file, string: "")
            }
        case .xctest:
            let index = self.context.productsBuildParameters.indexStore
            let api = try self.context.indexStoreAPI.get()
            let store = try IndexStore.open(store: TSCAbsolutePath(index), api: api)

            // FIXME: We can speed this up by having one llbuild command per object file.
            let tests = try store.listTests(in: tool.inputs.map { try TSCAbsolutePath(AbsolutePath(validating: $0.name)) })

            let testsByModule = Dictionary(grouping: tests, by: { $0.module.spm_mangledToC99ExtendedIdentifier() })

            // Find the main file path.
            guard let mainFile = outputs.first(where: { path in
                path.basename == TestDiscoveryTool.mainFileName
            }) else {
                throw InternalError("main output (\(TestDiscoveryTool.mainFileName)) not found")
            }

            // Write one file for each test module.
            //
            // We could write everything in one file but that can easily run into type conflicts due
            // in complex packages with large number of test targets.
            for file in outputs where file != mainFile {
                // FIXME: This is relying on implementation detail of the output but passing the
                // the context all the way through is not worth it right now.
                let module = file.basenameWithoutExt.spm_mangledToC99ExtendedIdentifier()

                guard let tests = testsByModule[module] else {
                    // This module has no tests so just write an empty file for it.
                    try fileSystem.writeFileContents(file, bytes: "")
                    continue
                }
                try write(
                    tests: tests,
                    forModule: module,
                    fileSystem: fileSystem,
                    path: file
                )
            }

            let testsKeyword = tests.isEmpty ? "let" : "var"

            // Write the main file.
            let stream = try LocalFileOutputByteStream(mainFile)

            stream.send(
                #"""
                import XCTest

                @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                public func __allDiscoveredTests() -> [XCTestCaseEntry] {
                    \#(testsKeyword) tests = [XCTestCaseEntry]()

                    \#(testsByModule.keys.map { "tests += __\($0)__allTests()" }.joined(separator: "\n    "))

                    return tests
                }
                """#
            )

            stream.flush()
        }
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testDiscoveryCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

extension TestEntryPointTool {
    public static func mainFileName(for library: BuildParameters.Testing.Library) -> String {
        "runner-\(library).swift"
    }
}

final class TestEntryPointCommand: CustomLLBuildCommand, TestBuildCommand {
    private func execute(fileSystem: Basics.FileSystem, tool: TestEntryPointTool) throws {
        let outputs = tool.outputs.compactMap { try? AbsolutePath(validating: $0.name) }

        // Find the main output file
        let mainFileName = TestEntryPointTool.mainFileName(
            for: self.context.productsBuildParameters.testingParameters.library
        )
        guard let mainFile = outputs.first(where: { path in
            path.basename == mainFileName
        }) else {
            throw InternalError("main file output (\(mainFileName)) not found")
        }

        // Write the main file.
        let stream = try LocalFileOutputByteStream(mainFile)

        switch self.context.productsBuildParameters.testingParameters.library {
        case .swiftTesting:
            stream.send(
                #"""
                #if canImport(Testing)
                import Testing
                #endif

                @main struct Runner {
                    static func main() async {
                #if canImport(Testing)
                        await Testing.__swiftPMEntryPoint() as Never
                #endif
                    }
                }
                """#
            )
        case .xctest:
            // Find the inputs, which are the names of the test discovery module(s)
            let inputs = tool.inputs.compactMap { try? AbsolutePath(validating: $0.name) }
            let discoveryModuleNames = inputs.map(\.basenameWithoutExt)

            let testObservabilitySetup: String
            let buildParameters = self.context.productsBuildParameters
            if buildParameters.testingParameters.experimentalTestOutput && buildParameters.triple.supportsTestSummary {
                testObservabilitySetup = "_ = SwiftPMXCTestObserver()\n"
            } else {
                testObservabilitySetup = ""
            }

            stream.send(
                #"""
                \#(generateTestObservationCode(buildParameters: buildParameters))

                import XCTest
                \#(discoveryModuleNames.map { "import \($0)" }.joined(separator: "\n"))

                @main
                @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
                struct Runner {
                    static func main() {
                        \#(testObservabilitySetup)
                        #if os(WASI)
                        // FIXME: On WASI, XCTest uses `Task` based waiting not to block the whole process, so
                        // the `XCTMain` call can return the control and the process will exit by `exit(0)` later.
                        // This is a workaround until we have WASI threads or swift-testing, which does not block threads.
                        XCTMain(__allDiscoveredTests())
                        #else
                        XCTMain(__allDiscoveredTests()) as Never
                        #endif
                    }
                }
                """#
            )
        }

        stream.flush()
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.testEntryPointCommands[command.name] else {
                throw InternalError("command \(command.name) not registered")
            }
            try execute(fileSystem: self.context.fileSystem, tool: tool)
            return true
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
    }
}

private protocol TestBuildCommand {}

final class InProcessTool: Tool {
    let context: BuildExecutionContext
    let type: CustomLLBuildCommand.Type

    init(_ context: BuildExecutionContext, type: CustomLLBuildCommand.Type) {
        self.context = context
        self.type = type
    }

    func createCommand(_: String) -> ExternalCommand? {
        type.init(self.context)
    }
}

/// Contains the description of the build that is needed during the execution.
public struct BuildDescription: Codable {
    public typealias CommandName = String
    public typealias TargetName = String
    public typealias CommandLineFlag = String

    /// The Swift compiler invocation targets.
    let swiftCommands: [LLBuildManifest.CmdName: SwiftCompilerTool]

    /// The Swift compiler frontend invocation targets.
    let swiftFrontendCommands: [LLBuildManifest.CmdName: SwiftFrontendTool]

    /// The map of test discovery commands.
    let testDiscoveryCommands: [LLBuildManifest.CmdName: TestDiscoveryTool]

    /// The map of test entry point commands.
    let testEntryPointCommands: [LLBuildManifest.CmdName: TestEntryPointTool]

    /// The map of copy commands.
    let copyCommands: [LLBuildManifest.CmdName: CopyTool]

    /// The map of write commands.
    let writeCommands: [LLBuildManifest.CmdName: WriteAuxiliaryFile]

    /// A flag that indicates this build should perform a check for whether targets only import
    /// their explicitly-declared dependencies
    let explicitTargetDependencyImportCheckingMode: BuildParameters.TargetDependencyImportCheckingMode

    /// Every target's set of dependencies.
    let targetDependencyMap: [TargetName: [TargetName]]

    /// A full swift driver command-line invocation used to dependency-scan a given Swift target
    let swiftTargetScanArgs: [TargetName: [CommandLineFlag]]

    /// A set of all targets with generated source
    let generatedSourceTargetSet: Set<TargetName>

    /// The built test products.
    public let builtTestProducts: [BuiltTestProduct]

    /// Distilled information about any plugins defined in the package.
    let pluginDescriptions: [PluginDescription]

    public init(
        plan: BuildPlan,
        swiftCommands: [LLBuildManifest.CmdName: SwiftCompilerTool],
        swiftFrontendCommands: [LLBuildManifest.CmdName: SwiftFrontendTool],
        testDiscoveryCommands: [LLBuildManifest.CmdName: TestDiscoveryTool],
        testEntryPointCommands: [LLBuildManifest.CmdName: TestEntryPointTool],
        copyCommands: [LLBuildManifest.CmdName: CopyTool],
        writeCommands: [LLBuildManifest.CmdName: WriteAuxiliaryFile],
        pluginDescriptions: [PluginDescription]
    ) throws {
        self.swiftCommands = swiftCommands
        self.swiftFrontendCommands = swiftFrontendCommands
        self.testDiscoveryCommands = testDiscoveryCommands
        self.testEntryPointCommands = testEntryPointCommands
        self.copyCommands = copyCommands
        self.writeCommands = writeCommands
        self.explicitTargetDependencyImportCheckingMode = plan.destinationBuildParameters.driverParameters
            .explicitTargetDependencyImportCheckingMode
        self.targetDependencyMap = try plan.targets.reduce(into: [TargetName: [TargetName]]()) { partial, targetBuildDescription in
            let deps = try targetBuildDescription.target.recursiveDependencies(
                satisfying: plan.buildParameters(for: targetBuildDescription.target).buildEnvironment
            )
                .compactMap(\.target).map(\.c99name)
            partial[targetBuildDescription.target.c99name] = deps
        }
        var targetCommandLines: [TargetName: [CommandLineFlag]] = [:]
        var generatedSourceTargets: [TargetName] = []
        for (targetID, description) in plan.targetMap {
            guard case .swift(let desc) = description, let target = plan.graph.allTargets[targetID] else {
                continue
            }
            let buildParameters = plan.buildParameters(for: target)
            targetCommandLines[target.c99name] =
                try desc.emitCommandLine(scanInvocation: true) + [
                    "-driver-use-frontend-path", buildParameters.toolchain.swiftCompilerPath.pathString
                ]
            if case .discovery = desc.testTargetRole {
                generatedSourceTargets.append(target.c99name)
            }
        }
        generatedSourceTargets.append(
            contentsOf: plan.graph.allTargets.filter { $0.type == .plugin }
                .map(\.c99name)
        )
        self.swiftTargetScanArgs = targetCommandLines
        self.generatedSourceTargetSet = Set(generatedSourceTargets)
        self.builtTestProducts = try plan.buildProducts.filter { $0.product.type == .test }.map { desc in
            return try BuiltTestProduct(
                productName: desc.product.name,
                binaryPath: desc.binaryPath,
                packagePath: desc.package.path,
                library: desc.buildParameters.testingParameters.library
            )
        }
        self.pluginDescriptions = pluginDescriptions
    }

    public func write(fileSystem: Basics.FileSystem, path: AbsolutePath) throws {
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(self)
        try fileSystem.writeFileContents(path, bytes: ByteString(data))
    }

    public static func load(fileSystem: Basics.FileSystem, path: AbsolutePath) throws -> BuildDescription {
        let contents: Data = try fileSystem.readFileContents(path)
        let decoder = JSONDecoder.makeWithDefaults()
        return try decoder.decode(BuildDescription.self, from: contents)
    }
}

/// A provider of advice about build errors.
public protocol BuildErrorAdviceProvider {
    /// Invoked after a command fails and an error message is detected in the output. Should return a string containing
    /// advice or additional information, if any, based on the build plan.
    func provideBuildErrorAdvice(for target: String, command: String, message: String) -> String?
}

/// The context available during build execution.
public final class BuildExecutionContext {
    /// Build parameters for products.
    let productsBuildParameters: BuildParameters

    /// Build parameters for build tools.
    let toolsBuildParameters: BuildParameters

    /// The build description.
    ///
    /// This is optional because we might not have a valid build description when performing the
    /// build for PackageStructure target.
    let buildDescription: BuildDescription?

    /// The package structure delegate.
    let packageStructureDelegate: PackageStructureDelegate

    /// Optional provider of build error resolution advice.
    let buildErrorAdviceProvider: BuildErrorAdviceProvider?

    let fileSystem: Basics.FileSystem

    let observabilityScope: ObservabilityScope

    public init(
        productsBuildParameters: BuildParameters,
        toolsBuildParameters: BuildParameters,
        buildDescription: BuildDescription? = nil,
        fileSystem: Basics.FileSystem,
        observabilityScope: ObservabilityScope,
        packageStructureDelegate: PackageStructureDelegate,
        buildErrorAdviceProvider: BuildErrorAdviceProvider? = nil
    ) {
        self.productsBuildParameters = productsBuildParameters
        self.toolsBuildParameters = toolsBuildParameters
        self.buildDescription = buildDescription
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
        self.packageStructureDelegate = packageStructureDelegate
        self.buildErrorAdviceProvider = buildErrorAdviceProvider
    }

    // MARK: - Private

    private var indexStoreAPICache = ThreadSafeBox<Result<IndexStoreAPI, Error>>()

    /// Reference to the index store API.
    var indexStoreAPI: Result<IndexStoreAPI, Error> {
        self.indexStoreAPICache.memoize {
            do {
                #if os(Windows)
                // The library's runtime component is in the `bin` directory on
                // Windows rather than the `lib` directory as on Unix.  The `lib`
                // directory contains the import library (and possibly static
                // archives) which are used for linking.  The runtime component is
                // not (necessarily) part of the SDK distributions.
                //
                // NOTE: the library name here `libIndexStore.dll` is technically
                // incorrect as per the Windows naming convention.  However, the
                // library is currently installed as `libIndexStore.dll` rather than
                // `IndexStore.dll`.  In the future, this may require a fallback
                // search, preferring `IndexStore.dll` over `libIndexStore.dll`.
                let indexStoreLib = toolsBuildParameters.toolchain.swiftCompilerPath
                    .parentDirectory
                    .appending("libIndexStore.dll")
                #else
                let ext = toolsBuildParameters.triple.dynamicLibraryExtension
                let indexStoreLib = try toolsBuildParameters.toolchain.toolchainLibDir
                    .appending("libIndexStore" + ext)
                #endif
                return try .success(IndexStoreAPI(dylib: TSCAbsolutePath(indexStoreLib)))
            } catch {
                return .failure(error)
            }
        }
    }
}

final class WriteAuxiliaryFileCommand: CustomLLBuildCommand {
    override func getSignature(_ command: SPMLLBuild.Command) -> [UInt8] {
        guard let buildDescription = self.context.buildDescription else {
            self.context.observabilityScope.emit(error: "unknown build description")
            return []
        }
        guard let tool = buildDescription.writeCommands[command.name] else {
            self.context.observabilityScope.emit(error: "command \(command.name) not registered")
            return []
        }

        do {
            let encoder = JSONEncoder.makeWithDefaults()
            var hash = Data()
            hash += try encoder.encode(tool.inputs)
            hash += try encoder.encode(tool.outputs)
            return [UInt8](hash)
        } catch {
            self.context.observabilityScope.emit(error: "getSignature() failed: \(error.interpolationDescription)")
            return []
        }
    }

    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        let outputFilePath: AbsolutePath
        let tool: WriteAuxiliaryFile!

        do {
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let _tool = buildDescription.writeCommands[command.name] else {
                throw StringError("command \(command.name) not registered")
            }
            tool = _tool

            guard let output = tool.outputs.first, output.kind == .file else {
                throw StringError("invalid output path")
            }
            outputFilePath = try AbsolutePath(validating: output.name)
        } catch {
            self.context.observabilityScope.emit(error: "failed to write auxiliary file: \(error.interpolationDescription)")
            return false
        }

        do {
            try self.context.fileSystem.writeIfChanged(path: outputFilePath, string: getFileContents(tool: tool))
            return true
        } catch {
            self.context.observabilityScope.emit(error: "failed to write auxiliary file '\(outputFilePath.pathString)': \(error.interpolationDescription)")
            return false
        }
    }

    func getFileContents(tool: WriteAuxiliaryFile) throws -> String {
        guard tool.inputs.first?.kind == .virtual, let generatedFileType = tool.inputs.first?.name.dropFirst().dropLast() else {
            throw StringError("invalid inputs")
        }

        for fileType in WriteAuxiliary.fileTypes {
            if generatedFileType == fileType.name {
                return try fileType.getFileContents(inputs: Array(tool.inputs.dropFirst()))
            }
        }

        throw InternalError("unhandled generated file type '\(generatedFileType)'")
    }
}

public protocol PackageStructureDelegate {
    func packageStructureChanged() -> Bool
}

final class PackageStructureCommand: CustomLLBuildCommand {
    override func getSignature(_: SPMLLBuild.Command) -> [UInt8] {
        let encoder = JSONEncoder.makeWithDefaults()
        // Include build parameters and process env in the signature.
        var hash = Data()
        hash += try! encoder.encode(self.context.productsBuildParameters)
        hash += try! encoder.encode(self.context.toolsBuildParameters)
        hash += try! encoder.encode(ProcessEnv.vars)
        return [UInt8](hash)
    }

    override func execute(
        _: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        self.context.packageStructureDelegate.packageStructureChanged()
    }
}

final class CopyCommand: CustomLLBuildCommand {
    override func execute(
        _ command: SPMLLBuild.Command,
        _: SPMLLBuild.BuildSystemCommandInterface
    ) -> Bool {
        do {
            // This tool will never run without the build description.
            guard let buildDescription = self.context.buildDescription else {
                throw InternalError("unknown build description")
            }
            guard let tool = buildDescription.copyCommands[command.name] else {
                throw StringError("command \(command.name) not registered")
            }

            let input = try AbsolutePath(validating: tool.inputs[0].name)
            let output = try AbsolutePath(validating: tool.outputs[0].name)
            try self.context.fileSystem.createDirectory(output.parentDirectory, recursive: true)
            try self.context.fileSystem.removeFileTree(output)
            try self.context.fileSystem.copy(from: input, to: output)
        } catch {
            self.context.observabilityScope.emit(error)
            return false
        }
        return true
    }
}

extension SwiftCompilerMessage {
    var verboseProgressText: String? {
        switch kind {
        case .began(let info):
            return ([info.commandExecutable] + info.commandArguments).joined(separator: " ")
        case .skipped, .finished, .signalled, .unparsableOutput:
            return nil
        }
    }

    var standardOutput: String? {
        switch kind {
        case .finished(let info),
             .signalled(let info):
            return info.output
        case .unparsableOutput(let output):
            return output
        case .skipped, .began:
            return nil
        }
    }
}

extension BuildSystemCommand {
    init(_ command: SPMLLBuild.Command) {
        self.init(
            name: command.name,
            description: command.description,
            verboseDescription: command.verboseDescription
        )
    }
}
