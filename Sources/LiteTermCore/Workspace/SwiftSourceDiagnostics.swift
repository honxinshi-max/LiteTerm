import Foundation

public enum SwiftSourceDiagnostics {
    public static let maximumProblems = 100

    public static func inspect(data: Data, relativePath: String) -> [WorkspaceProblem] {
        guard let source = String(data: data, encoding: .utf8) else {
            return problem(
                relativePath: relativePath,
                line: nil,
                column: nil,
                message: "Invalid UTF-8 source encoding."
            ).map { [$0] } ?? []
        }

        var problems: [WorkspaceProblem] = []
        appendConflictMarkers(in: source, relativePath: relativePath, to: &problems)
        inspectStructure(in: source, relativePath: relativePath, problems: &problems)
        return Array(problems.prefix(maximumProblems))
    }

    private struct Delimiter {
        let character: Character
        let line: Int
        let column: Int
    }

    private enum ScannerState {
        case normal
        case lineComment
        case blockComment(depth: Int, line: Int, column: Int)
        case string(line: Int, column: Int)
        case multilineString(line: Int, column: Int)
    }

    private static func inspectStructure(
        in source: String,
        relativePath: String,
        problems: inout [WorkspaceProblem]
    ) {
        let characters = Array(source)
        var state = ScannerState.normal
        var stack: [Delimiter] = []
        var index = 0
        var line = 1
        var column = 1

        func character(at offset: Int) -> Character? {
            let position = index + offset
            return characters.indices.contains(position) ? characters[position] : nil
        }

        func advance(_ count: Int = 1) {
            for _ in 0..<count where index < characters.count {
                if characters[index] == "\n" {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
                index += 1
            }
        }

        while index < characters.count, problems.count < maximumProblems {
            let current = characters[index]
            switch state {
            case .normal:
                if current == "/", character(at: 1) == "/" {
                    state = .lineComment
                    advance(2)
                } else if current == "/", character(at: 1) == "*" {
                    state = .blockComment(depth: 1, line: line, column: column)
                    advance(2)
                } else if current == "\"", character(at: 1) == "\"", character(at: 2) == "\"" {
                    state = .multilineString(line: line, column: column)
                    advance(3)
                } else if current == "\"" {
                    state = .string(line: line, column: column)
                    advance()
                } else if "([{<".contains(current) {
                    if current != "<" {
                        stack.append(Delimiter(character: current, line: line, column: column))
                    }
                    advance()
                } else if ")]}>".contains(current) {
                    if current == ">" {
                        advance()
                        continue
                    }
                    let expectedOpening: Character = current == ")" ? "(" : (current == "]" ? "[" : "{")
                    if stack.last?.character == expectedOpening {
                        _ = stack.popLast()
                    } else {
                        append(
                            relativePath: relativePath,
                            line: line,
                            column: column,
                            message: "Unexpected '\(current)' delimiter.",
                            to: &problems
                        )
                    }
                    advance()
                } else {
                    advance()
                }

            case .lineComment:
                if current == "\n" {
                    state = .normal
                }
                advance()

            case let .blockComment(depth, startLine, startColumn):
                if current == "/", character(at: 1) == "*" {
                    state = .blockComment(depth: depth + 1, line: startLine, column: startColumn)
                    advance(2)
                } else if current == "*", character(at: 1) == "/" {
                    if depth == 1 {
                        state = .normal
                    } else {
                        state = .blockComment(depth: depth - 1, line: startLine, column: startColumn)
                    }
                    advance(2)
                } else {
                    advance()
                }

            case let .string(startLine, startColumn):
                if current == "\\" {
                    advance(min(2, characters.count - index))
                } else if current == "\"" {
                    state = .normal
                    advance()
                } else if current == "\n" {
                    append(
                        relativePath: relativePath,
                        line: startLine,
                        column: startColumn,
                        message: "Unterminated string literal.",
                        to: &problems
                    )
                    state = .normal
                    advance()
                } else {
                    advance()
                }

            case .multilineString:
                if current == "\"", character(at: 1) == "\"", character(at: 2) == "\"" {
                    state = .normal
                    advance(3)
                } else if current == "\\" {
                    advance(min(2, characters.count - index))
                } else {
                    advance()
                }
            }
        }

        switch state {
        case let .blockComment(_, line, column):
            append(
                relativePath: relativePath,
                line: line,
                column: column,
                message: "Unterminated block comment.",
                to: &problems
            )
        case let .string(line, column):
            append(
                relativePath: relativePath,
                line: line,
                column: column,
                message: "Unterminated string literal.",
                to: &problems
            )
        case let .multilineString(line, column):
            append(
                relativePath: relativePath,
                line: line,
                column: column,
                message: "Unterminated multiline string literal.",
                to: &problems
            )
        case .normal, .lineComment:
            break
        }

        for opening in stack.reversed() where problems.count < maximumProblems {
            append(
                relativePath: relativePath,
                line: opening.line,
                column: opening.column,
                message: "Unclosed '\(opening.character)' delimiter.",
                to: &problems
            )
        }
    }

    private static func appendConflictMarkers(
        in source: String,
        relativePath: String,
        to problems: inout [WorkspaceProblem]
    ) {
        for (offset, sourceLine) in source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            guard problems.count < maximumProblems else { return }
            let trimmed = sourceLine.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("<<<<<<<")
                    || trimmed.hasPrefix("=======")
                    || trimmed.hasPrefix(">>>>>>>") else { continue }
            append(
                relativePath: relativePath,
                line: offset + 1,
                column: sourceLine.count - trimmed.count + 1,
                message: "Unresolved source-control conflict marker.",
                to: &problems
            )
        }
    }

    private static func append(
        relativePath: String,
        line: Int?,
        column: Int?,
        message: String,
        to problems: inout [WorkspaceProblem]
    ) {
        guard problems.count < maximumProblems,
              let value = problem(
                relativePath: relativePath,
                line: line,
                column: column,
                message: message
              ) else { return }
        problems.append(value)
    }

    private static func problem(
        relativePath: String,
        line: Int?,
        column: Int?,
        message: String
    ) -> WorkspaceProblem? {
        try? WorkspaceProblem(
            stage: .check,
            severity: .error,
            category: .syntax,
            relativePath: relativePath,
            line: line,
            column: column,
            message: message,
            recoveryAction: "Correct the source and run Check again."
        )
    }
}
