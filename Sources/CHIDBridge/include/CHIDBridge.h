#ifndef C_HID_BRIDGE_H
#define C_HID_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint32_t usage_page;
    uint32_t usage;
    char product[128];
    char manufacturer[128];
    char serial_number[128];
} sayo_hid_device_info;

// Mirrors IOHIDAccessType: 0 granted, 1 denied, 2 unknown.
int sayo_hid_access_status(void);
int sayo_hid_request_access(void);

int sayo_hid_find(
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t usage_page,
    uint32_t usage,
    sayo_hid_device_info *device_info,
    char *error_buffer,
    size_t error_buffer_size
);

// Transactions require the nonempty serial number and location returned by
// sayo_hid_find. Reports are bounded to 64 bytes; oversized responses fail.
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
);

#ifdef __cplusplus
}
#endif

#endif
