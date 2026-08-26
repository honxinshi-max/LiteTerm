public enum PythonRunDisposition: Equatable, Sendable {
    case script(entrypoint: String)
    case wsgi(entrypoint: String, callable: String)
}
