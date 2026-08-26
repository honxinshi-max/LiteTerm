#ifndef LITETERM_PYTHON_BRIDGE_H
#define LITETERM_PYTHON_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LTPythonRuntime LTPythonRuntime;
typedef struct LTPythonRequest LTPythonRequest;

typedef enum {
    LT_PYTHON_ERROR_NONE = 0,
    LT_PYTHON_ERROR_RUNTIME_UNAVAILABLE = 1,
    LT_PYTHON_ERROR_INVALID_CONFIGURATION = 2,
    LT_PYTHON_ERROR_CANCELLED = 3,
    LT_PYTHON_ERROR_DEADLINE = 4,
    LT_PYTHON_ERROR_POLICY_DENIED = 5,
    LT_PYTHON_ERROR_COMPILE = 6,
    LT_PYTHON_ERROR_TEST = 7,
    LT_PYTHON_ERROR_RUNTIME = 8,
    LT_PYTHON_ERROR_RESPONSE_LIMIT = 9
} LTPythonErrorCode;

typedef struct {
    const char *relative_path;
    const uint8_t *bytes;
    size_t byte_count;
} LTPythonSourceFile;

typedef struct {
    const LTPythonSourceFile *sources;
    size_t source_count;
    const char *const *allowed_imports;
    size_t allowed_import_count;
    const char *standard_library_root;
    uint64_t generation;
    uint64_t instruction_limit;
    uint64_t deadline_monotonic_nanoseconds;
    size_t output_line_limit;
    size_t output_byte_limit;
    size_t request_byte_limit;
    size_t response_byte_limit;
    void *callback_context;
} LTPythonConfiguration;

typedef void (*LTOutputCallback)(
    void *context,
    bool is_standard_error,
    const uint8_t *utf8_bytes,
    size_t byte_count
);

typedef void (*LTProblemCallback)(
    void *context,
    LTPythonErrorCode code,
    const char *relative_path,
    int32_t line,
    int32_t column,
    const uint8_t *message_utf8,
    size_t message_byte_count
);

typedef struct {
    const char *method;
    const char *relative_path;
    const char *query;
    const uint8_t *body;
    size_t body_byte_count;
} LTHTTPRequest;

typedef struct {
    int32_t status;
    uint8_t *body;
    size_t body_capacity;
    size_t body_byte_count;
} LTHTTPResponse;

bool LTIsPythonRuntimeAvailable(void);
LTPythonErrorCode LTGetPythonLastError(void);

LTPythonRuntime *LTCreatePythonRuntime(
    const LTPythonConfiguration *configuration,
    LTOutputCallback output,
    LTProblemCallback problem
);
bool LTCompilePythonFile(LTPythonRuntime *runtime, const char *relative_path);
bool LTRunPythonUnittestDiscovery(LTPythonRuntime *runtime, const char *start_relative_path);
bool LTRunPythonScript(LTPythonRuntime *runtime, const char *entrypoint);
bool LTPrepareWSGIApplication(
    LTPythonRuntime *runtime,
    const char *entrypoint,
    const char *name
);
bool LTCallWSGIApplication(
    LTPythonRuntime *runtime,
    const LTHTTPRequest *request,
    LTHTTPResponse *response
);
void LTCancelPythonRuntime(LTPythonRuntime *runtime);
void LTDestroyPythonRuntime(LTPythonRuntime *runtime);

bool LTIsSafePythonRelativePath(const char *relative_path);
bool LTIsDeniedPythonAuditEvent(const char *event_name);
bool LTIsAllowedPythonImport(const char *module_name);

#ifdef __cplusplus
}
#endif

#endif
