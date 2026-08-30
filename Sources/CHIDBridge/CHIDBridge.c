#include "CHIDBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDeviceKeys.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *destination;
    size_t capacity;
    size_t length;
    uint32_t expected_report_id;
    int completed;
    IOReturn result;
} report_state;

static void set_error(char *buffer, size_t buffer_size, const char *message) {
    if (buffer == NULL || buffer_size == 0) {
        return;
    }
    snprintf(buffer, buffer_size, "%s", message == NULL ? "Unknown HID error" : message);
}

static CFNumberRef make_number(int32_t value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
}

static int32_t number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    if (property == NULL || CFGetTypeID(property) != CFNumberGetTypeID()) {
        return 0;
    }

    int32_t value = 0;
    CFNumberGetValue((CFNumberRef)property, kCFNumberSInt32Type, &value);
    return value;
}

static void string_property(IOHIDDeviceRef device, CFStringRef key, char *destination, size_t capacity) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    destination[0] = '\0';

    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    if (property == NULL || CFGetTypeID(property) != CFStringGetTypeID()) {
        return;
    }
    CFStringGetCString((CFStringRef)property, destination, (CFIndex)capacity, kCFStringEncodingUTF8);
}

static IOHIDDeviceRef copy_matching_device(
    IOHIDManagerRef *manager_out,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t usage_page,
    uint32_t usage,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (manager_out == NULL) {
        set_error(error_buffer, error_buffer_size, "Missing HID manager output pointer");
        return NULL;
    }

    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (manager == NULL) {
        set_error(error_buffer, error_buffer_size, "Could not create IOHIDManager");
        return NULL;
    }

    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFNumberRef vendor = make_number(vendor_id);
    CFNumberRef product = make_number(product_id);
    CFNumberRef matched_usage_page = make_number((int32_t)usage_page);
    CFNumberRef matched_usage = make_number((int32_t)usage);
    if (matching == NULL || vendor == NULL || product == NULL || matched_usage_page == NULL || matched_usage == NULL) {
        if (vendor != NULL) {
            CFRelease(vendor);
        }
        if (product != NULL) {
            CFRelease(product);
        }
        if (matched_usage_page != NULL) {
            CFRelease(matched_usage_page);
        }
        if (matched_usage != NULL) {
            CFRelease(matched_usage);
        }
        if (matching != NULL) {
            CFRelease(matching);
        }
        set_error(error_buffer, error_buffer_size, "Could not allocate HID matching criteria");
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }
    CFDictionarySetValue(matching, CFSTR(kIOHIDVendorIDKey), vendor);
    CFDictionarySetValue(matching, CFSTR(kIOHIDProductIDKey), product);
    CFDictionarySetValue(matching, CFSTR(kIOHIDDeviceUsagePageKey), matched_usage_page);
    CFDictionarySetValue(matching, CFSTR(kIOHIDDeviceUsageKey), matched_usage);
    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(vendor);
    CFRelease(product);
    CFRelease(matched_usage_page);
    CFRelease(matched_usage);
    CFRelease(matching);

    IOReturn open_result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        char message[128];
        snprintf(message, sizeof(message), "Could not open IOHIDManager (0x%08x)", (unsigned int)open_result);
        set_error(error_buffer, error_buffer_size, message);
        CFRelease(manager);
        return NULL;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices == NULL || CFSetGetCount(devices) == 0) {
        set_error(error_buffer, error_buffer_size, "SayoDevice O2L V2 was not found");
        if (devices != NULL) {
            CFRelease(devices);
        }
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }

    CFIndex count = CFSetGetCount(devices);
    if (count <= 0 || (size_t)count > SIZE_MAX / sizeof(void *)) {
        set_error(error_buffer, error_buffer_size, "The HID device set is too large");
        CFRelease(devices);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }
    const void **values = calloc((size_t)count, sizeof(void *));
    if (values == NULL) {
        set_error(error_buffer, error_buffer_size, "Could not allocate HID device list");
        CFRelease(devices);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }
    CFSetGetValues(devices, values);

    IOHIDDeviceRef selected = NULL;
    for (CFIndex index = 0; index < count; index++) {
        IOHIDDeviceRef device = (IOHIDDeviceRef)values[index];
        int32_t candidate_usage_page = number_property(device, CFSTR(kIOHIDPrimaryUsagePageKey));
        int32_t candidate_usage = number_property(device, CFSTR(kIOHIDPrimaryUsageKey));
        if ((uint32_t)candidate_usage_page == usage_page && (uint32_t)candidate_usage == usage) {
            selected = device;
            CFRetain(selected);
            break;
        }
    }

    free(values);
    CFRelease(devices);

    if (selected == NULL) {
        set_error(error_buffer, error_buffer_size, "The SayoDevice vendor HID interface (0xFF00:0x01) was not found");
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }

    *manager_out = manager;
    return selected;
}

static void close_device(IOHIDManagerRef manager, IOHIDDeviceRef device) {
    if (device != NULL) {
        CFRelease(device);
    }
    if (manager != NULL) {
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
    }
}

static void input_report_callback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t report_id,
    uint8_t *report,
    CFIndex report_length
) {
    (void)sender;
    (void)type;

    report_state *state = (report_state *)context;
    if (state == NULL || report_id != state->expected_report_id) {
        return;
    }

    size_t length = report_length < 0 ? 0 : (size_t)report_length;
    if (length > state->capacity) {
        length = state->capacity;
    }
    state->result = result;
    if (result != kIOReturnSuccess || report == NULL || state->destination == NULL) {
        state->length = 0;
        state->completed = 1;
        return;
    }
    if (length > 0) {
        memcpy(state->destination, report, length);
    }
    state->length = length;
    state->completed = 1;
}

int sayo_hid_access_status(void) {
    return (int)IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
}

int sayo_hid_request_access(void) {
    return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? 1 : 0;
}

int sayo_hid_find(
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t usage_page,
    uint32_t usage,
    sayo_hid_device_info *device_info,
    char *error_buffer,
    size_t error_buffer_size
) {
    IOHIDManagerRef manager = NULL;
    IOHIDDeviceRef device = copy_matching_device(
        &manager,
        vendor_id,
        product_id,
        usage_page,
        usage,
        error_buffer,
        error_buffer_size
    );
    if (device == NULL) {
        return 0;
    }

    if (device_info != NULL) {
        memset(device_info, 0, sizeof(*device_info));
        device_info->vendor_id = (uint16_t)number_property(device, CFSTR(kIOHIDVendorIDKey));
        device_info->product_id = (uint16_t)number_property(device, CFSTR(kIOHIDProductIDKey));
        device_info->location_id = (uint32_t)number_property(device, CFSTR(kIOHIDLocationIDKey));
        device_info->usage_page = (uint32_t)number_property(device, CFSTR(kIOHIDPrimaryUsagePageKey));
        device_info->usage = (uint32_t)number_property(device, CFSTR(kIOHIDPrimaryUsageKey));
        string_property(device, CFSTR(kIOHIDProductKey), device_info->product, sizeof(device_info->product));
        string_property(device, CFSTR(kIOHIDManufacturerKey), device_info->manufacturer, sizeof(device_info->manufacturer));
        string_property(device, CFSTR(kIOHIDSerialNumberKey), device_info->serial_number, sizeof(device_info->serial_number));
    }

    close_device(manager, device);
    return 1;
}

int sayo_hid_transact(
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t usage_page,
    uint32_t usage,
    const uint8_t *output_report,
    size_t output_report_length,
    uint8_t *input_report,
    size_t input_report_capacity,
    int timeout_milliseconds,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (output_report == NULL || output_report_length == 0 || input_report == NULL || input_report_capacity == 0) {
        set_error(error_buffer, error_buffer_size, "Invalid HID transaction buffers");
        return -1;
    }

    IOHIDManagerRef manager = NULL;
    IOHIDDeviceRef device = copy_matching_device(
        &manager,
        vendor_id,
        product_id,
        usage_page,
        usage,
        error_buffer,
        error_buffer_size
    );
    if (device == NULL) {
        return -1;
    }

    IOReturn open_result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        char message[128];
        snprintf(message, sizeof(message), "Could not open the SayoDevice interface (0x%08x)", (unsigned int)open_result);
        set_error(error_buffer, error_buffer_size, message);
        close_device(manager, device);
        return -1;
    }

    uint8_t callback_buffer[64] = {0};
    report_state state = {
        .destination = input_report,
        .capacity = input_report_capacity,
        .length = 0,
        .expected_report_id = output_report[0],
        .completed = 0,
        .result = kIOReturnSuccess,
    };

    IOHIDDeviceRegisterInputReportCallback(
        device,
        callback_buffer,
        sizeof(callback_buffer),
        input_report_callback,
        &state
    );
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn write_result = IOHIDDeviceSetReport(
        device,
        kIOHIDReportTypeOutput,
        output_report[0],
        output_report,
        (CFIndex)output_report_length
    );
    if (write_result != kIOReturnSuccess) {
        char message[128];
        snprintf(message, sizeof(message), "Could not send HID report (0x%08x)", (unsigned int)write_result);
        set_error(error_buffer, error_buffer_size, message);
    } else {
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + ((double)timeout_milliseconds / 1000.0);
        while (!state.completed && CFAbsoluteTimeGetCurrent() < deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
        }
        if (!state.completed) {
            set_error(error_buffer, error_buffer_size, "The keyboard did not answer before the timeout");
        } else if (state.result != kIOReturnSuccess) {
            char message[128];
            snprintf(message, sizeof(message), "HID response failed (0x%08x)", (unsigned int)state.result);
            set_error(error_buffer, error_buffer_size, message);
        }
    }

    IOHIDDeviceRegisterInputReportCallback(device, callback_buffer, sizeof(callback_buffer), NULL, NULL);
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
    close_device(manager, device);

    if (write_result != kIOReturnSuccess || !state.completed || state.result != kIOReturnSuccess) {
        return -1;
    }
    return (int)state.length;
}
