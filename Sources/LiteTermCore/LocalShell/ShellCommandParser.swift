import Foundation

public enum ShellCommandParserError: Error, Equatable, Sendable {
    case emptyCommand
    case unknownCommand(String)
    case wrongArity(command: String)
    case unterminatedQuote
    case unterminatedEscape
}

public struct ShellCommandParser: Sendable {
    public init() {}

    public func parse(_ input: String) throws -> ShellCommand {
        let tokens = try tokenize(input)
        guard let command = tokens.first else {
            throw ShellCommandParserError.emptyCommand
        }

        let arguments = Array(tokens.dropFirst())
        switch command {
        case "pwd":
            try requireArity(arguments, command: command, allowed: 0...0)
            return .pwd
        case "ls":
            try requireArity(arguments, command: command, allowed: 0...1)
            return .ls(path: arguments.first)
        case "cd":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .cd(path: arguments[0])
        case "cat":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .cat(path: arguments[0])
        case "mkdir":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .mkdir(path: arguments[0])
        case "touch":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .touch(path: arguments[0])
        case "cp":
            try requireArity(arguments, command: command, allowed: 2...2)
            return .copy(source: arguments[0], destination: arguments[1])
        case "mv":
            try requireArity(arguments, command: command, allowed: 2...2)
            return .move(source: arguments[0], destination: arguments[1])
        case "rm":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .remove(path: arguments[0])
        case "clear":
            try requireArity(arguments, command: command, allowed: 0...0)
            return .clear
        case "edit":
            try requireArity(arguments, command: command, allowed: 1...1)
            return .edit(path: arguments[0])
        default:
            throw ShellCommandParserError.unknownCommand(command)
        }
    }

    private func requireArity(_ arguments: [String], command: String, allowed: ClosedRange<Int>) throws {
        guard allowed.contains(arguments.count) else {
            throw ShellCommandParserError.wrongArity(command: command)
        }
    }

    private func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isBuildingToken = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    self.advance(&index, in: input)
                    quote = nil
                } else if character == "\\" {
                    self.advance(&index, in: input)
                    guard index < input.endIndex else {
                        throw ShellCommandParserError.unterminatedEscape
                    }
                    current.append(input[index])
                    self.advance(&index, in: input)
                } else {
                    current.append(character)
                    self.advance(&index, in: input)
                }
                isBuildingToken = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                isBuildingToken = true
            } else if character.isWhitespace {
                if isBuildingToken {
                    tokens.append(current)
                    current = ""
                    isBuildingToken = false
                }
            } else if character == "\\" {
                self.advance(&index, in: input)
                guard index < input.endIndex else {
                    throw ShellCommandParserError.unterminatedEscape
                }
                current.append(input[index])
                isBuildingToken = true
            } else {
                current.append(character)
                isBuildingToken = true
            }
            self.advance(&index, in: input)
        }

        guard quote == nil else {
            throw ShellCommandParserError.unterminatedQuote
        }
        if isBuildingToken {
            tokens.append(current)
        }
        return tokens
    }

    private func advance(_ index: inout String.Index, in input: String) {
        index = input.index(after: index)
    }
}
