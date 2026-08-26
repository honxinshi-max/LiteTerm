#include "LiteTermPythonInternal.h"

#include <string.h>

void LTInitializeBoundedPythonOutput(
    LTBoundedPythonOutput *state,
    LTOutputCallback callback,
    void *context,
    size_t line_limit,
    size_t byte_limit
) {
    if (state == NULL) {
        return;
    }
    memset(state, 0, sizeof(*state));
    state->callback = callback;
    state->context = context;
    state->line_limit = line_limit;
    state->byte_limit = byte_limit;
}

bool LTAppendBoundedPythonOutput(
    LTBoundedPythonOutput *state,
    bool is_standard_error,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (state == NULL || bytes == NULL || byte_count == 0 || state->truncated) {
        return false;
    }
    if (state->line_count >= state->line_limit
        || byte_count > state->byte_limit - state->byte_count) {
        state->truncated = true;
        return false;
    }
    size_t newlines = 0;
    for (size_t index = 0; index < byte_count; index += 1) {
        if (bytes[index] == '\n') {
            newlines += 1;
        }
    }
    if (newlines > state->line_limit - state->line_count) {
        state->truncated = true;
        return false;
    }
    state->line_count += newlines;
    state->byte_count += byte_count;
    if (state->callback != NULL) {
        state->callback(state->context, is_standard_error, bytes, byte_count);
    }
    return true;
}
