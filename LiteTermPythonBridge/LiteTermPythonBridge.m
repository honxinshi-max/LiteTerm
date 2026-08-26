#include "LiteTermPythonBridge.h"

#include <stdatomic.h>

struct LTPythonRuntime {
    atomic_bool cancelled;
};

static _Thread_local LTPythonErrorCode LTLastPythonError = LT_PYTHON_ERROR_NONE;

bool LTIsPythonRuntimeAvailable(void) {
    return false;
}

LTPythonErrorCode LTGetPythonLastError(void) {
    return LTLastPythonError;
}

static bool LTUnavailable(void) {
    LTLastPythonError = LT_PYTHON_ERROR_RUNTIME_UNAVAILABLE;
    return false;
}

LTPythonRuntime *LTCreatePythonRuntime(
    const LTPythonConfiguration *configuration,
    LTOutputCallback output,
    LTProblemCallback problem
) {
    (void)configuration;
    (void)output;
    (void)problem;
    LTUnavailable();
    return NULL;
}

bool LTCompilePythonFile(LTPythonRuntime *runtime, const char *relative_path) {
    (void)runtime;
    (void)relative_path;
    return LTUnavailable();
}

bool LTRunPythonUnittestDiscovery(LTPythonRuntime *runtime, const char *start_relative_path) {
    (void)runtime;
    (void)start_relative_path;
    return LTUnavailable();
}

bool LTRunPythonScript(LTPythonRuntime *runtime, const char *entrypoint) {
    (void)runtime;
    (void)entrypoint;
    return LTUnavailable();
}

bool LTPrepareWSGIApplication(
    LTPythonRuntime *runtime,
    const char *entrypoint,
    const char *name
) {
    (void)runtime;
    (void)entrypoint;
    (void)name;
    return LTUnavailable();
}

bool LTCallWSGIApplication(
    LTPythonRuntime *runtime,
    const LTHTTPRequest *request,
    LTHTTPResponse *response
) {
    (void)runtime;
    (void)request;
    (void)response;
    return LTUnavailable();
}

void LTCancelPythonRuntime(LTPythonRuntime *runtime) {
    if (runtime != NULL) {
        atomic_store_explicit(&runtime->cancelled, true, memory_order_relaxed);
    }
}

void LTDestroyPythonRuntime(LTPythonRuntime *runtime) {
    (void)runtime;
}
