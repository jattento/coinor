#include "CoinorHookRelayPOSIX.h"

#include <unistd.h>

pid_t coinor_fork(void) {
    return fork();
}
