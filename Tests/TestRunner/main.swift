import Darwin
import Foundation
import LiteTermCore

@main
struct LiteTermCoreTestRunner {
    static func main() async {
        var failures: [String] = []

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

        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }

        print("PASS: 17 LiteTermCore checks")
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

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        _ failures: inout [String]
    ) {
        if !condition() {
            failures.append(message)
        }
    }
}

private struct RunnerFileSystem: LocalFileSystemAccess {
    func list(at url: URL) throws -> [String] { ["coordinated-entry"] }
    func readText(at url: URL) throws -> String { "" }
    func prepareForEditing(at url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func touch(at url: URL) throws {}
    func copyItem(from source: URL, to destination: URL) throws {}
    func moveItem(from source: URL, to destination: URL) throws {}
    func removeFile(at url: URL) throws {}
}
