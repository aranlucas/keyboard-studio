#include "CHIDBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDeviceKeys.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SAYO_HID_REPORT_LENGTH = 64 };
enum { SAYO_HID_TEXT_LENGTH = 128 };

typedef struct {
    uint8_t *destination;
    size_t capacity;
    size_t length;
    uint32_t expected_report_id;
    int completed;
    int truncated;
    int invalid;
    IOReturn result;
} report_state;

static void set_error(char *buffer, size_t buffer_size, const char *message) {
    if (buffer == NULL || buffer_size == 0) {
        return;
    }
    snprintf(buffer, buffer_size, "%s", message == NULL ? "Unknown HID error" : message);
}

static int valid_serial_selection(const char *serial_number) {
    return serial_number != NULL
        && serial_number[0] != '\0'
        && strnlen(serial_number, SAYO_HID_TEXT_LENGTH) < SAYO_HID_TEXT_LENGTH;
}

static int size_fits_cf_index(size_t value) {
    return value <= (size_t)INTPTR_MAX;
}

static CFNumberRef make_number(uint32_t value) {
    const int64_t signed_value = (int64_t)value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &signed_value);
}

static int uint32_property(IOHIDDeviceRef device, CFStringRef key, uint32_t *value_out) {
    if (value_out == NULL) {
        return 0;
    }

    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    if (property == NULL || CFGetTypeID(property) != CFNumberGetTypeID()) {
        return 0;
    }

    int64_t value = 0;
    if (!CFNumberGetValue((CFNumberRef)property, kCFNumberSInt64Type, &value)
        || value < 0
        || (uint64_t)value > UINT32_MAX) {
        return 0;
    }
    *value_out = (uint32_t)value;
    return 1;
}

static void string_property(IOHIDDeviceRef device, CFStringRef key, char *destination, size_t capacity) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    if (!size_fits_cf_index(capacity)) {
        return;
    }
    destination[0] = '\0';

    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    if (property == NULL || CFGetTypeID(property) != CFStringGetTypeID()) {
        return;
    }
    if (!CFStringGetCString((CFStringRef)property, destination, (CFIndex)capacity, kCFStringEncodingUTF8)) {
        destination[0] = '\0';
    }
}

static int string_property_equals(IOHIDDeviceRef device, CFStringRef key, const char *expected) {
    if (!valid_serial_selection(expected)) {
        return 0;
    }

    char actual[SAYO_HID_TEXT_LENGTH];
    string_property(device, key, actual, sizeof(actual));
    return actual[0] != '\0' && strcmp(actual, expected) == 0;
}

static IOHIDDeviceRef copy_matching_device(
    IOHIDManagerRef *manager_out,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t usage_page,
    uint32_t usage,
    const char *serial_number,
    uint32_t location_id,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (manager_out == NULL) {
        set_error(error_buffer, error_buffer_size, "Missing HID manager output pointer");
        return NULL;
    }
    *manager_out = NULL;
    if (serial_number != NULL && !valid_serial_selection(serial_number)) {
        set_error(error_buffer, error_buffer_size, "A nonempty HID serial selection is required");
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
    CFNumberRef matched_usage_page = make_number(usage_page);
    CFNumberRef matched_usage = make_number(usage);
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
    if (count <= 0 || (uintmax_t)count > SIZE_MAX / sizeof(void *)) {
        set_error(error_buffer, error_buffer_size, "The HID device set is too large");
        CFRelease(devices);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return NULL;
    }
    const size_t device_count = (size_t)count;
    const void **values = calloc(device_count, sizeof(*values));
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
        uint32_t candidate_usage_page = 0;
        uint32_t candidate_usage = 0;
        int matches = uint32_property(device, CFSTR(kIOHIDPrimaryUsagePageKey), &candidate_usage_page)
            && uint32_property(device, CFSTR(kIOHIDPrimaryUsageKey), &candidate_usage)
            && candidate_usage_page == usage_page
            && candidate_usage == usage;
        if (matches && serial_number != NULL) {
            uint32_t candidate_location = 0;
            matches = string_property_equals(device, CFSTR(kIOHIDSerialNumberKey), serial_number)
                && uint32_property(device, CFSTR(kIOHIDLocationIDKey), &candidate_location)
                && candidate_location == location_id;
        }
        if (matches) {
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

    state->result = result;
    if (report_length < 0
        || (uintmax_t)report_length > state->capacity
        || result != kIOReturnSuccess
        || report == NULL
        || state->destination == NULL) {
        if (report_length < 0 || (uintmax_t)report_length > state->capacity) {
            state->truncated = 1;
        }
        if (result != kIOReturnSuccess || report == NULL || state->destination == NULL) {
            state->invalid = 1;
        }
        state->length = 0;
        state->completed = 1;
        return;
    }
    const size_t length = (size_t)report_length;
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
        NULL,
        0,
        error_buffer,
        error_buffer_size
    );
    if (device == NULL) {
        return 0;
    }

    if (device_info != NULL) {
        memset(device_info, 0, sizeof(*device_info));
        uint32_t value = 0;
        if (uint32_property(device, CFSTR(kIOHIDVendorIDKey), &value) && value <= UINT16_MAX) {
            device_info->vendor_id = (uint16_t)value;
        }
        if (uint32_property(device, CFSTR(kIOHIDProductIDKey), &value) && value <= UINT16_MAX) {
            device_info->product_id = (uint16_t)value;
        }
        if (uint32_property(device, CFSTR(kIOHIDLocationIDKey), &value)) {
            device_info->location_id = value;
        }
        if (uint32_property(device, CFSTR(kIOHIDPrimaryUsagePageKey), &value)) {
            device_info->usage_page = value;
        }
        if (uint32_property(device, CFSTR(kIOHIDPrimaryUsageKey), &value)) {
            device_info->usage = value;
        }
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
    const char *serial_number,
    uint32_t location_id,
    const uint8_t *output_report,
    size_t output_report_length,
    uint8_t *input_report,
    size_t input_report_capacity,
    int timeout_milliseconds,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (!valid_serial_selection(serial_number)) {
        set_error(error_buffer, error_buffer_size, "A nonempty HID serial selection is required");
        return -1;
    }
    if (output_report == NULL || output_report_length == 0
        || output_report_length > SAYO_HID_REPORT_LENGTH
        || !size_fits_cf_index(output_report_length)
        || input_report == NULL || input_report_capacity == 0
        || input_report_capacity > SAYO_HID_REPORT_LENGTH
        || timeout_milliseconds < 0) {
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
        serial_number,
        location_id,
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

    uint8_t callback_buffer[SAYO_HID_REPORT_LENGTH] = {0};
    const CFIndex callback_buffer_length = (CFIndex)sizeof(callback_buffer);
    report_state state = {
        .destination = input_report,
        .capacity = input_report_capacity,
        .length = 0,
        .expected_report_id = output_report[0],
        .completed = 0,
        .truncated = 0,
        .invalid = 0,
        .result = kIOReturnSuccess,
    };

    IOHIDDeviceRegisterInputReportCallback(
        device,
        callback_buffer,
        callback_buffer_length,
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
        } else if (state.truncated) {
            set_error(error_buffer, error_buffer_size, "The HID response exceeded the fixed 64-byte report buffer");
        } else if (state.invalid) {
            set_error(error_buffer, error_buffer_size, "The HID response callback returned invalid data");
        } else if (state.result != kIOReturnSuccess) {
            char message[128];
            snprintf(message, sizeof(message), "HID response failed (0x%08x)", (unsigned int)state.result);
            set_error(error_buffer, error_buffer_size, message);
        }
    }

    IOHIDDeviceRegisterInputReportCallback(device, callback_buffer, callback_buffer_length, NULL, NULL);
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
    close_device(manager, device);

    if (write_result != kIOReturnSuccess || !state.completed || state.truncated || state.invalid || state.result != kIOReturnSuccess) {
        return -1;
    }
    if (state.length > INT_MAX) {
        set_error(error_buffer, error_buffer_size, "The HID response length is outside the supported range");
        return -1;
    }
    return (int)state.length;
}
