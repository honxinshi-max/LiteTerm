#include "LiteSpacePythonBridge.h"

#include <string.h>

static bool LTStartsWith(const char *value, const char *prefix) {
    return value != NULL && prefix != NULL
        && strncmp(value, prefix, strlen(prefix)) == 0;
}

bool LTIsSafePythonRelativePath(const char *relative_path) {
    if (relative_path == NULL || relative_path[0] == '\0'
        || relative_path[0] == '/' || strchr(relative_path, '\\') != NULL) {
        return false;
    }

    const char *component = relative_path;
    while (*component != '\0') {
        const char *separator = strchr(component, '/');
        size_t length = separator == NULL
            ? strlen(component)
            : (size_t)(separator - component);
        if (length == 0 || component[0] == '.'
            || (length == 2 && component[0] == '.' && component[1] == '.')) {
            return false;
        }
        component = separator == NULL ? component + length : separator + 1;
    }

    const char *extension = strrchr(relative_path, '.');
    if (extension != NULL && (
        strcmp(extension, ".so") == 0
        || strcmp(extension, ".dylib") == 0
        || strcmp(extension, ".framework") == 0
        || strcmp(extension, ".pyc") == 0
    )) {
        return false;
    }
    return true;
}

bool LTIsDeniedPythonAuditEvent(const char *event_name) {
    if (event_name == NULL || event_name[0] == '\0') {
        return true;
    }
    static const char *const denied_prefixes[] = {
        "socket.",
        "subprocess.",
        "multiprocessing.",
        "ctypes.",
        "os.system",
        "os.spawn",
        "os.exec",
        "os.fork",
        "posix.system",
        "pty.",
        "resource.setrlimit"
    };
    const size_t count = sizeof(denied_prefixes) / sizeof(denied_prefixes[0]);
    for (size_t index = 0; index < count; index += 1) {
        if (LTStartsWith(event_name, denied_prefixes[index])) {
            return true;
        }
    }
    return false;
}

bool LTIsAllowedPythonImport(const char *module_name) {
    if (module_name == NULL || module_name[0] == '\0') {
        return false;
    }
    static const char *const allowed_roots[] = {
        "__future__", "abc", "collections", "contextlib", "dataclasses",
        "datetime", "decimal", "enum", "functools", "hashlib", "html",
        "io", "itertools", "json", "math", "operator", "re", "statistics",
        "string", "sys", "time", "types", "typing", "unittest", "urllib",
        "wsgiref"
    };
    char root[64];
    const char *separator = strchr(module_name, '.');
    size_t length = separator == NULL ? strlen(module_name) : (size_t)(separator - module_name);
    if (length == 0 || length >= sizeof(root)) {
        return false;
    }
    memcpy(root, module_name, length);
    root[length] = '\0';
    const size_t count = sizeof(allowed_roots) / sizeof(allowed_roots[0]);
    for (size_t index = 0; index < count; index += 1) {
        if (strcmp(root, allowed_roots[index]) == 0) {
            return true;
        }
    }
    return false;
}
