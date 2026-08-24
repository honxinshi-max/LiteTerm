public enum ShellCommand: Equatable, Sendable {
    case pwd
    case ls(path: String?)
    case cd(path: String)
    case cat(path: String)
    case mkdir(path: String)
    case touch(path: String)
    case copy(source: String, destination: String)
    case move(source: String, destination: String)
    case remove(path: String)
    case clear
    case edit(path: String)
}
