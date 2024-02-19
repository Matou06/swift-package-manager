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
import class TSCBasic.LocalFileOutputByteStream
import protocol TSCBasic.WritableByteStream

enum BlastTerminal {
    static func isRunningUnderXcode() -> Bool {
        let xpcServiceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        return xpcServiceName?.localizedCaseInsensitiveContains("com.apple.dt.xcode") ?? false
    }

    static func isTTY(stream: WritableByteStream) -> Bool {
        guard let stream = stream as? LocalFileOutputByteStream else { return false }
        return TerminalController.isTTY(stream)
    }

    static func supportsRedrawing(stream: WritableByteStream) -> Bool {
        return Self.isTTY(stream: stream) && !Self.isRunningUnderXcode()
    }

    static func supportsColors(stream: WritableByteStream) -> Bool {
        if let cliColorForce = ProcessInfo.processInfo.environment["CLICOLOR_FORCE"],
           ["1", "yes", "true"].contains(cliColorForce) { return true}
        guard Self.isTTY(stream: stream) else { return false }
#if os(macOS)
        if let xpcServiceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
           xpcServiceName.localizedCaseInsensitiveContains("com.apple.dt.xcode") {
            return false
        }
#endif
        guard let term = ProcessInfo.processInfo.environment["TERM"],
              !["", "dumb", "cons25", "emacs"].contains(term) else { return false }
        return !Self.isRunningUnderXcode()
    }
}

