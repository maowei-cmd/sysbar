#ifndef SYSBAR_NVME_SMART_H
#define SYSBAR_NVME_SMART_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SysBarNVMeSMARTResult {
    int32_t available;
    int32_t status;
    double temperatureCelsius;
    uint32_t percentageUsed;
    uint32_t criticalWarning;
    char model[64];
    char serial[40];
    char location[32];
    char interconnect[32];
    char error[192];
} SysBarNVMeSMARTResult;

int SysBarReadNVMeSMART(const char *bsdName, SysBarNVMeSMARTResult *result);

#ifdef __cplusplus
}
#endif

#endif
