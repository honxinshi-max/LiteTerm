#ifndef LITETERM_PYTHON_INTERNAL_H
#define LITETERM_PYTHON_INTERNAL_H

#include "LiteTermPythonBridge.h"

typedef struct {
    LTOutputCallback callback;
    void *context;
    size_t line_limit;
    size_t byte_limit;
    size_t line_count;
    size_t byte_count;
    bool truncated;
} LTBoundedPythonOutput;

void LTInitializeBoundedPythonOutput(
    LTBoundedPythonOutput *state,
    LTOutputCallback callback,
    void *context,
    size_t line_limit,
    size_t byte_limit
);
bool LTAppendBoundedPythonOutput(
    LTBoundedPythonOutput *state,
    bool is_standard_error,
    const uint8_t *bytes,
    size_t byte_count
);

#endif
