#pragma once

// moonlight-common-c's public API, from the pinned submodule.
#include "../../../moonlight-common-c/src/Limelight.h"

/// The library logs through a printf-style variadic callback, which Swift can't implement. This points
/// `callbacks->logMessage` at a C function that formats each message and passes the finished string to `sink`.
void MCInstallLogSink(PCONNECTION_LISTENER_CALLBACKS callbacks, void (*sink)(const char *message));
