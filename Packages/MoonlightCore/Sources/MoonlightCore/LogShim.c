#include <stdarg.h>
#include <stdio.h>

#include "MoonlightCore.h"

// Set once before LiStartConnection, read from the library's threads afterwards.
static void (*logSink)(const char *message);

static void formatAndForward(const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args); // truncates long lines rather than overflowing
    va_end(args);
    if (logSink != NULL) {
        logSink(message);
    }
}

void MCInstallLogSink(PCONNECTION_LISTENER_CALLBACKS callbacks, void (*sink)(const char *message)) {
    logSink = sink;
    callbacks->logMessage = formatAndForward;
}
