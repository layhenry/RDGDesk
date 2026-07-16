#ifndef RDC_FREERDP_BRIDGE_H
#define RDC_FREERDP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDCFreeRDPClient RDCFreeRDPClient;
typedef void (*RDCFrameCallback)(void *context, const uint8_t *bgra, uint32_t width,
                                 uint32_t height, uint32_t stride);
typedef void (*RDCStateCallback)(void *context, int32_t state, int32_t error_code,
                                 const char *message);
typedef void (*RDCClipboardTextCallback)(void *context, const uint8_t *utf8,
                                         size_t utf8_length);

typedef enum {
    RDCCertificateDecisionReject = 0,
    RDCCertificateDecisionTrustAlways = 1,
    RDCCertificateDecisionTrustOnce = 2,
} RDCCertificateDecision;

typedef struct {
    uint64_t challenge_id;
    const uint8_t *pem;
    size_t pem_length;
    const char *host;
    uint16_t port;
    uint32_t flags;
} RDCCertificateChallenge;

typedef void (*RDCCertificateCallback)(void *context,
                                       const RDCCertificateChallenge *challenge);

typedef enum {
    RDCFreeRDPStateConnecting = 0,
    RDCFreeRDPStateConnected = 1,
    RDCFreeRDPStateDisconnected = 2,
    RDCFreeRDPStateFailed = 3,
} RDCFreeRDPState;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *domain;
    const char *password;
    uint32_t desktop_width;
    uint32_t desktop_height;
} RDCConnectionConfiguration;

uint32_t rdc_freerdp_bridge_version(void);
RDCFreeRDPClient *rdc_client_create(void *context, RDCFrameCallback frame,
                                    RDCStateCallback state,
                                    RDCCertificateCallback certificate);
int32_t rdc_client_connect(RDCFreeRDPClient *client,
                           const RDCConnectionConfiguration *configuration);
void rdc_client_disconnect(RDCFreeRDPClient *client);
void rdc_client_destroy(RDCFreeRDPClient *client);
int32_t rdc_client_resolve_certificate(RDCFreeRDPClient *client,
                                       uint64_t challenge_id,
                                       RDCCertificateDecision decision);
int32_t rdc_client_resize(RDCFreeRDPClient *client, uint32_t width, uint32_t height);
int32_t rdc_client_send_pointer(RDCFreeRDPClient *client, uint16_t flags, uint16_t x,
                                uint16_t y);
int32_t rdc_client_send_key(RDCFreeRDPClient *client, uint16_t flags, uint16_t code);
int32_t rdc_client_send_unicode(RDCFreeRDPClient *client, uint16_t flags,
                                uint16_t code_unit);
int32_t rdc_client_send_secure_attention(RDCFreeRDPClient *client);
int32_t rdc_client_set_clipboard_text(RDCFreeRDPClient *client,
                                      const uint8_t *utf8, size_t utf8_length);
int32_t rdc_client_set_clipboard_callback(RDCFreeRDPClient *client,
                                          RDCClipboardTextCallback callback);

/* Deterministic native seams used to verify the blocking callback contract. */
int32_t rdc_client_test_invoke_certificate(RDCFreeRDPClient *client,
                                           const uint8_t *pem, size_t pem_length,
                                           const char *host, uint16_t port,
                                           uint32_t flags);
int32_t rdc_client_test_external_certificate_management_enabled(
    RDCFreeRDPClient *client);
int32_t rdc_client_test_set_config_path(RDCFreeRDPClient *client,
                                        const char *config_path);
int32_t rdc_client_test_prepare_display_control(RDCFreeRDPClient *client);
int32_t rdc_client_test_display_control_supported(RDCFreeRDPClient *client);
int32_t rdc_client_test_dynamic_resolution_enabled(RDCFreeRDPClient *client);
int32_t rdc_client_test_attach_display_control(RDCFreeRDPClient *client);
int32_t rdc_client_test_receive_display_control_caps(
    RDCFreeRDPClient *client, uint32_t max_monitors,
    uint32_t max_area_factor_a, uint32_t max_area_factor_b);
int32_t rdc_client_test_detach_display_control(RDCFreeRDPClient *client);
int32_t rdc_client_test_dispatch_resize(RDCFreeRDPClient *client,
                                        uint32_t width, uint32_t height);
uint32_t rdc_client_test_sent_display_layout_count(RDCFreeRDPClient *client);
uint32_t rdc_client_test_sent_display_layout_width(RDCFreeRDPClient *client);
uint32_t rdc_client_test_sent_display_layout_height(RDCFreeRDPClient *client);

#ifdef __cplusplus
}
#endif

#endif
