#include "NVMeSMART.h"

#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static void SetError(SysBarNVMeSMARTResult *result, const char *message) {
    if (!result || !message) return;
    snprintf(result->error, sizeof(result->error), "%s", message);
}

static void CopyDictionaryString(CFDictionaryRef dictionary, CFStringRef key, char *buffer, size_t capacity) {
    if (!dictionary || !buffer || capacity == 0) return;
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    CFStringGetCString((CFStringRef)value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
}

static void ReadServiceAttributes(io_service_t service, SysBarNVMeSMARTResult *result) {
    CFTypeRef characteristics = IORegistryEntryCreateCFProperty(
        service, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
    if (characteristics && CFGetTypeID(characteristics) == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)characteristics;
        CopyDictionaryString(dictionary, CFSTR("Product Name"), result->model, sizeof(result->model));
        CopyDictionaryString(dictionary, CFSTR("Serial Number"), result->serial, sizeof(result->serial));
    }
    if (characteristics) CFRelease(characteristics);

    CFTypeRef protocols = IORegistryEntryCreateCFProperty(
        service, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
    if (protocols && CFGetTypeID(protocols) == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)protocols;
        CopyDictionaryString(dictionary, CFSTR("Physical Interconnect Location"),
                             result->location, sizeof(result->location));
        CopyDictionaryString(dictionary, CFSTR("Physical Interconnect"),
                             result->interconnect, sizeof(result->interconnect));
    }
    if (protocols) CFRelease(protocols);
}

int SysBarReadNVMeSMART(const char *bsdName, SysBarNVMeSMARTResult *result) {
    if (!result) return -1;
    memset(result, 0, sizeof(*result));
    if (!bsdName || bsdName[0] == '\0') {
        SetError(result, "未获取到系统盘设备");
        return 1;
    }

    CFMutableDictionaryRef matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (!matching) {
        SetError(result, "无法匹配系统盘设备");
        return 2;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        SetError(result, "未找到系统盘设备");
        return 3;
    }

    io_service_t smartService = 0;
    for (int depth = 0; depth < 20 && service; depth++) {
        ReadServiceAttributes(service, result);
        CFTypeRef capable = IORegistryEntryCreateCFProperty(
            service, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        if (capable) {
            CFRelease(capable);
            smartService = service;
            break;
        }
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(service);
            service = 0;
            break;
        }
        IOObjectRelease(service);
        service = parent;
    }

    if (!smartService) {
        SetError(result, "系统盘未提供 NVMe SMART 接口");
        return 4;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t pluginResult = IOCreatePlugInInterfaceForService(
        smartService, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (pluginResult != KERN_SUCCESS || !plugin) {
        result->status = pluginResult;
        SetError(result, "无法打开 NVMe SMART 接口");
        IOObjectRelease(smartService);
        return 5;
    }

    IONVMeSMARTInterface **smart = NULL;
    HRESULT queryResult = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (queryResult != S_OK || !smart) {
        result->status = (int32_t)queryResult;
        SetError(result, "无法获取 NVMe SMART 数据接口");
        if (smart) (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(smartService);
        return 6;
    }

    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn readResult = (*smart)->SMARTReadData(smart, &data);
    result->status = readResult;

    if (readResult == kIOReturnSuccess) {
        double celsius = (double)data.TEMPERATURE - 273.15;
        if (data.TEMPERATURE >= 200 && data.TEMPERATURE <= 450 && celsius >= -20 && celsius <= 150) {
            result->available = 1;
            result->temperatureCelsius = celsius;
            result->percentageUsed = data.PERCENTAGE_USED;
            result->criticalWarning = data.CRITICAL_WARNING;
        } else {
            SetError(result, "NVMe SMART 返回了无效温度");
        }
    } else {
        char message[96];
        snprintf(message, sizeof(message), "NVMe SMART 读取失败（0x%x）", (unsigned int)readResult);
        SetError(result, message);
    }

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    IOObjectRelease(smartService);
    return result->available ? 0 : 7;
}
