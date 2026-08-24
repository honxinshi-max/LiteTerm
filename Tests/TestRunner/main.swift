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

        checkHistoryDropsOldestLine(&failures)
        checkHistoryClear(&failures)
        checkZeroHistoryLimit(&failures)
        checkOversizedHistoryLimit(&failures)
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
        await checkCoordinatedPathInspection(&failures)
        failures.append(contentsOf: await checkLocalOperationQueue())
        checkHostRepository(&failures)
        checkKnownHostPolicy(&failures)
        checkReconnectPolicy(&failures)

        finish(failures, passingCheckCount: 24)
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

        for index in 0...2_000 {
            history.append("\(index)")
        }

        expect(history.lines.count == 2_000, "oversized history limit is capped at 2,000 lines", &failures)
        expect(history.lines.first == "1", "oversized history drops its oldest line", &failures)
        expect(history.lines.last == "2000", "oversized history retains its newest line", &failures)
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
            let removed = await shell.execute("rm moved.txt")
            let rootRemoval = await shell.execute("rm /")
            let directoryRemoval = await shell.execute("rm .")

            expect(createdDirectory.outputLines.isEmpty, "local shell creates one directory", &failures)
            let canonicalRoot = try WorkspacePathResolver(rootURL: root, currentDirectoryURL: root).resolve("/")
            expect(changedDirectory.directoryChange?.path == canonicalRoot.appendingPathComponent("docs").path, "local shell changes directory", &failures)
            expect(workingDirectory.outputLines == ["/docs"], "local shell reports virtual working directory", &failures)
            expect(touched.outputLines.isEmpty, "local shell creates one file", &failures)
            expect(listed.outputLines == ["source.txt"], "local shell lists a directory", &failures)
            expect(read.outputLines == ["hello"], "local shell reads UTF-8 text", &failures)
            expect(copied.outputLines.isEmpty, "local shell copies one file", &failures)
            expect(moved.outputLines.isEmpty, "local shell moves one file", &failures)
            expect(removed.outputLines.isEmpty, "local shell removes one file", &failures)
            expect(!fileManager.fileExists(atPath: root.appendingPathComponent("docs/moved.txt").path), "local shell removal changes the temporary fixture", &failures)
            expect(rootRemoval.outputLines == ["Error: workspace root cannot be removed"], "local shell rejects workspace root removal", &failures)
            expect(directoryRemoval.outputLines == ["Error: directories cannot be removed"], "local shell rejects directory removal", &failures)
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
            KnownHostPolicy.evaluate(savedFingerprint: " SHA256:\(fingerprint)= ", presentedFingerprint: "sha256:\(fingerprint)") == .trusted,
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
    func removeFile(at url: URL) throws {}
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
    func removeFile(at url: URL) throws {}
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
