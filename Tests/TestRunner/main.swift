import Darwin
import Foundation
import LiteTermCore

@main
struct LiteTermCoreTestRunner {
    static func main() async {
        var failures: [String] = []

        if CommandLine.arguments.contains("--remote-output-sanitizer") {
            checkRemoteOutputSanitization(&failures)
            finish(failures, passingCheckCount: 1)
            return
        }

        if CommandLine.arguments.contains("--host-credential-transactions") {
            checkHostCredentialTransactions(&failures)
            finish(failures, passingCheckCount: 1)
            return
        }

        if CommandLine.arguments.contains("--ssh-state") {
            checkSSHConnectionStateAndReconnect(&failures)
            finish(failures, passingCheckCount: 1)
            return
        }

        checkHistoryDropsOldestLine(&failures)
        checkHistoryClear(&failures)
        checkZeroHistoryLimit(&failures)
        checkOversizedHistoryLimit(&failures)
        checkOversizedHistoryEntry(&failures)
        checkControlLettersAndBracket(&failures)
        checkControlUppercasing(&failures)
        checkUnsupportedControlCharacters(&failures)
        checkShortcutInputReducer(&failures)
        checkQuotedShellPath(&failures)
        checkShellArityRejection(&failures)
        checkExactShellCommandSet(&failures)
        checkSymlinkedShellPathIsRejected(&failures)
        checkWorkspaceVirtualPaths(&failures)
        await checkLocalShellFileOperations(&failures)
        await checkLocalShellEditorClearAndSizeLimit(&failures)
        await checkLocalShellDirectoryEditAndEmptyCat(&failures)
        await checkInjectedFileAccessBoundary(&failures)
        checkRemoteOutputSanitization(&failures)
        checkLocalTerminalInputOrdering(&failures)
        checkLocalTerminalInputBound(&failures)
        await checkCoordinatedPathInspection(&failures)
        failures.append(contentsOf: await checkLocalOperationQueue())
        checkHostRepository(&failures)
        checkKnownHostPolicy(&failures)
        checkReconnectPolicy(&failures)
        checkHostCredentialTransactions(&failures)

        checkSSHConnectionStateAndReconnect(&failures)
        await checkAcceptanceFlow(&failures)

        finish(failures, passingCheckCount: 29)
    }

    private static func checkHistoryDropsOldestLine(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.append("two")
        history.append("three")
        expect(history.lines == ["two", "three"], "history retains the newest lines", &failures)
    }

    private static func checkHistoryClear(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 2)
        history.append("one")
        history.clear()
        expect(history.lines == [], "history clear removes all lines", &failures)
    }

    private static func checkZeroHistoryLimit(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 0)
        history.append("one")
        expect(history.lines == [], "zero history limit retains no lines", &failures)
    }

    private static func checkOversizedHistoryLimit(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 10_000)

        for index in 0...200 {
            history.append("\(index)")
        }

        expect(history.lines.count == 200, "oversized history limit is capped at 200 lines", &failures)
        expect(history.lines.first == "1", "oversized history drops its oldest line", &failures)
        expect(history.lines.last == "200", "oversized history retains its newest line", &failures)
    }

    private static func checkOversizedHistoryEntry(_ failures: inout [String]) {
        var history = TerminalHistory(limit: 2)
        history.append(String(repeating: "a", count: 16_385))
        expect(
            history.lines.first?.utf8.count == 16_384,
            "one history entry is bounded to 16 KiB",
            &failures
        )

        var byteBounded = TerminalHistory(limit: 10, totalByteLimit: 10)
        byteBounded.append("12345")
        byteBounded.append("67890")
        byteBounded.append("abc")
        expect(byteBounded.lines == ["67890", "abc"], "history drops whole oldest lines at its total byte budget", &failures)
        expect(byteBounded.totalByteCount == 8, "history accounts for retained UTF-8 bytes", &failures)
        expect(byteBounded.previous() == "abc", "history Up selects the newest command", &failures)
        expect(byteBounded.previous() == "67890", "repeated history Up selects the older command", &failures)
        expect(byteBounded.next() == "abc", "history Down selects the newer command", &failures)
        expect(byteBounded.next() == "", "history Down returns to an empty command line", &failures)
    }

    private static func checkControlLettersAndBracket(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("c") == 0x03, "Ctrl-C encodes as 0x03", &failures)
        expect(ControlKeyEncoder.encode("[") == 0x1B, "Ctrl-[ encodes as 0x1B", &failures)
    }

    private static func checkControlUppercasing(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("z") == 0x1A, "lowercase Ctrl-Z encodes as 0x1A", &failures)
        expect(ControlKeyEncoder.encode("Z") == 0x1A, "uppercase Ctrl-Z encodes as 0x1A", &failures)
    }

    private static func checkUnsupportedControlCharacters(_ failures: inout [String]) {
        expect(ControlKeyEncoder.encode("`") == nil, "backtick is not a control combination", &failures)
        expect(ControlKeyEncoder.encode("é") == nil, "non-ASCII input is not a control combination", &failures)
    }

    private static func checkShortcutInputReducer(_ failures: inout [String]) {
        var reducer = ShortcutInputReducer()
        expect(reducer.handleShortcut(.control) == [], "Ctrl latches without emitting bytes", &failures)
        expect(reducer.isControlLatched, "Ctrl reports its latched state", &failures)
        expect(reducer.reduceText("c") == [0x03], "latched Ctrl-C emits 0x03", &failures)
        expect(!reducer.isControlLatched, "Ctrl clears after one printable ASCII character", &failures)
        expect(reducer.reduceText("c") == [0x63], "cleared Ctrl does not affect the next character", &failures)

        let expected: [(TerminalShortcutKey, [UInt8])] = [
            (.escape, [0x1B]),
            (.tab, [0x09]),
            (.up, [0x1B, 0x5B, 0x41]),
            (.down, [0x1B, 0x5B, 0x42]),
            (.right, [0x1B, 0x5B, 0x43]),
            (.left, [0x1B, 0x5B, 0x44]),
            (.slash, [0x2F])
        ]
        for (key, bytes) in expected {
            expect(reducer.handleShortcut(key) == bytes, "\(key) emits its terminal byte sequence", &failures)
        }

        _ = reducer.handleShortcut(.control)
        expect(reducer.reduceText("1") == [0x31], "unsupported printable Ctrl input passes through", &failures)
        expect(!reducer.isControlLatched, "unsupported printable Ctrl input still clears the latch", &failures)
    }

    private static func checkQuotedShellPath(_ failures: inout [String]) {
        let parser = ShellCommandParser()
        let command = try? parser.parse("touch \"two words.txt\"")
        expect(
            command == .touch(path: "two words.txt"),
            "shell parser preserves a quoted path",
            &failures
        )
    }

    private static func checkShellArityRejection(_ failures: inout [String]) {
        let parser = ShellCommandParser()
        do {
            _ = try parser.parse("cp source.txt")
            failures.append("shell parser rejects a copy with no destination")
        } catch let error as ShellCommandParserError {
            expect(error == .wrongArity(command: "cp"), "shell parser reports copy arity", &failures)
        } catch {
            failures.append("shell parser reports the expected copy arity error")
        }
    }

    private static func checkExactShellCommandSet(_ failures: inout [String]) {
        let parser = ShellCommandParser()
        let expected: [(String, ShellCommand)] = [
            ("pwd", .pwd), ("ls", .ls(path: nil)), ("ls docs", .ls(path: "docs")),
            ("cd docs", .cd(path: "docs")), ("cat note.txt", .cat(path: "note.txt")),
            ("mkdir docs", .mkdir(path: "docs")), ("touch note.txt", .touch(path: "note.txt")),
            ("cp one.txt two.txt", .copy(source: "one.txt", destination: "two.txt")),
            ("mv one.txt two.txt", .move(source: "one.txt", destination: "two.txt")),
            ("rm note.txt", .remove(path: "note.txt")), ("clear", .clear),
            ("edit note.txt", .edit(path: "note.txt"))
        ]
        for (input, command) in expected {
            do {
                let parsed = try parser.parse(input)
                expect(parsed == command, "shell parser recognizes \(input)", &failures)
            } catch {
                failures.append("shell parser recognizes \(input)")
            }
        }
    }

    private static func checkSymlinkedShellPathIsRejected(_ failures: inout [String]) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-root-\(UUID().uuidString)", isDirectory: true)
        let sibling = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-sibling-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sibling, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: sibling)
            let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: root)
            do {
                _ = try resolver.resolve("escape/secret.txt")
                failures.append("workspace resolver rejects symlink escapes")
            } catch WorkspacePathResolverError.outsideWorkspace {
                // Expected behavior.
            } catch {
                failures.append("workspace resolver reports a symlink escape as out of workspace")
            }
        } catch {
            failures.append("workspace resolver runner fixture can be created: \(error)")
        }
    }

    private static func checkWorkspaceVirtualPaths(_ failures: inout [String]) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-virtual-root-\(UUID().uuidString)", isDirectory: true)
        do {
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            let resolver = WorkspacePathResolver(rootURL: root, currentDirectoryURL: nested)
            let relative = try resolver.resolve("../note.txt")
            let virtual = try resolver.resolve("/documents/readme.txt")
            let canonicalRoot = try WorkspacePathResolver(rootURL: root, currentDirectoryURL: root).resolve("/")
            expect(relative.path == canonicalRoot.appendingPathComponent("note.txt").path, "workspace resolver allows contained parent traversal", &failures)
            expect(virtual.path == canonicalRoot.appendingPathComponent("documents/readme.txt").path, "absolute shell paths are workspace virtual", &failures)
            expect(resolver.displayPath(for: virtual) == "/documents/readme.txt", "workspace resolver displays virtual paths", &failures)
            do {
                _ = try resolver.resolve("../../outside.txt")
                failures.append("workspace resolver rejects parent traversal outside root")
            } catch WorkspacePathResolverError.outsideWorkspace {
                // Expected behavior.
            } catch {
                failures.append("workspace resolver classifies parent traversal as outside root")
            }
        } catch {
            failures.append("workspace virtual-path runner fixture can be created: \(error)")
        }
    }

    private static func checkLocalShellFileOperations(_ failures: inout [String]) async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-local-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let shell = LocalShell(rootURL: root)
            let createdDirectory = await shell.execute("mkdir docs")
            let changedDirectory = await shell.execute("cd docs")
            let workingDirectory = await shell.execute("pwd")
            let touched = await shell.execute("touch source.txt")
            try "hello".data(using: .utf8)!.write(to: root.appendingPathComponent("docs/source.txt"))
            let listed = await shell.execute("ls")
            let read = await shell.execute("cat source.txt")
            let copied = await shell.execute("cp source.txt copied.txt")
            let moved = await shell.execute("mv copied.txt moved.txt")
            let removal = await shell.execute("rm moved.txt")
            let canonicalRoot = try WorkspacePathResolver(rootURL: root, currentDirectoryURL: root).resolve("/")
            let movedURL = canonicalRoot.appendingPathComponent("docs/moved.txt")
            expect(removal.deletionConfirmationRequest?.targetURL.path == movedURL.path, "rm returns the exact single-file confirmation target", &failures)
            expect(fileManager.fileExists(atPath: movedURL.path), "rm does not delete before explicit confirmation", &failures)
            let removed = if let request = removal.deletionConfirmationRequest {
                await shell.confirmDeletion(request)
            } else {
                ShellExecution(outputLines: ["missing request"])
            }
            let rootRemoval = await shell.execute("rm /")
            let directoryRemoval = await shell.execute("rm .")

            expect(createdDirectory.outputLines.isEmpty, "local shell creates one directory", &failures)
            expect(changedDirectory.directoryChange?.path == canonicalRoot.appendingPathComponent("docs").path, "local shell changes directory", &failures)
            expect(workingDirectory.outputLines == ["/docs"], "local shell reports virtual working directory", &failures)
            expect(touched.outputLines.isEmpty, "local shell creates one file", &failures)
            expect(listed.outputLines == ["source.txt"], "local shell lists a directory", &failures)
            expect(read.outputLines == ["hello"], "local shell reads UTF-8 text", &failures)
            expect(copied.outputLines.isEmpty, "local shell copies one file", &failures)
            expect(moved.outputLines.isEmpty, "local shell moves one file", &failures)
            expect(removed.outputLines.isEmpty, "local shell removes one file", &failures)
            expect(!fileManager.fileExists(atPath: movedURL.path), "confirmed local shell removal changes the temporary fixture", &failures)
            expect(rootRemoval.outputLines == ["Error: workspace root cannot be removed"], "local shell rejects workspace root removal", &failures)
            expect(directoryRemoval.outputLines == ["Error: directories cannot be removed"], "local shell rejects directory removal", &failures)

            let keepURL = root.appendingPathComponent("docs/keep.txt")
            let staleURL = root.appendingPathComponent("docs/stale.txt")
            try Data("keep".utf8).write(to: keepURL)
            try Data("stale".utf8).write(to: staleURL)
            if let cancelled = (await shell.execute("rm keep.txt")).deletionConfirmationRequest {
                await shell.cancelDeletion(cancelled)
            }
            expect(fileManager.fileExists(atPath: keepURL.path), "cancelled rm preserves a non-empty file", &failures)
            let stale = (await shell.execute("rm stale.txt")).deletionConfirmationRequest
            _ = await shell.execute("pwd")
            if let stale {
                let staleResult = await shell.confirmDeletion(stale)
                expect(staleResult.outputLines == ["Error: deletion request expired"], "a later command invalidates an rm request", &failures)
            }
            expect(fileManager.fileExists(atPath: staleURL.path), "a stale rm request cannot delete its file", &failures)

            let replacementURL = root.appendingPathComponent("docs/replacement.txt")
            let originalURL = root.appendingPathComponent("docs/original-object.txt")
            try Data("original".utf8).write(to: replacementURL)
            if let replacementRequest = (await shell.execute("rm replacement.txt")).deletionConfirmationRequest {
                try fileManager.moveItem(at: replacementURL, to: originalURL)
                try Data("new object".utf8).write(to: replacementURL)
                let replacementResult = await shell.confirmDeletion(replacementRequest)
                expect(replacementResult.outputLines == ["Error: deletion request expired"], "rm confirmation expires after same-path file replacement", &failures)
            } else {
                failures.append("replacement rm produces a confirmation request")
            }
            expect(fileManager.fileExists(atPath: replacementURL.path), "stale rm cannot delete a replacement object", &failures)
            expect(fileManager.fileExists(atPath: originalURL.path), "stale rm preserves the renamed original object", &failures)

            let guardedDirectory = root.appendingPathComponent("docs/guarded", isDirectory: true)
            let relocatedDirectory = root.appendingPathComponent("docs/relocated", isDirectory: true)
            try fileManager.createDirectory(at: guardedDirectory, withIntermediateDirectories: false)
            let guardedFile = guardedDirectory.appendingPathComponent("same-object.txt")
            try Data("same object".utf8).write(to: guardedFile)
            if let symlinkRequest = (await shell.execute("rm guarded/same-object.txt")).deletionConfirmationRequest {
                try fileManager.moveItem(at: guardedDirectory, to: relocatedDirectory)
                try fileManager.createSymbolicLink(at: guardedDirectory, withDestinationURL: relocatedDirectory)
                let symlinkResult = await shell.confirmDeletion(symlinkRequest)
                expect(symlinkResult.outputLines == ["Error: deletion request expired"], "rm confirmation expires after intermediate-directory symlink replacement", &failures)
            } else {
                failures.append("intermediate-symlink rm produces a confirmation request")
            }
            expect(
                fileManager.fileExists(atPath: relocatedDirectory.appendingPathComponent("same-object.txt").path),
                "rm cannot follow a replaced intermediate directory symlink even to the same file identity",
                &failures
            )

            let symlinkTargetURL = root.appendingPathComponent("docs/symlink-target.txt")
            let symlinkRelocatedURL = root.appendingPathComponent("docs/symlink-relocated.txt")
            try Data("same object".utf8).write(to: symlinkTargetURL)
            if let targetSymlinkRequest = (await shell.execute("rm symlink-target.txt")).deletionConfirmationRequest {
                try fileManager.moveItem(at: symlinkTargetURL, to: symlinkRelocatedURL)
                try fileManager.createSymbolicLink(at: symlinkTargetURL, withDestinationURL: symlinkRelocatedURL)
                let targetSymlinkResult = await shell.confirmDeletion(targetSymlinkRequest)
                expect(targetSymlinkResult.outputLines == ["Error: deletion request expired"], "rm confirmation expires after target symlink replacement", &failures)
            } else {
                failures.append("target-symlink rm produces a confirmation request")
            }
            expect(
                (try? fileManager.destinationOfSymbolicLink(atPath: symlinkTargetURL.path)) == symlinkRelocatedURL.path,
                "rm cannot remove a target symlink substituted after confirmation request",
                &failures
            )
            expect(fileManager.fileExists(atPath: symlinkRelocatedURL.path), "rm target-symlink rejection preserves the original object", &failures)
        } catch {
            failures.append("local shell runner fixture can be created: \(error)")
        }
    }

    private static func checkLocalShellEditorClearAndSizeLimit(_ failures: inout [String]) async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-size-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let atLimit = root.appendingPathComponent("at-limit.txt")
            let aboveLimit = root.appendingPathComponent("above-limit.txt")
            try Data(repeating: 0x61, count: 5 * 1024 * 1024).write(to: atLimit)
            try Data(repeating: 0x61, count: 5 * 1024 * 1024 + 1).write(to: aboveLimit)
            let shell = LocalShell(rootURL: root)
            let editable = await shell.execute("edit at-limit.txt")
            let rejectedRead = await shell.execute("cat above-limit.txt")
            let rejectedEdit = await shell.execute("edit above-limit.txt")
            let clear = await shell.execute("clear")

            let canonicalRoot = try WorkspacePathResolver(rootURL: root, currentDirectoryURL: root).resolve("/")
            expect(editable.editorURL?.path == canonicalRoot.appendingPathComponent("at-limit.txt").path, "local shell allows edit at exactly 5 MiB", &failures)
            expect(rejectedRead.outputLines == ["Error: file exceeds the 5 MiB read/edit limit"], "local shell rejects reads over 5 MiB", &failures)
            expect(rejectedEdit.outputLines == ["Error: file exceeds the 5 MiB read/edit limit"], "local shell rejects edits over 5 MiB", &failures)
            expect(clear.clearRequested && clear.outputLines.isEmpty, "local shell reports clear without output", &failures)
        } catch {
            failures.append("local shell size-limit runner fixture can be created: \(error)")
        }
    }

    private static func checkLocalShellDirectoryEditAndEmptyCat(_ failures: inout [String]) async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LiteTerm-Runner-edit-empty-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: false)
            guard fileManager.createFile(atPath: root.appendingPathComponent("empty.txt").path, contents: Data()) else {
                failures.append("local shell empty-file fixture can be created")
                return
            }
            let shell = LocalShell(rootURL: root)

            let directoryEdit = await shell.execute("edit docs")
            let emptyRead = await shell.execute("cat empty.txt")

            expect(directoryEdit.editorURL == nil, "local shell does not open a directory in the editor", &failures)
            expect(directoryEdit.outputLines == ["Error: target is not a regular file"], "local shell explains directory edit rejection", &failures)
            expect(emptyRead.outputLines.isEmpty, "cat of an empty file emits no output lines", &failures)
        } catch {
            failures.append("local shell directory-edit runner fixture can be created: \(error)")
        }
    }

    private static func checkInjectedFileAccessBoundary(_ failures: inout [String]) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Runner-injected-file-access-\(UUID().uuidString)", isDirectory: true)
        let shell = LocalShell(rootURL: root, fileSystem: RunnerFileSystem())

        let listing = await shell.execute("ls")

        expect(listing.outputLines == ["coordinated-entry"], "local shell uses its injected file access boundary", &failures)

        let mismatchFileSystem = RunnerIdentityMismatchFileSystem()
        let mismatchShell = LocalShell(rootURL: root, fileSystem: mismatchFileSystem)
        if let request = (await mismatchShell.execute("rm target.txt")).deletionConfirmationRequest {
            let result = await mismatchShell.confirmDeletion(request)
            expect(result.outputLines == ["Error: deletion request expired"], "local shell fails closed on an injected coordinated identity mismatch", &failures)
        } else {
            failures.append("injected identity mismatch produces a confirmation request")
        }
        expect(mismatchFileSystem.revalidationCallCount == 1, "local shell delegates confirmation to one revalidation/removal boundary", &failures)
        expect(!mismatchFileSystem.didDelete, "identity mismatch boundary performs no deletion", &failures)

        let raceFileSystem = RunnerRequestPreparationRaceFileSystem()
        let raceShell = LocalShell(rootURL: root, fileSystem: raceFileSystem)
        let raceResult = await raceShell.execute("rm target.txt")
        expect(raceResult.deletionConfirmationRequest == nil, "request preparation rejects a target replaced by a symlink", &failures)
        expect(raceResult.outputLines == ["Error: deletion request expired"], "request-time replacement expires without displaying a bound target", &failures)
        expect(raceFileSystem.prepareCallCount == 1, "local shell uses exactly one request preparation boundary", &failures)

        let mismatchedPreparedFileSystem = RunnerMismatchedPreparedDeletionFileSystem()
        let mismatchedPreparedShell = LocalShell(rootURL: root, fileSystem: mismatchedPreparedFileSystem)
        let mismatchedPreparedResult = await mismatchedPreparedShell.execute("rm target.txt")
        expect(mismatchedPreparedResult.deletionConfirmationRequest == nil, "local shell rejects mismatched prepared display and logical paths", &failures)
        expect(mismatchedPreparedResult.outputLines == ["Error: deletion request expired"], "mismatched prepared deletion fails closed", &failures)
    }

    private static func checkRemoteOutputSanitization(_ failures: inout [String]) {
        var sanitizer = RemoteOutputSanitizer()
        let ordinary = Array("hello".utf8) + [0x1B, 0x5B, 0x41]
        expect(sanitizer.sanitize(ordinary) == ordinary, "remote sanitizer preserves ordinary terminal bytes", &failures)

        var ordinaryRepeatedEscapeSanitizer = RemoteOutputSanitizer()
        expect(
            ordinaryRepeatedEscapeSanitizer.sanitize([0x1B, 0x1B, 0x5B, 0x41]) == [0x1B, 0x1B, 0x5B, 0x41],
            "remote sanitizer preserves repeated ESC outside DCS",
            &failures
        )

        let sevenBit = [UInt8(0x61), 0x1B, 0x50] + Array("qpayload".utf8) + [0x1B, 0x5C, 0x62]
        expect(sanitizer.sanitize(sevenBit) == [0x61, 0x62], "remote sanitizer strips complete seven-bit DCS", &failures)

        let eightBit = [UInt8(0x63), 0x90] + Array("payload".utf8) + [0x9C, 0x64]
        expect(sanitizer.sanitize(eightBit) == [0x63, 0x64], "remote sanitizer strips complete eight-bit DCS", &failures)

        expect(sanitizer.sanitize([0x61, 0x1B]) == [0x61], "remote sanitizer holds a split escape introducer", &failures)
        expect(sanitizer.bufferedByteCount == 1, "remote sanitizer buffers at most the pending escape byte", &failures)
        expect(sanitizer.sanitize([0x50, 0x71, 0x1B]) == [], "remote sanitizer strips a split DCS body", &failures)
        expect(sanitizer.bufferedByteCount == 1, "remote sanitizer records only the pending DCS-exit escape", &failures)
        expect(sanitizer.sanitize([0x5C, 0x62]) == [0x62], "remote sanitizer recognizes a split DCS terminator", &failures)

        var canSanitizer = RemoteOutputSanitizer()
        expect(canSanitizer.sanitize([0x61, 0x1B, 0x50, 0x71, 0x31]) == [0x61], "remote sanitizer enters seven-bit DCS before CAN", &failures)
        expect(canSanitizer.sanitize([0x18, 0x62]) == [0x62], "CAN cancels a split seven-bit DCS", &failures)

        var subSanitizer = RemoteOutputSanitizer()
        expect(subSanitizer.sanitize([0x61, 0x90, 0x71, 0x31]) == [0x61], "remote sanitizer enters eight-bit DCS before SUB", &failures)
        expect(subSanitizer.sanitize([0x1A, 0x62]) == [0x62], "SUB cancels a split eight-bit DCS", &failures)

        var escapeExitSanitizer = RemoteOutputSanitizer()
        expect(escapeExitSanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B]).isEmpty, "remote sanitizer holds a split DCS-exit escape", &failures)
        expect(escapeExitSanitizer.bufferedByteCount == 1, "split DCS-exit escape retains one control byte", &failures)
        expect(
            escapeExitSanitizer.sanitize([0x5B, 0x33, 0x31, 0x6D, 0x4F, 0x4B]) == [0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x4F, 0x4B],
            "non-ST after DCS escape preserves the new escape sequence",
            &failures
        )

        var repeatedEscapeSanitizer = RemoteOutputSanitizer()
        _ = repeatedEscapeSanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B])
        expect(repeatedEscapeSanitizer.sanitize([0x1B, 0x1B]).isEmpty, "repeated ESC exits DCS and retains only the newest split escape", &failures)
        expect(repeatedEscapeSanitizer.bufferedByteCount == 1, "repeated ESC retains only the new escape introducer", &failures)
        expect(repeatedEscapeSanitizer.sanitize([0x5B, 0x41]) == [0x1B, 0x5B, 0x41], "repeated ESC preserves the following CSI sequence", &failures)

        var reentrySanitizer = RemoteOutputSanitizer()
        _ = reentrySanitizer.sanitize([0x1B, 0x50, 0x71, 0x31, 0x1B])
        expect(
            reentrySanitizer.sanitize([0x50, 0x71, 0x32, 0x33, 0x1B, 0x5C, 0x62]) == [0x62],
            "ESC P after DCS exit re-enters filtering without leaking payload",
            &failures
        )

        var c1ReentrySanitizer = RemoteOutputSanitizer()
        expect(
            c1ReentrySanitizer.sanitize([0x1B, 0x90, 0x71, 0x32, 0x33, 0x9C, 0x62]) == [0x62],
            "ESC followed by C1 DCS re-enters filtering without leaving terminal escape state",
            &failures
        )

        _ = sanitizer.sanitize([0x1B, 0x50])
        for _ in 0..<128 {
            expect(sanitizer.sanitize(Array(repeating: 0x71, count: 8_192)).isEmpty, "remote sanitizer emits no DCS payload", &failures)
            expect(sanitizer.bufferedByteCount == 0, "remote sanitizer retains no DCS payload bytes", &failures)
        }
        expect(sanitizer.sanitize([0x1B, 0x5C, 0x7A]) == [0x7A], "remote sanitizer resumes after a bounded DCS payload", &failures)
    }

    private static func checkLocalTerminalInputOrdering(_ failures: inout [String]) {
        var reducer = LocalTerminalInputReducer()
        expect(
            reducer.reduce(Array("pwd\r".utf8)) == [
                .echo(Array("pwd".utf8)),
                .submit("pwd")
            ],
            "local input emits pwd echo before its submit event",
            &failures
        )

        reducer.reset()
        expect(
            reducer.reduce(Array("pwd\r\nls\r".utf8)) == [
                .echo(Array("pwd".utf8)),
                .submit("pwd"),
                .echo(Array("ls".utf8)),
                .submit("ls")
            ],
            "multiline paste preserves echo and submit byte order",
            &failures
        )

        reducer.reset()
        expect(
            reducer.reduce(Array("ab".utf8) + [0x7F] + Array("c".utf8) + [0x03]) == [
                .echo(Array("ab".utf8)),
                .erase,
                .echo(Array("c".utf8)),
                .interrupt
            ],
            "local input flushes printable runs before controls",
            &failures
        )
    }

    private static func checkLocalTerminalInputBound(_ failures: inout [String]) {
        var reducer = LocalTerminalInputReducer(maximumInputBytes: 8)
        let oversized = Array(repeating: UInt8(ascii: "a"), count: 9)
        let pasteEvents = reducer.reduce(oversized)
        let echoedByteCount = pasteEvents.reduce(into: 0) { count, event in
            if case .echo(let bytes) = event {
                count += bytes.count
            }
        }
        expect(echoedByteCount == 8, "Local paste echo is bounded to its input budget", &failures)

        _ = reducer.reduce([0x7F])
        _ = reducer.reduce([UInt8(ascii: "b")])
        let submitEvents = reducer.reduce([0x0D])
        guard case .submit(let command) = submitEvents.last else {
            failures.append("bounded Local input remains submittable")
            return
        }
        expect(command.utf8.count == 8, "Local command buffer is bounded to its input budget", &failures)
        expect(command.last == "b", "backspace releases Local input capacity", &failures)

        var unicode = LocalTerminalInputReducer(maximumInputBytes: 8)
        let emoji = Array("😀".utf8)
        expect(unicode.reduce(Array(emoji.prefix(2))).isEmpty, "split UTF-8 emits no partial scalar", &failures)
        expect(unicode.bufferedPartialScalarByteCount == 2, "split UTF-8 retains only its bounded scalar prefix", &failures)
        expect(unicode.reduce(Array(emoji.suffix(2))) == [.echo(emoji)], "split UTF-8 echoes one complete scalar atomically", &failures)
        expect(unicode.reduce([0x0D]) == [.submit("😀")], "split UTF-8 submits without replacement corruption", &failures)

        var exactBoundary = LocalTerminalInputReducer(maximumInputBytes: 5)
        _ = exactBoundary.reduce(Array("abc".utf8))
        expect(exactBoundary.reduce(emoji).isEmpty, "a scalar crossing the exact input boundary is rejected atomically", &failures)
        expect(exactBoundary.reduce([0x0D]) == [.submit("abc")], "boundary rejection preserves valid input", &failures)

        var paste = LocalTerminalInputReducer(maximumEventsPerReduction: 6)
        expect(paste.reduce(Array(String(repeating: "x\n", count: 100).utf8)).count == 6, "multiline paste work is capped by one event budget", &failures)

        var navigation = LocalTerminalInputReducer()
        _ = navigation.reduce(Array("pwd\r".utf8))
        _ = navigation.reduce(Array("ls\r".utf8))
        expect(navigation.navigateHistory(.previous) == [.replaceLine(Array("ls".utf8))], "Local Up recalls the latest command", &failures)
        expect(navigation.navigateHistory(.previous) == [.replaceLine(Array("pwd".utf8))], "repeated Local Up recalls older history", &failures)
        expect(navigation.navigateHistory(.next) == [.replaceLine(Array("ls".utf8))], "Local Down advances history", &failures)
        expect(navigation.navigateHistory(.next) == [.replaceLine([])], "Local Down returns to an empty input line", &failures)

        var exactControlBudget = LocalTerminalInputReducer(maximumEventsPerReduction: 2)
        expect(
            exactControlBudget.reduce([UInt8(ascii: "a"), 0x03]) == [.echo([UInt8(ascii: "a")]), .interrupt],
            "Local echo and interrupt consume their exact aggregate event budget",
            &failures
        )
        var insufficientControlBudget = LocalTerminalInputReducer(maximumEventsPerReduction: 1)
        let boundedControlEvents = insufficientControlBudget.reduce([UInt8(ascii: "a"), 0x03])
        expect(boundedControlEvents == [.echo([UInt8(ascii: "a")])], "Local interrupt is not partially applied beyond its event budget", &failures)
        expect(boundedControlEvents.count <= 1, "Local interrupt path never exceeds the event cap", &failures)
        expect(insufficientControlBudget.reduce([0x03]) == [.interrupt], "Local interrupt remains deterministic after an insufficient batch budget", &failures)

        var insufficientEraseBudget = LocalTerminalInputReducer(maximumEventsPerReduction: 1)
        let boundedEraseEvents = insufficientEraseBudget.reduce([UInt8(ascii: "a"), 0x7F])
        expect(boundedEraseEvents == [.echo([UInt8(ascii: "a")])], "Local erase is not partially applied beyond its event budget", &failures)
        expect(boundedEraseEvents.count <= 1, "Local erase path never exceeds the event cap", &failures)
        expect(insufficientEraseBudget.reduce([0x7F]) == [.erase], "Local erase remains deterministic after an insufficient batch budget", &failures)
    }

    private static func checkCoordinatedPathInspection(_ failures: inout [String]) async {
        let root = URL(fileURLWithPath: "/tmp/LiteTerm-runner-inspected-root-\(UUID().uuidString)", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/LiteTerm-runner-inspected-outside-\(UUID().uuidString)", isDirectory: true)
        let fileSystem = RunnerInspectingFileSystem(
            symbolicLinks: [root.appendingPathComponent("escape").path: outside.path]
        )
        let resolver = WorkspacePathResolver(
            rootURL: root,
            currentDirectoryURL: root,
            pathInspector: fileSystem
        )

        do {
            _ = try resolver.resolve("escape/secret.txt")
            failures.append("workspace resolver uses injected symlink inspection")
        } catch WorkspacePathResolverError.outsideWorkspace {
            // Expected behavior proves the injected boundary supplied the virtual symlink.
        } catch {
            failures.append("workspace resolver classifies the injected symlink escape")
        }

        let cdFileSystem = RunnerInspectingFileSystem()
        let cdRoot = URL(fileURLWithPath: "/tmp/LiteTerm-runner-inspected-cd-\(UUID().uuidString)", isDirectory: true)
        let shell = LocalShell(rootURL: cdRoot, fileSystem: cdFileSystem)
        let change = await shell.execute("cd virtual-folder")
        expect(change.outputLines.isEmpty, "local shell accepts injected directory inspection", &failures)
        expect(
            change.directoryChange?.path == cdRoot.appendingPathComponent("virtual-folder").path,
            "local shell cd uses the injected file access boundary",
            &failures
        )
    }

    @MainActor
    private static func checkLocalOperationQueue() async -> [String] {
        var failures: [String] = []
        let queue = LocalOperationQueue()
        let gate = RunnerDelayedOperationGate()
        let recorder = RunnerOperationRecorder()

        expect(queue.enqueue {
            await recorder.append("old-start")
            await gate.wait()
            await recorder.append("old-finish")
        }, "local operation queue accepts an old-root operation", &failures)
        expect(queue.enqueue {
            await recorder.append("old-second")
        }, "local operation queue accepts a second old-root operation", &failures)

        let transition = Task { @MainActor in
            await queue.suspendAndDrain()
            await recorder.append("scope-stop")
        }

        await gate.waitUntilStarted()
        while queue.isAccepting {
            await Task.yield()
        }
        expect(!queue.enqueue {
            await recorder.append("blocked")
        }, "local operation queue blocks new input during transition", &failures)

        await gate.release()
        await transition.value
        let drainedValues = await recorder.values()
        expect(
            drainedValues == ["old-start", "old-finish", "old-second", "scope-stop"],
            "local operation queue drains old work before scope stop",
            &failures
        )

        queue.resume()
        expect(queue.enqueue {
            await recorder.append("new-root")
        }, "local operation queue resumes after root replacement", &failures)
        await queue.suspendAndDrain()
        let resumedValues = await recorder.values()
        expect(
            resumedValues == ["old-start", "old-finish", "old-second", "scope-stop", "new-root"],
            "local operation queue runs resumed input only after transition",
            &failures
        )

        let boundedQueue = LocalOperationQueue(maximumPendingOperations: 3, maximumPendingCost: 6)
        let boundedGate = RunnerDelayedOperationGate()
        let boundedRecorder = RunnerOperationRecorder()
        var input = LocalTerminalInputReducer()
        var acceptedCount = 0
        var rejectedCount = 0
        for index in 0..<12 {
            for event in input.reduce(Array("x\(index % 10)\r".utf8)) {
                guard case .submit(let command) = event else { continue }
                if boundedQueue.enqueue(operationCost: command.utf8.count, {
                    if index == 0 {
                        await boundedGate.wait()
                    }
                    await boundedRecorder.append(command)
                }) {
                    acceptedCount += 1
                } else {
                    rejectedCount += 1
                }
            }
        }
        await boundedGate.waitUntilStarted()
        expect(acceptedCount == 3 && rejectedCount == 9, "local operation queue rejects repeated submits beyond its aggregate limits", &failures)
        expect(boundedQueue.pendingOperationCount == 3, "local operation queue bounds retained operation count", &failures)
        expect(boundedQueue.pendingOperationCost == 6, "local operation queue bounds retained command bytes", &failures)
        let boundedDrain = Task { @MainActor in await boundedQueue.suspendAndDrain() }
        while boundedQueue.isAccepting { await Task.yield() }
        expect(!boundedQueue.enqueue(operationCost: 1, {}), "bounded queue rejects work while draining", &failures)
        await boundedGate.release()
        await boundedDrain.value
        expect(boundedQueue.pendingOperationCount == 0 && boundedQueue.pendingOperationCost == 0, "bounded queue releases all reservations after drain", &failures)
        let boundedDrainedValues = await boundedRecorder.values()
        expect(boundedDrainedValues.count == 3, "bounded queue executes only accepted submits", &failures)
        boundedQueue.resume()
        expect(boundedQueue.enqueue(operationCost: 6, { await boundedRecorder.append("resumed") }), "bounded queue accepts work deterministically after resume", &failures)
        await boundedQueue.suspendAndDrain()
        let boundedResumedValues = await boundedRecorder.values()
        expect(boundedResumedValues.last == "resumed", "bounded queue completes resumed work", &failures)

        let scheduler = WorkspaceTransitionScheduler()
        let transitionGate = RunnerDelayedOperationGate()
        let transitionRecorder = RunnerOperationRecorder()
        scheduler.submitNormal {
            await transitionRecorder.append("normal-running")
            await transitionGate.wait()
        }
        await transitionGate.waitUntilStarted()
        for index in 0..<100 {
            scheduler.submitNormal { await transitionRecorder.append("normal-\(index)") }
        }
        for _ in 0..<100 {
            scheduler.submitSafety { await transitionRecorder.append("safety") }
        }
        scheduler.submitNormal { await transitionRecorder.append("normal-latest") }
        expect(scheduler.retainedTransitionCount == 3, "workspace scheduler retains one running, one safety, and one latest normal transition", &failures)
        expect(scheduler.hasPendingSafety && scheduler.hasPendingNormal, "workspace scheduler preserves safety and latest normal intents under saturation", &failures)
        await transitionGate.release()
        await scheduler.drain()
        let transitionValues = await transitionRecorder.values()
        expect(transitionValues == ["normal-running", "safety", "normal-latest"], "workspace scheduler executes safety before the latest coalesced normal transition", &failures)
        expect(scheduler.retainedTransitionCount == 0, "workspace scheduler releases all retained transitions after drain", &failures)
        return failures
    }

    private static func checkHostRepository(_ failures: inout [String]) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Runner-hosts-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("hosts.json")
        do {
            let first = try SSHHost(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                label: "Zulu",
                hostname: "server.example",
                port: 22,
                username: "alice",
                authenticationKind: .password,
                reconnectPreference: .enabled
            )
            let second = try SSHHost(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                label: "Alpha",
                hostname: "backup.example",
                port: 2222,
                username: "bob",
                authenticationKind: .generatedKey,
                reconnectPreference: .disabled
            )
            let hostData = try JSONEncoder().encode(first)
            let hostObject = try JSONSerialization.jsonObject(with: hostData) as? [String: Any]
            let exactHostKeys: Set<String> = [
                "id", "label", "hostname", "port", "username",
                "authenticationKind", "reconnectPreference"
            ]
            let serializedHostKeys = Set(hostObject?.keys.map { $0 } ?? [])
            expect(
                serializedHostKeys == exactHostKeys,
                "SSHHost serialization contains exactly the allowed metadata keys",
                &failures
            )
            let repository = HostRepository(fileURL: fileURL)
            try repository.save([first, second])
            let snapshot = try repository.load()
            expect(snapshot.hosts == [first, second], "host repository preserves stable metadata order", &failures)
            expect(snapshot.issues.isEmpty, "host repository reports no issues for valid metadata", &failures)

            let encoded = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
            expect(!encoded.contains(#""password":"#) && !encoded.contains(#""privateKey":"#) && !encoded.contains(#""fingerprint":"#), "host metadata JSON contains no secret fields", &failures)

            let malformedJSON = """
            {"schemaVersion":1,"hosts":[
              {"id":"11111111-1111-1111-1111-111111111111","label":"Valid","hostname":"server.example","port":22,"username":"alice","authenticationKind":"password","reconnectPreference":"enabled"},
              {"id":"22222222-2222-2222-2222-222222222222","label":"Broken","hostname":"","port":22,"username":"bob","authenticationKind":"password","reconnectPreference":"enabled"}
            ]}
            """
            try Data(malformedJSON.utf8).write(to: fileURL, options: .atomic)
            let partial = try repository.load()
            expect(partial.hosts.map(\.label) == ["Valid"], "host repository retains valid records beside malformed records", &failures)
            expect(partial.issues.map(\.recordIndex) == [1], "host repository reports the malformed record index", &failures)

            let invalidSchemaVersions = ["true", "1.5", "2"]
            for invalidVersion in invalidSchemaVersions {
                let invalidEnvelope = #"{"schemaVersion":\#(invalidVersion),"hosts":[]}"#
                try Data(invalidEnvelope.utf8).write(to: fileURL, options: .atomic)
                do {
                    _ = try repository.load()
                    failures.append("host repository rejects schema version \(invalidVersion)")
                } catch HostRepositoryError.corruptEnvelope {
                    // Expected.
                } catch {
                    failures.append("host repository classifies schema version \(invalidVersion) as corrupt")
                }
            }

            let unknownFieldsJSON = """
            {"schemaVersion":1,"hosts":[
              {"id":"11111111-1111-1111-1111-111111111111","label":"Valid","hostname":"server.example","port":22,"username":"alice","authenticationKind":"password","reconnectPreference":"enabled"},
              {"id":"22222222-2222-2222-2222-222222222222","label":"Secret","hostname":"secret.example","port":22,"username":"bob","authenticationKind":"password","reconnectPreference":"enabled","trustedFingerprint":"not-a-real-fingerprint"},
              {"id":"33333333-3333-3333-3333-333333333333","label":"Unknown","hostname":"future.example","port":22,"username":"carol","authenticationKind":"generatedKey","reconnectPreference":"disabled","futureField":true}
            ]}
            """
            try Data(unknownFieldsJSON.utf8).write(to: fileURL, options: .atomic)
            let whitelisted = try repository.load()
            expect(whitelisted.hosts.map(\.label) == ["Valid"], "host repository skips secret-bearing and unknown-key records", &failures)
            expect(whitelisted.issues.map(\.recordIndex) == [1, 2], "host repository reports every non-whitelisted record", &failures)

            let corrupt = Data(#"{"schemaVersion":1,"hosts":["#.utf8)
            try corrupt.write(to: fileURL, options: .atomic)
            do {
                _ = try repository.load()
                failures.append("host repository rejects a wholly corrupt envelope")
            } catch HostRepositoryError.corruptEnvelope {
                expect((try? Data(contentsOf: fileURL)) == corrupt, "host repository leaves a corrupt envelope unchanged", &failures)
            } catch {
                failures.append("host repository classifies a wholly corrupt envelope")
            }
        } catch {
            failures.append("host repository runner completes: \(error)")
        }
    }

    private static func checkKnownHostPolicy(_ failures: inout [String]) {
        let fingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: nil, presentedFingerprint: "SHA256:\(fingerprint)") == .needsTrust,
            "known-host policy requires explicit first-use trust",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "SHA256:\(fingerprint)", presentedFingerprint: "SHA256:\(fingerprint)") == .trusted,
            "known-host policy trusts an exact fingerprint",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: " SHA256: \(fingerprint)= ", presentedFingerprint: "sha256:\(fingerprint)") == .trusted,
            "known-host policy normalizes prefix case and optional Base64 padding",
            &failures
        )
        let changedCase = "a" + fingerprint.dropFirst()
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "SHA256:\(fingerprint)", presentedFingerprint: "SHA256:\(changedCase)") == .mismatch,
            "known-host policy keeps fingerprint payload comparison case-sensitive",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "SHA256:\(fingerprint)", presentedFingerprint: "SHA256:BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == .mismatch,
            "known-host policy hard-fails a changed host key",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "not-a-fingerprint", presentedFingerprint: "not-a-fingerprint") == .mismatch,
            "known-host policy rejects equal arbitrary strings",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: nil, presentedFingerprint: "SHA256:not-base64") == .mismatch,
            "known-host policy validates a presented fingerprint before first-use trust",
            &failures
        )
        let shortDigest = Data(repeating: 0, count: 31).base64EncodedString()
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "SHA256:\(shortDigest)", presentedFingerprint: "SHA256:\(shortDigest)") == .mismatch,
            "known-host policy requires exactly 32 decoded digest bytes",
            &failures
        )
        expect(
            KnownHostPolicy.evaluate(savedFingerprint: "SHA256:\(fingerprint)==", presentedFingerprint: "SHA256:\(fingerprint)==") == .mismatch,
            "known-host policy rejects non-canonical padding",
            &failures
        )
    }

    private static func checkReconnectPolicy(_ failures: inout [String]) {
        let enabled = ReconnectPolicy(isEnabled: true)
        expect(
            (0...3).map {
                enabled.nextDelay(afterAttempt: $0, failure: .transportLoss, sceneIsActive: true)
            } == [.seconds(1), .seconds(2), .seconds(4), nil],
            "reconnect policy uses only 1, 2, and 4 second transport-loss delays",
            &failures
        )
        expect(
            enabled.nextDelay(afterAttempt: 0, failure: .transportLoss, sceneIsActive: false) == nil,
            "reconnect policy does not retry while the scene is inactive",
            &failures
        )
        expect(
            ReconnectPolicy(isEnabled: false).nextDelay(afterAttempt: 0, failure: .transportLoss, sceneIsActive: true) == nil,
            "reconnect policy honors a disabled host preference",
            &failures
        )
        let terminalFailures: [SSHConnectionFailure] = [
            .authenticationRejected,
            .hostKeyMismatch,
            .manualDisconnect
        ]
        expect(
            terminalFailures.allSatisfy {
                enabled.nextDelay(afterAttempt: 0, failure: $0, sceneIsActive: true) == nil
            },
            "reconnect policy does not retry terminal or manual failures",
            &failures
        )
        expect(
            enabled.nextDelay(afterAttempt: -1, failure: .transportLoss, sceneIsActive: true) == nil,
            "reconnect policy rejects a negative attempt",
            &failures
        )
    }

    private static func checkHostCredentialTransactions(_ failures: inout [String]) {
        do {
            let replacementID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let originalPasswordHost = try SSHHost(
                id: replacementID,
                label: "Original",
                hostname: "old.example",
                port: 22,
                username: "old-user",
                authenticationKind: .password,
                reconnectPreference: .enabled
            )
            let editedPasswordHost = try SSHHost(
                id: replacementID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let oldPassword = Data("old-password".utf8)
            let replacementBeforeHost = try runnerHost(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                authenticationKind: .generatedKey
            )
            let replacementAfterHost = try runnerHost(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                authenticationKind: .generatedKey
            )
            let replacementOriginalHosts = [
                replacementBeforeHost,
                originalPasswordHost,
                replacementAfterHost
            ]
            let replacementMetadata = RunnerHostMetadataStore(hosts: replacementOriginalHosts)
            let replacementSecrets = RunnerHostSecretStore()
            replacementSecrets.seed(oldPassword, for: replacementID, kind: .password)
            replacementSecrets.failNextSetKinds = [.password]
            let replacementCoordinator = HostCredentialCoordinator(
                metadata: replacementMetadata,
                secrets: replacementSecrets
            )
            let replacementFailure = replacementCoordinator.upsert(
                editedPasswordHost,
                password: Data("replacement-password".utf8),
                in: replacementOriginalHosts
            )
            expect(replacementFailure.hosts == replacementOriginalHosts, "password replacement failure returns original ordered metadata", &failures)
            expect(replacementMetadata.hosts == replacementOriginalHosts, "password replacement failure durably restores original ordered metadata", &failures)
            expect(replacementSecrets.value(for: replacementID, kind: .password) == oldPassword, "password replacement failure preserves the previous password", &failures)
            expect(replacementFailure.credentialStates[replacementID] == .ready, "successful password replacement compensation returns the original host healthy", &failures)
            expect(!replacementMetadata.hosts.contains(editedPasswordHost), "restart cannot inspect edited metadata with the stale password", &failures)
            expect(replacementCoordinator.inspect(replacementMetadata.hosts)[replacementID] == .ready, "restart inspection sees the coherent original host", &failures)
            expect(replacementSecrets.value(for: replacementID, kind: .credentialRepair) == nil, "successful replacement compensation leaves no repair marker", &failures)

            let orderID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
            let orderOriginalHost = try SSHHost(
                id: orderID,
                label: "Original",
                hostname: "old.example",
                port: 22,
                username: "old-user",
                authenticationKind: .password,
                reconnectPreference: .enabled
            )
            let orderEditedHost = try SSHHost(
                id: orderID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let orderLog = RunnerHostOperationLog()
            let orderMetadata = RunnerHostMetadataStore(hosts: [orderOriginalHost], operationLog: orderLog)
            let orderSecrets = RunnerHostSecretStore(operationLog: orderLog)
            orderSecrets.seed(Data("old-password".utf8), for: orderID, kind: .password)
            orderSecrets.failNextSetKinds = [.password]
            var orderCoordinator: HostCredentialCoordinator!
            var orderStates: [HostCredentialState?] = []
            orderLog.onEvent = { _ in
                orderStates.append(orderCoordinator.inspect(orderMetadata.hosts)[orderID])
            }
            orderCoordinator = HostCredentialCoordinator(metadata: orderMetadata, secrets: orderSecrets)
            let orderFailure = orderCoordinator.upsert(
                orderEditedHost,
                password: Data("new-password".utf8),
                in: [orderOriginalHost]
            )
            let expectedOrderEvents = [
                "set:credential-repair",
                "metadata:new.example",
                "set-failed:password",
                "set:password",
                "delete:private-key",
                "metadata:old.example",
                "delete:credential-repair"
            ]
            expect(orderLog.events == expectedOrderEvents, "credential compensation restores metadata before marker clear", &failures)
            expect(orderStates.dropLast().allSatisfy { $0 == .repairRequired }, "credential compensation has no ready intermediate state", &failures)
            expect(orderStates.last == .ready, "credential compensation becomes ready only after final marker clear", &failures)
            expect(orderFailure.hosts == [orderOriginalHost] && orderFailure.credentialStates[orderID] == .ready, "ordered compensation returns the coherent original host", &failures)

            let clearFailureID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
            let clearFailureOriginalHost = try runnerHost(id: clearFailureID, authenticationKind: .password)
            let clearFailureEditedHost = try SSHHost(
                id: clearFailureID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let clearFailureLog = RunnerHostOperationLog()
            let clearFailureMetadata = RunnerHostMetadataStore(hosts: [clearFailureOriginalHost], operationLog: clearFailureLog)
            let clearFailureSecrets = RunnerHostSecretStore(operationLog: clearFailureLog)
            clearFailureSecrets.seed(Data("old-password".utf8), for: clearFailureID, kind: .password)
            clearFailureSecrets.failNextSetKinds = [.password]
            clearFailureSecrets.failNextDeleteKinds = [.credentialRepair]
            let clearFailureCoordinator = HostCredentialCoordinator(
                metadata: clearFailureMetadata,
                secrets: clearFailureSecrets
            )
            let clearFailure = clearFailureCoordinator.upsert(
                clearFailureEditedHost,
                password: Data("new-password".utf8),
                in: [clearFailureOriginalHost]
            )
            let clearFailureMetadataIndex = clearFailureLog.events.firstIndex(of: "metadata:server.example")
            let clearFailureMarkerIndex = clearFailureLog.events.firstIndex(of: "delete-failed:credential-repair")
            expect(
                clearFailureMetadataIndex != nil && clearFailureMarkerIndex != nil && clearFailureMetadataIndex! < clearFailureMarkerIndex!,
                "marker-clear failure occurs only after metadata restoration",
                &failures
            )
            expect(clearFailureLog.events.last == "delete-failed:credential-repair", "marker-clear failure does not rewrite or clear the marker", &failures)
            expect(clearFailure.failure == .compensationFailed(original: .password, rollback: .secret(.credentialRepair)), "marker-clear failure identifies its non-secret rollback boundary", &failures)
            expect(clearFailure.credentialStates[clearFailureID] == .repairRequired && clearFailureCoordinator.inspect(clearFailureMetadata.hosts)[clearFailureID] == .repairRequired, "marker-clear failure remains repair-required after restart", &failures)

            let existingMarkerID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
            let existingMarkerOriginalHost = try runnerHost(id: existingMarkerID, authenticationKind: .password)
            let existingMarkerEditedHost = try SSHHost(
                id: existingMarkerID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let originalMarker = Data([9])
            let existingMarkerLog = RunnerHostOperationLog()
            let existingMarkerMetadata = RunnerHostMetadataStore(hosts: [existingMarkerOriginalHost], operationLog: existingMarkerLog)
            let existingMarkerSecrets = RunnerHostSecretStore(operationLog: existingMarkerLog)
            existingMarkerSecrets.seed(Data("old-password".utf8), for: existingMarkerID, kind: .password)
            existingMarkerSecrets.seed(originalMarker, for: existingMarkerID, kind: .credentialRepair)
            existingMarkerSecrets.failNextSetKinds = [.password]
            let existingMarkerCoordinator = HostCredentialCoordinator(
                metadata: existingMarkerMetadata,
                secrets: existingMarkerSecrets
            )
            let existingMarkerFailure = existingMarkerCoordinator.upsert(
                existingMarkerEditedHost,
                password: Data("new-password".utf8),
                in: [existingMarkerOriginalHost]
            )
            expect(Array(existingMarkerLog.events.suffix(2)) == ["metadata:server.example", "set:credential-repair"], "existing marker is restored only after original metadata", &failures)
            expect(existingMarkerSecrets.value(for: existingMarkerID, kind: .credentialRepair) == originalMarker, "compensation restores the original marker value", &failures)
            expect(existingMarkerFailure.hosts == [existingMarkerOriginalHost] && existingMarkerFailure.credentialStates[existingMarkerID] == .repairRequired, "original repair state remains visible after compensation", &failures)

            let markerGuardID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
            let markerGuardOriginalHost = try runnerHost(id: markerGuardID, authenticationKind: .password)
            let markerGuardEditedHost = try SSHHost(
                id: markerGuardID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let markerGuardLog = RunnerHostOperationLog()
            let markerGuardMetadata = RunnerHostMetadataStore(hosts: [markerGuardOriginalHost], operationLog: markerGuardLog)
            markerGuardMetadata.failingSaveCalls = [2]
            let markerGuardSecrets = RunnerHostSecretStore(operationLog: markerGuardLog)
            markerGuardSecrets.seed(Data("old-password".utf8), for: markerGuardID, kind: .password)
            markerGuardSecrets.failNextSetKinds = [.password]
            markerGuardSecrets.failingSetCallNumbers[.credentialRepair] = [2]
            let markerGuardCoordinator = HostCredentialCoordinator(
                metadata: markerGuardMetadata,
                secrets: markerGuardSecrets
            )
            let markerGuardFailure = markerGuardCoordinator.upsert(
                markerGuardEditedHost,
                password: Data("new-password".utf8),
                in: [markerGuardOriginalHost]
            )
            expect(
                markerGuardLog.events == [
                    "set:credential-repair",
                    "metadata:new.example",
                    "set-failed:password",
                    "set:password",
                    "delete:private-key",
                    "metadata-failed:server.example"
                ],
                "metadata rollback failure performs no marker restore or clear",
                &failures
            )
            expect(markerGuardSecrets.setCallCount(for: .credentialRepair) == 1, "metadata rollback failure never attempts the injected marker rewrite", &failures)
            expect(markerGuardFailure.failure == .compensationFailed(original: .password, rollback: .metadata), "metadata rollback failure reports only the attempted boundary", &failures)
            expect(markerGuardFailure.credentialStates[markerGuardID] == .repairRequired && markerGuardCoordinator.inspect(markerGuardMetadata.hosts)[markerGuardID] == .repairRequired, "metadata rollback failure keeps marker protection across restart", &failures)

            let newPasswordHost = try runnerHost(authenticationKind: .password)
            let passwordMetadata = RunnerHostMetadataStore()
            let passwordSecrets = RunnerHostSecretStore()
            passwordSecrets.failingSetKinds = [.password]
            let passwordCoordinator = HostCredentialCoordinator(
                metadata: passwordMetadata,
                secrets: passwordSecrets
            )
            let passwordFailure = passwordCoordinator.upsert(
                newPasswordHost,
                password: Data("credential".utf8),
                in: []
            )
            expect(passwordFailure.hosts.isEmpty, "credential password failure restores the original empty list", &failures)
            expect(passwordMetadata.hosts.isEmpty, "credential password failure durably restores original metadata", &failures)
            expect(passwordFailure.credentialStates[newPasswordHost.id] == nil, "credential password failure does not claim an absent host healthy", &failures)
            expect(passwordFailure.failure == .secretMutation(.password), "credential password failure reports its secret kind", &failures)
            expect(passwordSecrets.hostIDsWithValues.isSubset(of: Set(passwordFailure.hosts.map(\.id))), "credential password failure creates no secret-only UUID", &failures)
            passwordSecrets.failingSetKinds = []
            let passwordRetry = passwordCoordinator.upsert(newPasswordHost, password: Data("credential".utf8), in: passwordFailure.hosts)
            expect(passwordRetry.failure == nil && passwordRetry.credentialStates[newPasswordHost.id] == .ready, "credential password failure can be retried to ready", &failures)

            let switchingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let generatedHost = try runnerHost(id: switchingID, authenticationKind: .generatedKey)
            let passwordHost = try runnerHost(id: switchingID, authenticationKind: .password)
            let keyMetadata = RunnerHostMetadataStore(hosts: [generatedHost])
            let keySecrets = RunnerHostSecretStore()
            keySecrets.seed(Data("generated-key".utf8), for: switchingID, kind: .privateKey)
            keySecrets.failingDeleteKinds = [.privateKey]
            let keyCoordinator = HostCredentialCoordinator(metadata: keyMetadata, secrets: keySecrets)
            let keyFailure = keyCoordinator.upsert(passwordHost, password: Data("credential".utf8), in: [generatedHost])
            expect(keyFailure.hosts == [generatedHost] && keyMetadata.hosts == [generatedHost], "private-key cleanup failure restores original metadata", &failures)
            expect(keyFailure.credentialStates[switchingID] == .ready, "private-key cleanup compensation restores the original host healthy", &failures)
            expect(keyFailure.failure == .secretMutation(.privateKey), "private-key cleanup failure identifies the failing kind", &failures)
            expect(keySecrets.value(for: switchingID, kind: .password) == nil, "private-key cleanup compensation removes the new password", &failures)
            expect(keySecrets.value(for: switchingID, kind: .privateKey) == Data("generated-key".utf8), "private-key cleanup compensation restores the old key", &failures)
            expect(keySecrets.hostIDsWithValues.isSubset(of: Set(keyFailure.hosts.map(\.id))), "private-key cleanup failure creates no secret-only UUID", &failures)

            let compensationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            let compensationOldHost = try runnerHost(id: compensationID, authenticationKind: .generatedKey)
            let compensationUpdatedHost = try runnerHost(id: compensationID, authenticationKind: .password)
            let compensationMetadata = RunnerHostMetadataStore(hosts: [compensationOldHost])
            let compensationSecrets = RunnerHostSecretStore()
            compensationSecrets.seed(Data("old-key".utf8), for: compensationID, kind: .privateKey)
            compensationSecrets.failNextDeleteKinds = [.privateKey]
            compensationSecrets.failingDeleteKinds = [.password]
            let compensationCoordinator = HostCredentialCoordinator(
                metadata: compensationMetadata,
                secrets: compensationSecrets
            )
            let compensationFailure = compensationCoordinator.upsert(
                compensationUpdatedHost,
                password: Data("new-password".utf8),
                in: [compensationOldHost]
            )
            expect(compensationFailure.hosts == [compensationOldHost] && compensationMetadata.hosts == [compensationOldHost], "secret compensation failure still restores visible metadata", &failures)
            expect(compensationFailure.credentialStates[compensationID] == .repairRequired, "secret compensation failure never claims the host ready", &failures)
            expect(compensationFailure.failure == .compensationFailed(original: .privateKey, rollback: .secret(.password)), "secret compensation failure identifies both non-secret boundaries", &failures)
            expect(compensationCoordinator.inspect(compensationMetadata.hosts)[compensationID] == .repairRequired, "secret compensation failure remains derived repair after restart", &failures)
            expect(compensationSecrets.value(for: compensationID, kind: .credentialRepair) != nil, "secret compensation failure persists a repair marker", &failures)

            let metadataRollbackID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            let metadataRollbackOldHost = try SSHHost(
                id: metadataRollbackID,
                label: "Original",
                hostname: "old.example",
                port: 22,
                username: "old-user",
                authenticationKind: .password,
                reconnectPreference: .enabled
            )
            let metadataRollbackUpdatedHost = try SSHHost(
                id: metadataRollbackID,
                label: "Edited",
                hostname: "new.example",
                port: 2222,
                username: "new-user",
                authenticationKind: .password,
                reconnectPreference: .disabled
            )
            let metadataRollbackStore = RunnerHostMetadataStore(hosts: [metadataRollbackOldHost])
            metadataRollbackStore.failingSaveCalls = [2]
            let metadataRollbackSecrets = RunnerHostSecretStore()
            metadataRollbackSecrets.seed(Data("old-password".utf8), for: metadataRollbackID, kind: .password)
            metadataRollbackSecrets.failNextSetKinds = [.password]
            let metadataRollbackCoordinator = HostCredentialCoordinator(
                metadata: metadataRollbackStore,
                secrets: metadataRollbackSecrets
            )
            let metadataRollbackFailure = metadataRollbackCoordinator.upsert(
                metadataRollbackUpdatedHost,
                password: Data("new-password".utf8),
                in: [metadataRollbackOldHost]
            )
            expect(metadataRollbackFailure.hosts == [metadataRollbackUpdatedHost] && metadataRollbackStore.hosts == [metadataRollbackUpdatedHost], "metadata compensation failure keeps persisted edited metadata visible", &failures)
            expect(metadataRollbackFailure.credentialStates[metadataRollbackID] == .repairRequired, "metadata compensation failure never claims the persisted host ready", &failures)
            expect(metadataRollbackFailure.failure == .compensationFailed(original: .password, rollback: .metadata), "metadata compensation failure identifies the metadata boundary", &failures)
            expect(metadataRollbackSecrets.value(for: metadataRollbackID, kind: .credentialRepair) != nil, "metadata compensation failure persists a repair marker", &failures)
            expect(metadataRollbackCoordinator.inspect(metadataRollbackStore.hosts)[metadataRollbackID] == .repairRequired, "metadata compensation failure remains repair-required after restart", &failures)

            let multipleFailureID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
            let multipleFailureOldHost = try runnerHost(id: multipleFailureID, authenticationKind: .generatedKey)
            let multipleFailureUpdatedHost = try runnerHost(id: multipleFailureID, authenticationKind: .password)
            let multipleFailureMetadata = RunnerHostMetadataStore(hosts: [multipleFailureOldHost])
            multipleFailureMetadata.failingSaveCalls = [2]
            let multipleFailureSecrets = RunnerHostSecretStore()
            multipleFailureSecrets.seed(Data("old-key".utf8), for: multipleFailureID, kind: .privateKey)
            multipleFailureSecrets.failNextDeleteKinds = [.privateKey]
            multipleFailureSecrets.failingDeleteKinds = [.password]
            let multipleFailureCoordinator = HostCredentialCoordinator(
                metadata: multipleFailureMetadata,
                secrets: multipleFailureSecrets
            )
            let multipleFailure = multipleFailureCoordinator.upsert(
                multipleFailureUpdatedHost,
                password: Data("new-password".utf8),
                in: [multipleFailureOldHost]
            )
            expect(multipleFailure.hosts == [multipleFailureUpdatedHost] && multipleFailureMetadata.hosts == [multipleFailureUpdatedHost], "multiple compensation failures keep persisted metadata visible", &failures)
            expect(multipleFailure.failure == .compensationFailed(original: .privateKey, rollback: .multiple([.secret(.password), .metadata])), "multiple compensation failures report every non-secret boundary", &failures)
            expect(multipleFailureCoordinator.inspect(multipleFailureMetadata.hosts)[multipleFailureID] == .repairRequired, "multiple compensation failures remain repair-required after restart", &failures)

            let repairHost = try runnerHost(authenticationKind: .password)
            let repairMetadata = RunnerHostMetadataStore(hosts: [repairHost])
            let repairSecrets = RunnerHostSecretStore()
            repairSecrets.seed(Data("old-password".utf8), for: repairHost.id, kind: .password)
            repairSecrets.seed(Data([1]), for: repairHost.id, kind: .credentialRepair)
            let repairCoordinator = HostCredentialCoordinator(metadata: repairMetadata, secrets: repairSecrets)
            let repaired = repairCoordinator.upsert(repairHost, password: Data("new-password".utf8), in: [repairHost])
            expect(repaired.failure == nil && repaired.credentialStates[repairHost.id] == .ready, "successful upsert clears repair-required state", &failures)
            expect(repairSecrets.value(for: repairHost.id, kind: .credentialRepair) == nil, "successful upsert removes the durable repair marker", &failures)

            for failingKind in HostSecretKind.allCases {
                let host = try runnerHost(authenticationKind: .password)
                let metadata = RunnerHostMetadataStore(hosts: [host])
                let secrets = RunnerHostSecretStore()
                for kind in HostSecretKind.allCases {
                    secrets.seed(Data("fixture-\(kind.rawValue)".utf8), for: host.id, kind: kind)
                }
                secrets.failingDeleteKinds = [failingKind]
                let coordinator = HostCredentialCoordinator(metadata: metadata, secrets: secrets)
                let failed = coordinator.delete(host, from: [host])
                expect(failed.hosts == [host] && metadata.hosts == [host], "delete failure for \(failingKind) keeps host visible", &failures)
                expect(failed.failure == .secretDeletion(failingKind), "delete failure identifies \(failingKind)", &failures)
                expect(failed.credentialStates[host.id] == .repairRequired, "delete failure for \(failingKind) marks repair required", &failures)
                expect(secrets.hostIDsWithValues.isSubset(of: Set(failed.hosts.map(\.id))), "delete failure for \(failingKind) creates no orphan", &failures)

                secrets.failingDeleteKinds = []
                let retried = coordinator.delete(host, from: failed.hosts)
                expect(retried.hosts.isEmpty && metadata.hosts.isEmpty, "delete retry after \(failingKind) removes metadata", &failures)
                expect(secrets.hostIDsWithValues.isEmpty, "delete retry after \(failingKind) removes every secret", &failures)
            }

            let saveFailureHost = try runnerHost(authenticationKind: .password)
            let upsertMetadata = RunnerHostMetadataStore()
            upsertMetadata.saveShouldFail = true
            let upsertSecrets = RunnerHostSecretStore()
            let upsertCoordinator = HostCredentialCoordinator(metadata: upsertMetadata, secrets: upsertSecrets)
            let upsertFailure = upsertCoordinator.upsert(saveFailureHost, password: Data("credential".utf8), in: [])
            expect(upsertFailure.hosts.isEmpty, "upsert metadata failure keeps the prior visible list", &failures)
            expect(upsertFailure.failure == .metadataSave, "upsert metadata failure reports metadata boundary", &failures)
            expect(upsertSecrets.mutationCount == 0 && upsertSecrets.hostIDsWithValues.isEmpty, "upsert metadata failure creates no secret-only UUID", &failures)

            let existingSaveFailureHost = try runnerHost(authenticationKind: .password)
            let existingSaveFailureMetadata = RunnerHostMetadataStore(hosts: [existingSaveFailureHost])
            existingSaveFailureMetadata.saveShouldFail = true
            let existingSaveFailureSecrets = RunnerHostSecretStore()
            let existingOldPassword = Data("old-password".utf8)
            existingSaveFailureSecrets.seed(existingOldPassword, for: existingSaveFailureHost.id, kind: .password)
            let existingSaveFailureCoordinator = HostCredentialCoordinator(
                metadata: existingSaveFailureMetadata,
                secrets: existingSaveFailureSecrets
            )
            let existingSaveFailure = existingSaveFailureCoordinator.upsert(
                existingSaveFailureHost,
                password: Data("new-password".utf8),
                in: [existingSaveFailureHost]
            )
            expect(existingSaveFailure.hosts == [existingSaveFailureHost] && existingSaveFailureMetadata.hosts == [existingSaveFailureHost], "existing-host metadata failure preserves original visible metadata", &failures)
            expect(existingSaveFailure.failure == .metadataSave && existingSaveFailure.credentialStates[existingSaveFailureHost.id] == .repairRequired, "existing-host metadata failure returns repair-required", &failures)
            expect(existingSaveFailureSecrets.value(for: existingSaveFailureHost.id, kind: .password) == existingOldPassword, "existing-host metadata failure preserves the old password", &failures)
            expect(existingSaveFailureSecrets.value(for: existingSaveFailureHost.id, kind: .credentialRepair) != nil, "existing-host metadata failure leaves a durable repair marker", &failures)
            expect(existingSaveFailureCoordinator.inspect(existingSaveFailureMetadata.hosts)[existingSaveFailureHost.id] == .repairRequired, "existing-host metadata failure remains repair-required after restart", &failures)

            let deleteMetadata = RunnerHostMetadataStore(hosts: [saveFailureHost])
            deleteMetadata.saveShouldFail = true
            let deleteSecrets = RunnerHostSecretStore()
            deleteSecrets.seed(Data("credential".utf8), for: saveFailureHost.id, kind: .password)
            let deleteCoordinator = HostCredentialCoordinator(metadata: deleteMetadata, secrets: deleteSecrets)
            let deleteFailure = deleteCoordinator.delete(saveFailureHost, from: [saveFailureHost])
            expect(deleteFailure.hosts == [saveFailureHost] && deleteMetadata.hosts == [saveFailureHost], "delete metadata failure keeps host visible", &failures)
            expect(deleteFailure.failure == .metadataSave, "delete metadata failure reports metadata boundary", &failures)
            expect(deleteFailure.credentialStates[saveFailureHost.id] == .repairRequired, "delete metadata failure marks credential repair", &failures)
            expect(deleteSecrets.hostIDsWithValues.isEmpty, "delete metadata failure leaves no secret orphan", &failures)
            expect(deleteCoordinator.inspect(deleteMetadata.hosts)[saveFailureHost.id] != .ready, "delete metadata failure remains non-healthy after restart inspection", &failures)
            deleteMetadata.saveShouldFail = false
            let deleteRetry = deleteCoordinator.delete(saveFailureHost, from: deleteFailure.hosts)
            expect(deleteRetry.failure == nil && deleteRetry.hosts.isEmpty && deleteMetadata.hosts.isEmpty, "delete metadata failure can be retried to completion", &failures)
        } catch {
            failures.append("host credential transaction runner completes: \(error)")
        }
    }

    private static func checkSSHConnectionStateAndReconnect(_ failures: inout [String]) {
        var reducer = SSHConnectionStateReducer()
        let staleGeneration = reducer.beginConnection()
        let generation = reducer.beginConnection()
        expect(generation > staleGeneration, "SSH session generation increases monotonically", &failures)
        expect(!reducer.reduce(.hostKeyValidated, generation: staleGeneration), "stale SSH callbacks are rejected", &failures)
        expect(reducer.state == .connecting, "stale SSH callback does not mutate state", &failures)
        expect(reducer.reduce(.hostKeyValidationRequired, generation: generation), "first-use host key pauses the current session", &failures)
        expect(reducer.state == .awaitingHostTrust, "host trust state is observable", &failures)
        expect(reducer.reduce(.hostKeyValidated, generation: generation), "trusted host key begins authentication", &failures)
        expect(reducer.reduce(.authenticationSucceeded, generation: generation), "authenticated SSH session connects", &failures)

        expect(reducer.reduce(.hostKeyValidationRequired, generation: generation), "connected rekey pauses for explicit replacement trust", &failures)
        expect(reducer.state == .awaitingHostTrust, "rekey trust is observable", &failures)
        expect(reducer.reduce(.hostKeyRevalidated, generation: generation), "confirmed rekey resumes the connected session", &failures)
        expect(reducer.state == .connected, "confirmed rekey does not restart user authentication", &failures)

        let reconnectGeneration = reducer.beginReconnect(attempt: 1)
        expect(reconnectGeneration > generation, "SSH reconnect advances the session generation", &failures)
        expect(!reducer.reduce(.failed(.transport), generation: generation), "reconnect rejects the prior attempt callback", &failures)

        let disconnectedGeneration = reducer.disconnect()
        expect(disconnectedGeneration > reconnectGeneration, "manual disconnect invalidates the session generation", &failures)
        expect(!reducer.reduce(.failed(.transport), generation: reconnectGeneration), "disconnected session rejects in-flight failures", &failures)

        var reconnect = SSHReconnectOrchestrator(isEnabled: true)
        reconnect.userInitiatedConnection()
        reconnect.connectionEstablished()
        let expected = [
            SSHReconnectDirective(attempt: 1, delay: .seconds(1)),
            SSHReconnectDirective(attempt: 2, delay: .seconds(2)),
            SSHReconnectDirective(attempt: 3, delay: .seconds(4))
        ]
        expect(reconnect.connectionFailed(.transportLoss) == expected[0], "first reconnect waits one second", &failures)
        expect(reconnect.connectionFailed(.transportLoss) == expected[1], "second reconnect waits two seconds", &failures)
        expect(reconnect.connectionFailed(.transportLoss) == expected[2], "third reconnect waits four seconds", &failures)
        expect(reconnect.connectionFailed(.transportLoss) == nil, "fourth reconnect is not scheduled", &failures)

        var foreground = SSHReconnectOrchestrator(isEnabled: true)
        foreground.userInitiatedConnection()
        foreground.connectionEstablished()
        expect(foreground.scenePhaseChanged(isActive: false) == nil, "inactive scene schedules no work", &failures)
        expect(foreground.connectionFailed(.transportLoss) == nil, "inactive scene blocks transport retry", &failures)
        expect(foreground.scenePhaseChanged(isActive: true) == expected[0], "active scene resumes a wanted connection", &failures)
        foreground.manualDisconnect()
        expect(foreground.scenePhaseChanged(isActive: false) == nil, "manual disconnect remains idle when inactive", &failures)
        expect(foreground.scenePhaseChanged(isActive: true) == nil, "manual disconnect does not reconnect on activation", &failures)

        for failure in [SSHConnectionFailure.authenticationRejected, .hostKeyMismatch] {
            var secureStop = SSHReconnectOrchestrator(isEnabled: true)
            secureStop.userInitiatedConnection()
            expect(secureStop.connectionFailed(failure) == nil, "security failure schedules no reconnect", &failures)
            expect(!secureStop.wantsConnection, "security failure cancels reconnect intent", &failures)
        }
    }

    private static func checkAcceptanceFlow(_ failures: inout [String]) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteTerm-Runner-Acceptance-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            var flow = TerminalFlowStateReducer(initialWorkspaceID: root.path)
            let shell = LocalShell(rootURL: root)

            flow.selectLocalWorkspace(id: root.path)
            expect(flow.activeMode == .local, "acceptance starts in Local mode", &failures)
            expect(flow.activeSSHConnectionCount == 0, "acceptance starts without SSH", &failures)

            let touch = await shell.execute("touch draft.txt")
            let initialListing = await shell.execute("ls")
            let emptyContent = await shell.execute("cat draft.txt")
            expect(touch.outputLines.isEmpty, "acceptance touch succeeds", &failures)
            expect(initialListing.outputLines == ["draft.txt"], "acceptance ls sees the touched file", &failures)
            expect(emptyContent.outputLines.isEmpty, "acceptance cat reads the empty file", &failures)

            let edit = await shell.execute("edit draft.txt")
            guard let editorURL = edit.editorURL else {
                failures.append("acceptance edit produces a native editor intent")
                return
            }
            try Data("edited on iPad\n".utf8).write(to: editorURL)
            let editedContent = await shell.execute("cat draft.txt")
            expect(
                editedContent.outputLines == ["edited on iPad", ""],
                "acceptance cat reads the edited file",
                &failures
            )

            let host = try runnerHost(authenticationKind: .password)
            flow.selectSSHHost(id: host.id)
            var ssh = SSHConnectionStateReducer()
            let sshGeneration = ssh.beginConnection()
            expect(
                flow.beginSSHConnection(generation: sshGeneration, state: ssh.state),
                "acceptance connects the selected SSH host",
                &failures
            )
            expect(flow.activeMode == .ssh, "acceptance switches to SSH mode", &failures)
            expect(flow.activeSSHConnectionCount == 1, "acceptance has one SSH connection", &failures)

            expect(ssh.reduce(.hostKeyValidated, generation: sshGeneration), "acceptance validates the SSH host key", &failures)
            expect(flow.updateSSHConnectionState(ssh.state, generation: sshGeneration), "acceptance observes SSH authentication", &failures)
            expect(ssh.reduce(.authenticationSucceeded, generation: sshGeneration), "acceptance authenticates SSH", &failures)
            expect(flow.updateSSHConnectionState(ssh.state, generation: sshGeneration), "acceptance observes connected SSH", &failures)

            let remoteCommand = Array("pwd\r".utf8)
            expect(flow.routeRemoteInput(remoteCommand) == remoteCommand, "acceptance sends input only to connected SSH", &failures)

            _ = ssh.disconnect()
            flow.disconnectSSH()
            expect(flow.activeSSHConnectionCount == 0, "acceptance disconnect removes the SSH connection", &failures)
            expect(flow.routeRemoteInput(remoteCommand) == nil, "disconnected SSH rejects input", &failures)

            flow.returnToLocal()
            expect(flow.activeMode == .local, "acceptance returns to Local mode", &failures)
            let localReturnListing = await shell.execute("ls")
            expect(localReturnListing.outputLines == ["draft.txt"], "Local return retains the selected workspace", &failures)
        } catch {
            failures.append("acceptance flow completes with real temporary files: \(error)")
        }
    }

    private static func runnerHost(
        id: UUID = UUID(),
        authenticationKind: SSHAuthenticationKind
    ) throws -> SSHHost {
        try SSHHost(
            id: id,
            label: "Primary",
            hostname: "server.example",
            port: 22,
            username: "alice",
            authenticationKind: authenticationKind,
            reconnectPreference: .enabled
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        _ failures: inout [String]
    ) {
        if !condition() {
            failures.append(message)
        }
    }

    private static func finish(_ failures: [String], passingCheckCount: Int) {
        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }

        print("PASS: \(passingCheckCount) LiteTermCore checks")
    }
}

private struct RunnerFileSystem: LocalFileSystemAccess {
    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { true }
    func list(at url: URL) throws -> [String] { ["coordinated-entry"] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        throw LocalFileSystemError.deletionRequestExpired
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity { throw LocalFileSystemError.fileIdentityUnavailable }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private struct RunnerInspectingFileSystem: LocalFileSystemAccess {
    let symbolicLinks: [String: String]

    init(symbolicLinks: [String: String] = [:]) {
        self.symbolicLinks = symbolicLinks
    }

    func symbolicLinkDestination(at url: URL) throws -> String? { symbolicLinks[url.path] }
    func isDirectory(at url: URL) throws -> Bool { true }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        throw LocalFileSystemError.deletionRequestExpired
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity { throw LocalFileSystemError.fileIdentityUnavailable }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private final class RunnerIdentityMismatchFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private(set) var revalidationCallCount = 0
    private(set) var didDelete = false

    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        PreparedDeletion(
            targetURL: rootURL.appendingPathComponent(userPath),
            rootRelativePath: userPath,
            fileIdentity: LocalFileIdentity(resourceIdentifier: Data([0x01]))
        )
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x01]))
    }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {
        revalidationCallCount += 1
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private final class RunnerRequestPreparationRaceFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    private var replacementIsSymlink = false
    private(set) var prepareCallCount = 0

    func symbolicLinkDestination(at url: URL) throws -> String? {
        guard url.lastPathComponent == "target.txt" else { return nil }
        return replacementIsSymlink ? "replacement.txt" : nil
    }
    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        prepareCallCount += 1
        let resolver = WorkspacePathResolver(rootURL: rootURL, currentDirectoryURL: currentDirectoryURL, pathInspector: self)
        _ = try resolver.resolveWithoutSymbolicLinks(userPath)
        replacementIsSymlink = true
        do {
            _ = try resolver.resolveWithoutSymbolicLinks(userPath)
        } catch {
            throw LocalFileSystemError.deletionRequestExpired
        }
        throw LocalFileSystemError.deletionRequestExpired
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x02]))
    }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {
        throw LocalFileSystemError.deletionRequestExpired
    }
}

private final class RunnerMismatchedPreparedDeletionFileSystem: LocalFileSystemAccess, @unchecked Sendable {
    func symbolicLinkDestination(at url: URL) throws -> String? { nil }
    func isDirectory(at url: URL) throws -> Bool { false }
    func list(at url: URL) throws -> [String] { [] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func prepareDeletion(rootURL: URL, currentDirectoryURL: URL, userPath: String) throws -> PreparedDeletion {
        PreparedDeletion(
            targetURL: rootURL.appendingPathComponent("target.txt"),
            rootRelativePath: "replacement.txt",
            fileIdentity: LocalFileIdentity(resourceIdentifier: Data([0x03]))
        )
    }
    func deletionIdentity(at url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(resourceIdentifier: Data([0x03]))
    }
    func revalidateAndRemoveFile(rootURL: URL, rootRelativePath: String, expectedIdentity: LocalFileIdentity) throws {}
}

private actor RunnerDelayedOperationGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RunnerOperationRecorder {
    private var recorded: [String] = []

    func append(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private enum RunnerHostStoreFailure: Error {
    case injected
}

private final class RunnerHostOperationLog {
    private(set) var events: [String] = []
    var onEvent: ((String) -> Void)?

    func record(_ event: String) {
        events.append(event)
        onEvent?(event)
    }
}

private final class RunnerHostMetadataStore: HostMetadataStoring {
    var hosts: [SSHHost]
    var saveShouldFail = false
    var failingSaveCalls: Set<Int> = []
    private(set) var saveCallCount = 0
    private let operationLog: RunnerHostOperationLog?

    init(hosts: [SSHHost] = [], operationLog: RunnerHostOperationLog? = nil) {
        self.hosts = hosts
        self.operationLog = operationLog
    }

    func save(_ hosts: [SSHHost]) throws {
        saveCallCount += 1
        guard !saveShouldFail, !failingSaveCalls.contains(saveCallCount) else {
            operationLog?.record("metadata-failed:\(hosts.map(\.hostname).joined(separator: ","))")
            throw RunnerHostStoreFailure.injected
        }
        self.hosts = hosts
        operationLog?.record("metadata:\(hosts.map(\.hostname).joined(separator: ","))")
    }
}

private final class RunnerHostSecretStore: HostSecretStoring {
    private struct Key: Hashable {
        let hostID: UUID
        let kind: HostSecretKind
    }

    var failingSetKinds: Set<HostSecretKind> = []
    var failNextSetKinds: Set<HostSecretKind> = []
    var failingSetCallNumbers: [HostSecretKind: Set<Int>] = [:]
    var failingDeleteKinds: Set<HostSecretKind> = []
    var failNextDeleteKinds: Set<HostSecretKind> = []
    private(set) var mutationCount = 0
    private var values: [Key: Data] = [:]
    private var setCallCounts: [HostSecretKind: Int] = [:]
    private let operationLog: RunnerHostOperationLog?

    init(operationLog: RunnerHostOperationLog? = nil) {
        self.operationLog = operationLog
    }

    var hostIDsWithValues: Set<UUID> {
        Set(values.keys.map(\.hostID))
    }

    func seed(_ data: Data, for hostID: UUID, kind: HostSecretKind) {
        values[Key(hostID: hostID, kind: kind)] = data
    }

    func value(for hostID: UUID, kind: HostSecretKind) -> Data? {
        values[Key(hostID: hostID, kind: kind)]
    }

    func setCallCount(for kind: HostSecretKind) -> Int {
        setCallCounts[kind, default: 0]
    }

    func set(_ data: Data, for hostID: UUID, kind: HostSecretKind) throws {
        mutationCount += 1
        setCallCounts[kind, default: 0] += 1
        if failingSetCallNumbers[kind, default: []].contains(setCallCounts[kind, default: 0]) {
            operationLog?.record("set-failed:\(kind.rawValue)")
            throw RunnerHostStoreFailure.injected
        }
        if failNextSetKinds.remove(kind) != nil {
            operationLog?.record("set-failed:\(kind.rawValue)")
            throw RunnerHostStoreFailure.injected
        }
        guard !failingSetKinds.contains(kind) else {
            operationLog?.record("set-failed:\(kind.rawValue)")
            throw RunnerHostStoreFailure.injected
        }
        values[Key(hostID: hostID, kind: kind)] = data
        operationLog?.record("set:\(kind.rawValue)")
    }

    func data(for hostID: UUID, kind: HostSecretKind) throws -> Data? {
        values[Key(hostID: hostID, kind: kind)]
    }

    func delete(for hostID: UUID, kind: HostSecretKind) throws {
        mutationCount += 1
        if failNextDeleteKinds.remove(kind) != nil {
            operationLog?.record("delete-failed:\(kind.rawValue)")
            throw RunnerHostStoreFailure.injected
        }
        guard !failingDeleteKinds.contains(kind) else {
            operationLog?.record("delete-failed:\(kind.rawValue)")
            throw RunnerHostStoreFailure.injected
        }
        values.removeValue(forKey: Key(hostID: hostID, kind: kind))
        operationLog?.record("delete:\(kind.rawValue)")
    }
}
