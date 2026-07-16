#include "RdcFreeRDPBridge.h"

#define WITHOUT_FREERDP_3x_DEPRECATED
#include <freerdp/addin.h>
#include <freerdp/codec/color.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/version.h>
#include <winpr/crt.h>
#include <winpr/synch.h>
#include <winpr/string.h>
#include <winpr/thread.h>
#include <winpr/user.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    RDC_COMMAND_NONE = 0,
    RDC_COMMAND_RESIZE,
    RDC_COMMAND_POINTER,
    RDC_COMMAND_KEY,
    RDC_COMMAND_UNICODE,
    RDC_COMMAND_SECURE_ATTENTION,
    RDC_COMMAND_CLIPBOARD_TEXT,
} RDCClientCommand;

typedef struct {
    rdpContext context;
    struct RDCFreeRDPClient *client;
} RDCFreeRDPContext;

struct RDCFreeRDPClient {
    freerdp *instance;
    void *callback_context;
    RDCFrameCallback frame_callback;
    RDCStateCallback state_callback;
    RDCCertificateCallback certificate_callback;
    RDCClipboardTextCallback clipboard_callback;
    CliprdrClientContext *cliprdr;
    DispClientContext *disp;
    BOOL display_control_ready;
    UINT32 display_control_max_monitors;
    UINT32 display_control_max_area_factor_a;
    UINT32 display_control_max_area_factor_b;
    BOOL pending_display_resize;
    uint32_t pending_display_width;
    uint32_t pending_display_height;
    HANDLE stop_event;
    HANDLE worker_finished_event;
    HANDLE polling_thread;
    DWORD polling_thread_id;
    HANDLE command_event;
    HANDLE command_complete_event;
    HANDLE certificate_decision_event;
    HANDLE certificate_callback_finished_event;
    CRITICAL_SECTION lifecycle_lock;
    BOOL lifecycle_lock_initialized;
    CRITICAL_SECTION command_lock;
    BOOL command_lock_initialized;
    BOOL connected;
    BOOL accepting_commands;
    BOOL clipboard_connected_subscription;
    BOOL clipboard_disconnected_subscription;
    RDCClientCommand command;
    int32_t command_result;
    uint32_t command_width;
    uint32_t command_height;
    uint16_t command_flags;
    uint16_t command_x;
    uint16_t command_y;
    uint16_t command_code;
    char *clipboard_text;
    char *command_clipboard_text;
    uint32_t requested_clipboard_format;
    uint64_t next_certificate_id;
    uint64_t pending_certificate_id;
    RDCCertificateDecision certificate_decision;
    BOOL certificate_pending;
    BOOL certificate_resolved;
    char *password_copy;
    uint8_t *frame_buffer;
    size_t frame_buffer_size;
    uint32_t frame_width;
    uint32_t frame_height;
    uint32_t frame_stride;
    DispClientContext test_disp;
    uint32_t test_sent_display_layout_count;
    DISPLAY_CONTROL_MONITOR_LAYOUT test_sent_display_layout;
};

static int32_t rdc_dispatch_display_control_resize(RDCFreeRDPClient *client,
                                                   uint32_t width,
                                                   uint32_t height);

static RDCFreeRDPClient *rdc_client_from_context(rdpContext *context) {
    if (!context)
        return NULL;
    return ((RDCFreeRDPContext *)context)->client;
}

static BOOL rdc_load_static_channel(rdpChannels *channels, rdpSettings *settings,
                                    const char *name, void *data) {
    PVIRTUALCHANNELENTRY raw = freerdp_load_channel_addin_entry(
        name, NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    PVIRTUALCHANNELENTRYEX entry_ex =
        WINPR_FUNC_PTR_CAST(raw, PVIRTUALCHANNELENTRYEX);
    if (entry_ex)
        return freerdp_channels_client_load_ex(channels, settings, entry_ex, data) == 0;

    PVIRTUALCHANNELENTRY entry = freerdp_load_channel_addin_entry(
        name, NULL, NULL, FREERDP_ADDIN_CHANNEL_STATIC);
    return entry && freerdp_channels_client_load(channels, settings, entry, data) == 0;
}

static BOOL rdc_load_channels(freerdp *instance) {
    if (!instance || !instance->context || !instance->context->channels ||
        !instance->context->settings)
        return FALSE;
    RDCFreeRDPClient *client = rdc_client_from_context(instance->context);
    if (!client)
        return FALSE;
    rdpSettings *settings = instance->context->settings;
    rdpChannels *channels = instance->context->channels;
    if (freerdp_settings_get_bool(settings, FreeRDP_RedirectClipboard)) {
        const char *const params[] = {CLIPRDR_SVC_CHANNEL_NAME};
        if (!freerdp_client_add_static_channel(settings, 1, params))
            return FALSE;
        ADDIN_ARGV *args = freerdp_static_channel_collection_find(
            settings, CLIPRDR_SVC_CHANNEL_NAME);
        if (!args || !rdc_load_static_channel(
                         channels, settings, CLIPRDR_SVC_CHANNEL_NAME, args))
            return FALSE;
    }

    if (freerdp_settings_get_bool(settings, FreeRDP_SupportDisplayControl)) {
        const char *const params[] = {DISP_CHANNEL_NAME};
        if (!freerdp_client_add_dynamic_channel(settings, 1, params) ||
            !freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE) ||
            !rdc_load_static_channel(channels, settings,
                                     DRDYNVC_SVC_CHANNEL_NAME, settings))
            return FALSE;
    }

    return TRUE;
}

static void rdc_emit_state(RDCFreeRDPClient *client, int32_t state, int32_t error_code,
                           const char *message) {
    if (client && client->state_callback)
        client->state_callback(client->callback_context, state, error_code, message);
}

static int rdc_verify_x509_certificate(freerdp *instance, const BYTE *data,
                                       size_t length, const char *hostname,
                                       UINT16 port, DWORD flags) {
    if (!instance || !instance->context || !data || length == 0 || !hostname)
        return RDCCertificateDecisionReject;

    RDCFreeRDPClient *client = rdc_client_from_context(instance->context);
    if (!client || !client->certificate_callback || !client->certificate_decision_event ||
        !client->certificate_callback_finished_event)
        return RDCCertificateDecisionReject;

    EnterCriticalSection(&client->lifecycle_lock);
    if (client->certificate_pending || client->next_certificate_id == UINT64_MAX) {
        LeaveCriticalSection(&client->lifecycle_lock);
        return RDCCertificateDecisionReject;
    }

    client->next_certificate_id += 1;
    client->pending_certificate_id = client->next_certificate_id;
    client->certificate_decision = RDCCertificateDecisionReject;
    client->certificate_pending = TRUE;
    client->certificate_resolved = FALSE;
    if (!ResetEvent(client->certificate_decision_event) ||
        !ResetEvent(client->certificate_callback_finished_event)) {
        client->pending_certificate_id = 0;
        client->certificate_pending = FALSE;
        LeaveCriticalSection(&client->lifecycle_lock);
        return RDCCertificateDecisionReject;
    }
    const uint64_t challenge_id = client->pending_certificate_id;
    LeaveCriticalSection(&client->lifecycle_lock);

    const RDCCertificateChallenge challenge = {
        .challenge_id = challenge_id,
        .pem = data,
        .pem_length = length,
        .host = hostname,
        .port = port,
        .flags = flags,
    };
    client->certificate_callback(client->callback_context, &challenge);

    HANDLE events[2] = {client->certificate_decision_event, client->stop_event};
    const DWORD wait = WaitForMultipleObjects(2, events, FALSE, INFINITE);

    EnterCriticalSection(&client->lifecycle_lock);
    RDCCertificateDecision decision = RDCCertificateDecisionReject;
    if (wait == WAIT_OBJECT_0 && client->certificate_resolved &&
        WaitForSingleObject(client->stop_event, 0) != WAIT_OBJECT_0)
        decision = client->certificate_decision;
    client->pending_certificate_id = 0;
    client->certificate_decision = RDCCertificateDecisionReject;
    client->certificate_pending = FALSE;
    client->certificate_resolved = FALSE;
    HANDLE callback_finished_event = client->certificate_callback_finished_event;
    LeaveCriticalSection(&client->lifecycle_lock);
    /* Keep this as the callback's final client-related operation. Destroy waits on it. */
    (void)SetEvent(callback_finished_event);
    return (int)decision;
}

#define RDC_CLIPBOARD_MAX_UTF8_BYTES (1024u * 1024u)

static UINT rdc_clipboard_send_capabilities(CliprdrClientContext *cliprdr) {
    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    CLIPRDR_CAPABILITIES capabilities = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    return cliprdr->ClientCapabilities(cliprdr, &capabilities);
}

static UINT rdc_clipboard_announce_text(CliprdrClientContext *cliprdr) {
    if (!cliprdr || !cliprdr->custom)
        return ERROR_INVALID_STATE;
    RDCFreeRDPClient *client = (RDCFreeRDPClient *)cliprdr->custom;
    CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT, .formatName = NULL };
    CLIPRDR_FORMAT_LIST list = {0};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = client->clipboard_text ? 1u : 0u;
    list.formats = client->clipboard_text ? &format : NULL;
    return cliprdr->ClientFormatList(cliprdr, &list);
}

static UINT rdc_clipboard_monitor_ready(CliprdrClientContext *cliprdr,
                                        const CLIPRDR_MONITOR_READY *ready) {
    WINPR_UNUSED(ready);
    UINT rc = rdc_clipboard_send_capabilities(cliprdr);
    if (rc != CHANNEL_RC_OK)
        return rc;
    return rdc_clipboard_announce_text(cliprdr);
}

static UINT rdc_clipboard_server_capabilities(CliprdrClientContext *cliprdr,
                                               const CLIPRDR_CAPABILITIES *capabilities) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(capabilities);
    return CHANNEL_RC_OK;
}

static UINT rdc_clipboard_server_format_list(CliprdrClientContext *cliprdr,
                                              const CLIPRDR_FORMAT_LIST *list) {
    if (!cliprdr || !cliprdr->custom || !list)
        return ERROR_INVALID_PARAMETER;
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    if (rc != CHANNEL_RC_OK)
        return rc;

    for (UINT32 index = 0; index < list->numFormats; index++) {
        if (list->formats[index].formatId != CF_UNICODETEXT)
            continue;
        RDCFreeRDPClient *client = (RDCFreeRDPClient *)cliprdr->custom;
        client->requested_clipboard_format = CF_UNICODETEXT;
        CLIPRDR_FORMAT_DATA_REQUEST request = {0};
        request.common.msgType = CB_FORMAT_DATA_REQUEST;
        request.requestedFormatId = CF_UNICODETEXT;
        return cliprdr->ClientFormatDataRequest(cliprdr, &request);
    }
    return CHANNEL_RC_OK;
}

static UINT rdc_clipboard_server_format_list_response(
    CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(response);
    return CHANNEL_RC_OK;
}

static UINT rdc_clipboard_server_format_data_request(
    CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    if (!cliprdr || !cliprdr->custom || !request)
        return ERROR_INVALID_PARAMETER;
    RDCFreeRDPClient *client = (RDCFreeRDPClient *)cliprdr->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    if (request->requestedFormatId == CF_UNICODETEXT && client->clipboard_text) {
        size_t characters = 0;
        WCHAR *wide = ConvertUtf8ToWCharAlloc(client->clipboard_text, &characters);
        if (wide && characters <= (UINT32_MAX / sizeof(WCHAR)) - 1u) {
            response.common.msgFlags = CB_RESPONSE_OK;
            response.common.dataLen = (UINT32)((characters + 1u) * sizeof(WCHAR));
            response.requestedFormatData = (const BYTE *)wide;
            UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
            free(wide);
            return rc;
        }
        free(wide);
    }
    return cliprdr->ClientFormatDataResponse(cliprdr, &response);
}

static UINT rdc_clipboard_server_format_data_response(
    CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    if (!cliprdr || !cliprdr->custom || !response)
        return ERROR_INVALID_PARAMETER;
    RDCFreeRDPClient *client = (RDCFreeRDPClient *)cliprdr->custom;
    if (client->requested_clipboard_format != CF_UNICODETEXT)
        return CHANNEL_RC_OK;
    client->requested_clipboard_format = 0;
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) ||
        !response->requestedFormatData || response->common.dataLen < sizeof(WCHAR) ||
        (response->common.dataLen % sizeof(WCHAR)) != 0 ||
        response->common.dataLen > (RDC_CLIPBOARD_MAX_UTF8_BYTES * sizeof(WCHAR)))
        return CHANNEL_RC_OK;

    const size_t units = response->common.dataLen / sizeof(WCHAR);
    WCHAR *copy = calloc(units + 1u, sizeof(WCHAR));
    if (!copy)
        return CHANNEL_RC_NO_MEMORY;
    memcpy(copy, response->requestedFormatData, response->common.dataLen);
    size_t utf8_length = 0;
    char *utf8 = ConvertWCharToUtf8Alloc(copy, &utf8_length);
    free(copy);
    if (!utf8)
        return CHANNEL_RC_OK;
    if (utf8_length <= RDC_CLIPBOARD_MAX_UTF8_BYTES && client->clipboard_callback)
        client->clipboard_callback(client->callback_context, (const uint8_t *)utf8,
                                   utf8_length);
    free(utf8);
    return CHANNEL_RC_OK;
}

static UINT rdc_clipboard_noop_lock(CliprdrClientContext *cliprdr,
                                    const CLIPRDR_LOCK_CLIPBOARD_DATA *data) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(data);
    return CHANNEL_RC_OK;
}

static UINT rdc_clipboard_noop_unlock(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_UNLOCK_CLIPBOARD_DATA *data) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(data);
    return CHANNEL_RC_OK;
}

static UINT rdc_display_control_caps(DispClientContext *disp,
                                     UINT32 max_monitors,
                                     UINT32 max_area_factor_a,
                                     UINT32 max_area_factor_b) {
    if (!disp || !disp->custom)
        return ERROR_INVALID_PARAMETER;
    RDCFreeRDPClient *client = (RDCFreeRDPClient *)disp->custom;
    client->display_control_max_monitors = max_monitors;
    client->display_control_max_area_factor_a = max_area_factor_a;
    client->display_control_max_area_factor_b = max_area_factor_b;
    const uint64_t max_area = (uint64_t)max_area_factor_a * max_area_factor_b;
    client->display_control_ready =
        max_monitors > 0 &&
        max_area >= (uint64_t)DISPLAY_CONTROL_MIN_MONITOR_WIDTH *
                        DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
    if (client->display_control_ready && client->pending_display_resize) {
        (void)rdc_dispatch_display_control_resize(
            client, client->pending_display_width, client->pending_display_height);
    }
    return CHANNEL_RC_OK;
}

static void rdc_attach_display_control(RDCFreeRDPClient *client,
                                       DispClientContext *disp) {
    if (!client || !disp)
        return;
    client->disp = disp;
    client->display_control_ready = FALSE;
    client->display_control_max_monitors = 0;
    client->display_control_max_area_factor_a = 0;
    client->display_control_max_area_factor_b = 0;
    disp->custom = client;
    disp->DisplayControlCaps = rdc_display_control_caps;
}

static void rdc_detach_display_control(RDCFreeRDPClient *client,
                                       DispClientContext *disp) {
    if (disp && disp->custom == client)
        disp->custom = NULL;
    if (!client || (disp && client->disp != disp))
        return;
    client->disp = NULL;
    client->display_control_ready = FALSE;
    client->display_control_max_monitors = 0;
    client->display_control_max_area_factor_a = 0;
    client->display_control_max_area_factor_b = 0;
}

static void rdc_on_channel_connected(void *context, const ChannelConnectedEventArgs *event) {
    if (!context || !event || !event->name)
        return;
    RDCFreeRDPClient *client = rdc_client_from_context((rdpContext *)context);
    if (!client)
        return;
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        rdc_attach_display_control(client, (DispClientContext *)event->pInterface);
        return;
    }
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) != 0)
        return;
    CliprdrClientContext *cliprdr = (CliprdrClientContext *)event->pInterface;
    if (!cliprdr)
        return;
    client->cliprdr = cliprdr;
    cliprdr->custom = client;
    cliprdr->MonitorReady = rdc_clipboard_monitor_ready;
    cliprdr->ServerCapabilities = rdc_clipboard_server_capabilities;
    cliprdr->ServerFormatList = rdc_clipboard_server_format_list;
    cliprdr->ServerFormatListResponse = rdc_clipboard_server_format_list_response;
    cliprdr->ServerLockClipboardData = rdc_clipboard_noop_lock;
    cliprdr->ServerUnlockClipboardData = rdc_clipboard_noop_unlock;
    cliprdr->ServerFormatDataRequest = rdc_clipboard_server_format_data_request;
    cliprdr->ServerFormatDataResponse = rdc_clipboard_server_format_data_response;
}

static void rdc_on_channel_disconnected(void *context,
                                        const ChannelDisconnectedEventArgs *event) {
    if (!context || !event || !event->name)
        return;
    RDCFreeRDPClient *client = rdc_client_from_context((rdpContext *)context);
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        rdc_detach_display_control(client, (DispClientContext *)event->pInterface);
        return;
    }
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) != 0)
        return;
    CliprdrClientContext *cliprdr = (CliprdrClientContext *)event->pInterface;
    if (cliprdr)
        cliprdr->custom = NULL;
    if (client)
        client->cliprdr = NULL;
}

static BOOL rdc_allocate_frame_buffer(RDCFreeRDPClient *client, uint32_t width,
                                      uint32_t height) {
    if (!client || width == 0 || height == 0 || width > UINT32_MAX / 4u)
        return FALSE;

    const uint32_t stride = width * 4u;
    if ((size_t)height > SIZE_MAX / stride)
        return FALSE;

    const size_t size = (size_t)stride * height;
    uint8_t *buffer = calloc(1, size);
    if (!buffer)
        return FALSE;

    free(client->frame_buffer);
    client->frame_buffer = buffer;
    client->frame_buffer_size = size;
    client->frame_width = width;
    client->frame_height = height;
    client->frame_stride = stride;
    return TRUE;
}

static BOOL rdc_begin_paint(rdpContext *context) {
    if (!context || !context->gdi || !context->gdi->primary ||
        !context->gdi->primary->hdc || !context->gdi->primary->hdc->hwnd ||
        !context->gdi->primary->hdc->hwnd->invalid)
        return FALSE;

    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL rdc_end_paint(rdpContext *context) {
    RDCFreeRDPClient *client = rdc_client_from_context(context);
    if (!client || !client->frame_callback || !context->gdi ||
        !context->gdi->primary_buffer || !context->gdi->primary ||
        !context->gdi->primary->hdc || !context->gdi->primary->hdc->hwnd)
        return TRUE;

    HGDI_RGN invalid = context->gdi->primary->hdc->hwnd->invalid;
    if (!invalid || invalid->null)
        return TRUE;

    const uint32_t width = (uint32_t)context->gdi->width;
    const uint32_t height = (uint32_t)context->gdi->height;
    if (client->frame_width != width || client->frame_height != height) {
        if (!rdc_allocate_frame_buffer(client, width, height))
            return FALSE;
    }

    int64_t left = invalid->x;
    int64_t top = invalid->y;
    int64_t right = left + invalid->w;
    int64_t bottom = top + invalid->h;
    if (left < 0)
        left = 0;
    if (top < 0)
        top = 0;
    if (right > width)
        right = width;
    if (bottom > height)
        bottom = height;
    if (right <= left || bottom <= top)
        return TRUE;

    const size_t copy_width = (size_t)(right - left) * 4u;
    for (int64_t y = top; y < bottom; ++y) {
        const size_t source_offset = (size_t)y * context->gdi->stride + (size_t)left * 4u;
        const size_t destination_offset = (size_t)y * client->frame_stride + (size_t)left * 4u;
        memcpy(client->frame_buffer + destination_offset,
               context->gdi->primary_buffer + source_offset, copy_width);
    }

    client->frame_callback(client->callback_context, client->frame_buffer,
                           client->frame_width, client->frame_height,
                           client->frame_stride);
    return TRUE;
}

static BOOL rdc_desktop_resize(rdpContext *context) {
    RDCFreeRDPClient *client = rdc_client_from_context(context);
    if (!client || !context || !context->settings || !context->gdi)
        return FALSE;

    const uint32_t width =
        freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const uint32_t height =
        freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, width, height))
        return FALSE;
    return rdc_allocate_frame_buffer(client, width, height);
}

static BOOL rdc_post_connect(freerdp *instance) {
    if (!instance || !instance->context || !instance->context->update)
        return FALSE;
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    rdpContext *context = instance->context;
    RDCFreeRDPClient *client = rdc_client_from_context(context);
    if (!client || !rdc_allocate_frame_buffer(client, (uint32_t)context->gdi->width,
                                               (uint32_t)context->gdi->height)) {
        gdi_free(instance);
        return FALSE;
    }

    context->update->BeginPaint = rdc_begin_paint;
    context->update->EndPaint = rdc_end_paint;
    context->update->DesktopResize = rdc_desktop_resize;
    return TRUE;
}

static void rdc_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context)
        return;
    RDCFreeRDPClient *client = rdc_client_from_context(instance->context);
    if (client) {
        free(client->clipboard_text);
        client->clipboard_text = NULL;
        client->requested_clipboard_format = 0;
        client->cliprdr = NULL;
        client->pending_display_resize = FALSE;
        client->pending_display_width = 0;
        client->pending_display_height = 0;
        rdc_detach_display_control(client, client->disp);
    }
    if (instance->context->gdi)
        gdi_free(instance);
}

static void rdc_clear_password(RDCFreeRDPClient *client) {
    if (!client)
        return;

    if (client->password_copy) {
        const size_t length = strlen(client->password_copy);
        SecureZeroMemory(client->password_copy, length);
        free(client->password_copy);
        client->password_copy = NULL;
    }
    if (client->instance && client->instance->context) {
        const char *settings_password = freerdp_settings_get_string(
            client->instance->context->settings, FreeRDP_Password);
        if (settings_password)
            SecureZeroMemory((void *)settings_password, strlen(settings_password));
        (void)freerdp_settings_set_string(client->instance->context->settings,
                                          FreeRDP_Password, NULL);
    }
}

static int32_t rdc_prepare_display_control(rdpSettings *settings) {
    if (!settings)
        return -2;
    if (!freerdp_settings_set_bool(settings, FreeRDP_SupportMonitorLayoutPdu, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE))
        return -2;
    return 0;
}

static int32_t rdc_dispatch_display_control_resize(RDCFreeRDPClient *client,
                                                   uint32_t width,
                                                   uint32_t height) {
    if (!client)
        return -2;
    if (!client->disp || !client->display_control_ready ||
        !client->disp->SendMonitorLayout) {
        client->pending_display_resize = TRUE;
        client->pending_display_width = width;
        client->pending_display_height = height;
        return 0;
    }

    width = MIN(MAX(width, DISPLAY_CONTROL_MIN_MONITOR_WIDTH),
                DISPLAY_CONTROL_MAX_MONITOR_WIDTH);
    height = MIN(MAX(height, DISPLAY_CONTROL_MIN_MONITOR_HEIGHT),
                 DISPLAY_CONTROL_MAX_MONITOR_HEIGHT);
    width -= width % 2;

    const uint64_t max_area =
        (uint64_t)client->display_control_max_area_factor_a *
        client->display_control_max_area_factor_b;
    if ((uint64_t)width * height > max_area) {
        const uint64_t limited_height = max_area / width;
        if (limited_height >= DISPLAY_CONTROL_MIN_MONITOR_HEIGHT) {
            height = (uint32_t)limited_height;
        } else {
            height = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
            width = (uint32_t)(max_area / height);
            width = MIN(width, DISPLAY_CONTROL_MAX_MONITOR_WIDTH);
            width -= width % 2;
        }
    }

    DISPLAY_CONTROL_MONITOR_LAYOUT monitor = {0};
    monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    monitor.Width = width;
    monitor.Height = height;
    monitor.PhysicalWidth = width;
    monitor.PhysicalHeight = height;
    monitor.DesktopScaleFactor = 100;
    monitor.DeviceScaleFactor = 100;
    if (client->disp->SendMonitorLayout(client->disp, 1, &monitor) != CHANNEL_RC_OK)
        return -2;
    client->pending_display_resize = FALSE;
    client->pending_display_width = 0;
    client->pending_display_height = 0;
    return 0;
}

static int32_t rdc_process_command(RDCFreeRDPClient *client) {
    int32_t result = -1;
    rdpContext *context = client->instance->context;
    switch (client->command) {
    case RDC_COMMAND_RESIZE: {
        result = rdc_dispatch_display_control_resize(
            client, client->command_width, client->command_height);
        break;
    }
    case RDC_COMMAND_POINTER:
        result = freerdp_input_send_mouse_event(context->input, client->command_flags,
                                                client->command_x, client->command_y)
                     ? 0
                     : -2;
        break;
    case RDC_COMMAND_KEY:
        result = freerdp_input_send_keyboard_event(context->input, client->command_flags,
                                                   (uint8_t)client->command_code)
                     ? 0
                     : -2;
        break;
    case RDC_COMMAND_UNICODE:
        result = freerdp_input_send_unicode_keyboard_event(
                     context->input, client->command_flags, client->command_code)
                     ? 0
                     : -2;
        break;
    case RDC_COMMAND_SECURE_ATTENTION: {
        const BOOL sent =
            freerdp_input_send_keyboard_event(context->input, 0, 0x1D) &&
            freerdp_input_send_keyboard_event(context->input, 0, 0x38) &&
            freerdp_input_send_keyboard_event(context->input, 0x0100, 0x53) &&
            freerdp_input_send_keyboard_event(context->input, 0x8100, 0x53) &&
            freerdp_input_send_keyboard_event(context->input, 0x8000, 0x38) &&
            freerdp_input_send_keyboard_event(context->input, 0x8000, 0x1D);
        result = sent ? 0 : -2;
        break;
    }
    case RDC_COMMAND_CLIPBOARD_TEXT:
        free(client->clipboard_text);
        client->clipboard_text = client->command_clipboard_text;
        client->command_clipboard_text = NULL;
        result = client->cliprdr &&
                         rdc_clipboard_announce_text(client->cliprdr) == CHANNEL_RC_OK
                     ? 0
                     : -2;
        break;
    case RDC_COMMAND_NONE:
        break;
    }
    client->command = RDC_COMMAND_NONE;
    client->command_result = result;
    (void)ResetEvent(client->command_event);
    (void)SetEvent(client->command_complete_event);
    return result;
}

static void rdc_cancel_pending_command(RDCFreeRDPClient *client) {
    if (WaitForSingleObject(client->command_event, 0) != WAIT_OBJECT_0)
        return;
    client->command = RDC_COMMAND_NONE;
    free(client->command_clipboard_text);
    client->command_clipboard_text = NULL;
    client->command_result = -1;
    (void)ResetEvent(client->command_event);
    (void)SetEvent(client->command_complete_event);
}

static void rdc_close_command_acceptance(RDCFreeRDPClient *client) {
    EnterCriticalSection(&client->lifecycle_lock);
    client->accepting_commands = FALSE;
    LeaveCriticalSection(&client->lifecycle_lock);
    rdc_cancel_pending_command(client);
}

static int32_t rdc_submit_command(RDCFreeRDPClient *client, RDCClientCommand command) {
    EnterCriticalSection(&client->lifecycle_lock);
    if (!client->accepting_commands || !client->polling_thread ||
        WaitForSingleObject(client->worker_finished_event, 0) == WAIT_OBJECT_0) {
        LeaveCriticalSection(&client->lifecycle_lock);
        return -1;
    }
    client->command = command;
    client->command_result = -1;
    (void)ResetEvent(client->command_complete_event);
    (void)SetEvent(client->command_event);
    LeaveCriticalSection(&client->lifecycle_lock);

    const DWORD wait = WaitForSingleObject(client->command_complete_event, INFINITE);
    return wait == WAIT_OBJECT_0 ? client->command_result : -1;
}

static DWORD WINAPI rdc_polling_thread(void *argument) {
    RDCFreeRDPClient *client = argument;
    freerdp *instance = client->instance;
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
    rdc_emit_state(client, RDCFreeRDPStateConnecting, 0, NULL);

    const BOOL connected = freerdp_connect(instance);
    rdc_clear_password(client);
    if (!connected) {
        const uint32_t error = freerdp_get_last_error(instance->context);
        rdc_close_command_acceptance(client);
        if (instance->context->gdi)
            gdi_free(instance);
        (void)SetEvent(client->worker_finished_event);
        if (WaitForSingleObject(client->stop_event, 0) == WAIT_OBJECT_0) {
            rdc_emit_state(client, RDCFreeRDPStateDisconnected, 0, NULL);
        } else {
            rdc_emit_state(client, RDCFreeRDPStateFailed, (int32_t)error,
                           freerdp_get_last_error_string(error));
        }
        return error;
    }

    EnterCriticalSection(&client->lifecycle_lock);
    client->connected = TRUE;
    LeaveCriticalSection(&client->lifecycle_lock);
    rdc_emit_state(client, RDCFreeRDPStateConnected, 0, NULL);
    BOOL failed = FALSE;
    while (WaitForSingleObject(client->stop_event, 0) != WAIT_OBJECT_0 &&
           !freerdp_shall_disconnect_context(instance->context)) {
        handles[0] = client->stop_event;
        handles[1] = client->command_event;
        const DWORD count = freerdp_get_event_handles(instance->context, &handles[2],
                                                       MAXIMUM_WAIT_OBJECTS - 2);
        if (count == 0) {
            failed = TRUE;
            break;
        }

        const DWORD wait = WaitForMultipleObjects(count + 2, handles, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0) {
            break;
        }
        if (wait == WAIT_OBJECT_0 + 1) {
            (void)rdc_process_command(client);
            continue;
        }
        if (wait == WAIT_FAILED || !freerdp_check_event_handles(instance->context)) {
            failed = TRUE;
            break;
        }
    }

    const uint32_t error = freerdp_get_last_error(instance->context);
    (void)freerdp_disconnect(instance);
    EnterCriticalSection(&client->lifecycle_lock);
    client->connected = FALSE;
    client->accepting_commands = FALSE;
    LeaveCriticalSection(&client->lifecycle_lock);
    rdc_cancel_pending_command(client);
    (void)SetEvent(client->worker_finished_event);
    if (failed && error != FREERDP_ERROR_SUCCESS) {
        rdc_emit_state(client, RDCFreeRDPStateFailed, (int32_t)error,
                       freerdp_get_last_error_string(error));
    } else {
        rdc_emit_state(client, RDCFreeRDPStateDisconnected, 0, NULL);
    }
    return error;
}

static BOOL rdc_set_optional_string(rdpSettings *settings,
                                    FreeRDP_Settings_Keys_String key,
                                    const char *value) {
    return freerdp_settings_set_string(settings, key, value);
}

uint32_t rdc_freerdp_bridge_version(void) {
    return FREERDP_VERSION_MAJOR * 10000u + FREERDP_VERSION_MINOR * 10u;
}

RDCFreeRDPClient *rdc_client_create(void *context, RDCFrameCallback frame,
                                    RDCStateCallback state,
                                    RDCCertificateCallback certificate) {
    RDCFreeRDPClient *client = calloc(1, sizeof(*client));
    if (!client)
        return NULL;

    client->callback_context = context;
    client->frame_callback = frame;
    client->state_callback = state;
    client->certificate_callback = certificate;
    InitializeCriticalSection(&client->lifecycle_lock);
    client->lifecycle_lock_initialized = TRUE;
    InitializeCriticalSection(&client->command_lock);
    client->command_lock_initialized = TRUE;
    client->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    client->worker_finished_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    client->command_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    client->command_complete_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    client->certificate_decision_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    client->certificate_callback_finished_event = CreateEvent(NULL, TRUE, TRUE, NULL);
    client->instance = freerdp_new();
    if (!client->stop_event || !client->worker_finished_event || !client->command_event ||
        !client->command_complete_event || !client->certificate_decision_event ||
        !client->certificate_callback_finished_event || !client->instance)
        goto fail;

    client->instance->ContextSize = sizeof(RDCFreeRDPContext);
    client->instance->LoadChannels = rdc_load_channels;
    client->instance->PostConnect = rdc_post_connect;
    client->instance->PostDisconnect = rdc_post_disconnect;
    client->instance->VerifyX509Certificate = rdc_verify_x509_certificate;
    if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) !=
        CHANNEL_RC_OK)
        goto fail;
    if (!freerdp_context_new(client->instance))
        goto fail;
    ((RDCFreeRDPContext *)client->instance->context)->client = client;
    if (PubSub_SubscribeChannelConnected(client->instance->context->pubSub,
                                         rdc_on_channel_connected) < 0)
        goto fail;
    client->clipboard_connected_subscription = TRUE;
    if (PubSub_SubscribeChannelDisconnected(client->instance->context->pubSub,
                                            rdc_on_channel_disconnected) < 0)
        goto fail;
    client->clipboard_disconnected_subscription = TRUE;
    if (!freerdp_settings_set_bool(client->instance->context->settings,
                                   FreeRDP_ExternalCertificateManagement, TRUE))
        goto fail;
    return client;

fail:
    rdc_client_destroy(client);
    return NULL;
}

int32_t rdc_client_connect(RDCFreeRDPClient *client,
                           const RDCConnectionConfiguration *configuration) {
    if (!client || !client->instance || !client->instance->context || !configuration ||
        !configuration->host || configuration->host[0] == '\0')
        return -1;

    EnterCriticalSection(&client->lifecycle_lock);
    if (client->polling_thread) {
        if (WaitForSingleObject(client->worker_finished_event, 0) != WAIT_OBJECT_0) {
            LeaveCriticalSection(&client->lifecycle_lock);
            return -1;
        }
        if (GetCurrentThreadId() == client->polling_thread_id) {
            LeaveCriticalSection(&client->lifecycle_lock);
            return -1;
        }
        (void)WaitForSingleObject(client->polling_thread, INFINITE);
        (void)CloseHandle(client->polling_thread);
        client->polling_thread = NULL;
        client->polling_thread_id = 0;
    }

    rdpSettings *settings = client->instance->context->settings;
    const uint32_t width = configuration->desktop_width ? configuration->desktop_width : 1024u;
    const uint32_t height = configuration->desktop_height ? configuration->desktop_height : 768u;

    if (rdc_prepare_display_control(settings) != 0 ||
        !freerdp_settings_set_string(settings, FreeRDP_ServerHostname, configuration->host) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, configuration->port) ||
        !rdc_set_optional_string(settings, FreeRDP_Username, configuration->username) ||
        !rdc_set_optional_string(settings, FreeRDP_Domain, configuration->domain) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32u) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE))
        goto settings_failed;

    if (configuration->password) {
        client->password_copy = strdup(configuration->password);
        if (!client->password_copy)
            goto settings_failed;
    }
    if (!freerdp_settings_set_string(settings, FreeRDP_Password, client->password_copy)) {
        rdc_clear_password(client);
        goto settings_failed;
    }

    if (!ResetEvent(client->stop_event) || !ResetEvent(client->worker_finished_event)) {
        rdc_clear_password(client);
        LeaveCriticalSection(&client->lifecycle_lock);
        return -3;
    }
    client->accepting_commands = TRUE;
    client->polling_thread =
        CreateThread(NULL, 0, rdc_polling_thread, client, 0, &client->polling_thread_id);
    if (!client->polling_thread) {
        client->accepting_commands = FALSE;
        rdc_clear_password(client);
        LeaveCriticalSection(&client->lifecycle_lock);
        return -3;
    }
    LeaveCriticalSection(&client->lifecycle_lock);
    return 0;

settings_failed:
    LeaveCriticalSection(&client->lifecycle_lock);
    return -2;
}

void rdc_client_disconnect(RDCFreeRDPClient *client) {
    if (!client)
        return;
    EnterCriticalSection(&client->lifecycle_lock);
    client->accepting_commands = FALSE;
    if (client->stop_event)
        (void)SetEvent(client->stop_event);
    if (client->certificate_decision_event)
        (void)SetEvent(client->certificate_decision_event);
    if (client->polling_thread && client->instance && client->instance->context)
        (void)freerdp_abort_connect_context(client->instance->context);
    LeaveCriticalSection(&client->lifecycle_lock);
}

void rdc_client_destroy(RDCFreeRDPClient *client) {
    if (!client)
        return;

    rdc_client_disconnect(client);
    if (client->polling_thread) {
        (void)WaitForSingleObject(client->polling_thread, INFINITE);
        (void)CloseHandle(client->polling_thread);
    }
    if (client->certificate_callback_finished_event)
        (void)WaitForSingleObject(client->certificate_callback_finished_event, INFINITE);
    rdc_clear_password(client);
    free(client->frame_buffer);
    if (client->instance) {
        if (client->instance->context && client->clipboard_connected_subscription)
            PubSub_UnsubscribeChannelConnected(client->instance->context->pubSub,
                                               rdc_on_channel_connected);
        if (client->instance->context && client->clipboard_disconnected_subscription)
            PubSub_UnsubscribeChannelDisconnected(client->instance->context->pubSub,
                                                  rdc_on_channel_disconnected);
        freerdp_context_free(client->instance);
        freerdp_free(client->instance);
    }
    if (client->stop_event)
        (void)CloseHandle(client->stop_event);
    if (client->worker_finished_event)
        (void)CloseHandle(client->worker_finished_event);
    if (client->command_event)
        (void)CloseHandle(client->command_event);
    if (client->command_complete_event)
        (void)CloseHandle(client->command_complete_event);
    if (client->certificate_decision_event)
        (void)CloseHandle(client->certificate_decision_event);
    if (client->certificate_callback_finished_event)
        (void)CloseHandle(client->certificate_callback_finished_event);
    if (client->command_lock_initialized)
        DeleteCriticalSection(&client->command_lock);
    if (client->lifecycle_lock_initialized)
        DeleteCriticalSection(&client->lifecycle_lock);
    free(client->clipboard_text);
    free(client->command_clipboard_text);
    free(client);
}

int32_t rdc_client_resolve_certificate(RDCFreeRDPClient *client,
                                       uint64_t challenge_id,
                                       RDCCertificateDecision decision) {
    if (!client || challenge_id == 0 ||
        (decision != RDCCertificateDecisionReject &&
         decision != RDCCertificateDecisionTrustAlways &&
         decision != RDCCertificateDecisionTrustOnce))
        return -1;

    EnterCriticalSection(&client->lifecycle_lock);
    if (!client->certificate_pending || client->certificate_resolved ||
        client->pending_certificate_id != challenge_id) {
        LeaveCriticalSection(&client->lifecycle_lock);
        return -1;
    }
    client->certificate_decision = decision;
    client->certificate_resolved = TRUE;
    const BOOL signaled = SetEvent(client->certificate_decision_event);
    LeaveCriticalSection(&client->lifecycle_lock);
    return signaled ? 0 : -2;
}

int32_t rdc_client_resize(RDCFreeRDPClient *client, uint32_t width, uint32_t height) {
    if (!client || !client->instance || !client->instance->context || width == 0 || height == 0 ||
        width > INT32_MAX || height > INT32_MAX)
        return -1;

    EnterCriticalSection(&client->lifecycle_lock);
    const BOOL has_worker = client->polling_thread != NULL &&
                            WaitForSingleObject(client->worker_finished_event, 0) != WAIT_OBJECT_0;
    if (has_worker) {
        LeaveCriticalSection(&client->lifecycle_lock);
        EnterCriticalSection(&client->command_lock);
        client->command_width = width;
        client->command_height = height;
        const int32_t result = rdc_submit_command(client, RDC_COMMAND_RESIZE);
        LeaveCriticalSection(&client->command_lock);
        return result;
    }
    rdpSettings *settings = client->instance->context->settings;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height)) {
        LeaveCriticalSection(&client->lifecycle_lock);
        return -2;
    }
    LeaveCriticalSection(&client->lifecycle_lock);
    return 0;
}

int32_t rdc_client_send_pointer(RDCFreeRDPClient *client, uint16_t flags, uint16_t x,
                                uint16_t y) {
    if (!client || !client->instance || !client->instance->context ||
        !client->instance->context->input)
        return -1;
    EnterCriticalSection(&client->command_lock);
    client->command_flags = flags;
    client->command_x = x;
    client->command_y = y;
    const int32_t result = rdc_submit_command(client, RDC_COMMAND_POINTER);
    LeaveCriticalSection(&client->command_lock);
    return result;
}

int32_t rdc_client_send_key(RDCFreeRDPClient *client, uint16_t flags, uint16_t code) {
    if (!client || !client->instance || !client->instance->context ||
        !client->instance->context->input || code > UINT8_MAX)
        return -1;
    EnterCriticalSection(&client->command_lock);
    client->command_flags = flags;
    client->command_code = code;
    const int32_t result = rdc_submit_command(client, RDC_COMMAND_KEY);
    LeaveCriticalSection(&client->command_lock);
    return result;
}

int32_t rdc_client_send_unicode(RDCFreeRDPClient *client, uint16_t flags,
                                uint16_t code_unit) {
    if (!client || !client->instance || !client->instance->context ||
        !client->instance->context->input)
        return -1;
    EnterCriticalSection(&client->command_lock);
    client->command_flags = flags;
    client->command_code = code_unit;
    const int32_t result = rdc_submit_command(client, RDC_COMMAND_UNICODE);
    LeaveCriticalSection(&client->command_lock);
    return result;
}

int32_t rdc_client_send_secure_attention(RDCFreeRDPClient *client) {
    if (!client || !client->instance || !client->instance->context ||
        !client->instance->context->input)
        return -1;
    EnterCriticalSection(&client->command_lock);
    const int32_t result = rdc_submit_command(client, RDC_COMMAND_SECURE_ATTENTION);
    LeaveCriticalSection(&client->command_lock);
    return result;
}

int32_t rdc_client_set_clipboard_text(RDCFreeRDPClient *client,
                                      const uint8_t *utf8, size_t utf8_length) {
    if (!client || !client->instance || !client->instance->context ||
        (utf8_length > 0 && !utf8) || utf8_length > RDC_CLIPBOARD_MAX_UTF8_BYTES)
        return -1;
    char *copy = calloc(utf8_length + 1u, 1u);
    if (!copy)
        return -2;
    if (utf8_length > 0)
        memcpy(copy, utf8, utf8_length);
    size_t wide_length = 0;
    WCHAR *validation = ConvertUtf8ToWCharAlloc(copy, &wide_length);
    free(validation);
    if (!validation) {
        free(copy);
        return -1;
    }

    EnterCriticalSection(&client->command_lock);
    free(client->command_clipboard_text);
    client->command_clipboard_text = copy;
    const int32_t result = rdc_submit_command(client, RDC_COMMAND_CLIPBOARD_TEXT);
    if (client->command_clipboard_text == copy) {
        free(client->command_clipboard_text);
        client->command_clipboard_text = NULL;
    }
    LeaveCriticalSection(&client->command_lock);
    return result;
}

int32_t rdc_client_set_clipboard_callback(RDCFreeRDPClient *client,
                                          RDCClipboardTextCallback callback) {
    if (!client)
        return -1;
    EnterCriticalSection(&client->lifecycle_lock);
    client->clipboard_callback = callback;
    LeaveCriticalSection(&client->lifecycle_lock);
    return 0;
}

int32_t rdc_client_test_invoke_certificate(RDCFreeRDPClient *client,
                                           const uint8_t *pem, size_t pem_length,
                                           const char *host, uint16_t port,
                                           uint32_t flags) {
    if (!client || !client->instance)
        return RDCCertificateDecisionReject;
    return rdc_verify_x509_certificate(client->instance, pem, pem_length, host, port,
                                       flags);
}

int32_t rdc_client_test_external_certificate_management_enabled(
    RDCFreeRDPClient *client) {
    if (!client || !client->instance || !client->instance->context)
        return 0;
    return freerdp_settings_get_bool(client->instance->context->settings,
                                     FreeRDP_ExternalCertificateManagement)
               ? 1
               : 0;
}

int32_t rdc_client_test_set_config_path(RDCFreeRDPClient *client,
                                        const char *config_path) {
    if (!client || !client->instance || !client->instance->context || !config_path ||
        config_path[0] == '\0')
        return -1;

    EnterCriticalSection(&client->lifecycle_lock);
    if (client->polling_thread) {
        LeaveCriticalSection(&client->lifecycle_lock);
        return -1;
    }
    const BOOL updated = freerdp_settings_set_string(
        client->instance->context->settings, FreeRDP_ConfigPath, config_path);
    LeaveCriticalSection(&client->lifecycle_lock);
    return updated ? 0 : -2;
}

static UINT rdc_test_send_display_layout(
    DispClientContext *disp, UINT32 monitor_count,
    DISPLAY_CONTROL_MONITOR_LAYOUT *monitors) {
    if (!disp || !disp->custom || monitor_count != 1 || !monitors)
        return ERROR_INVALID_PARAMETER;
    RDCFreeRDPClient *client = (RDCFreeRDPClient *)disp->custom;
    client->test_sent_display_layout_count += 1;
    client->test_sent_display_layout = monitors[0];
    return CHANNEL_RC_OK;
}

int32_t rdc_client_test_prepare_display_control(RDCFreeRDPClient *client) {
    if (!client || !client->instance || !client->instance->context)
        return -1;
    return rdc_prepare_display_control(client->instance->context->settings);
}

int32_t rdc_client_test_display_control_supported(RDCFreeRDPClient *client) {
    if (!client || !client->instance || !client->instance->context)
        return 0;
    return freerdp_settings_get_bool(client->instance->context->settings,
                                     FreeRDP_SupportDisplayControl)
               ? 1 : 0;
}

int32_t rdc_client_test_dynamic_resolution_enabled(RDCFreeRDPClient *client) {
    if (!client || !client->instance || !client->instance->context)
        return 0;
    return freerdp_settings_get_bool(client->instance->context->settings,
                                     FreeRDP_DynamicResolutionUpdate)
               ? 1 : 0;
}

int32_t rdc_client_test_attach_display_control(RDCFreeRDPClient *client) {
    if (!client)
        return -1;
    memset(&client->test_disp, 0, sizeof(client->test_disp));
    client->test_disp.SendMonitorLayout = rdc_test_send_display_layout;
    client->test_sent_display_layout_count = 0;
    memset(&client->test_sent_display_layout, 0,
           sizeof(client->test_sent_display_layout));
    rdc_attach_display_control(client, &client->test_disp);
    return 0;
}

int32_t rdc_client_test_receive_display_control_caps(
    RDCFreeRDPClient *client, uint32_t max_monitors,
    uint32_t max_area_factor_a, uint32_t max_area_factor_b) {
    if (!client || !client->disp || !client->disp->DisplayControlCaps)
        return -1;
    return (int32_t)client->disp->DisplayControlCaps(
        client->disp, max_monitors, max_area_factor_a, max_area_factor_b);
}

int32_t rdc_client_test_detach_display_control(RDCFreeRDPClient *client) {
    if (!client)
        return -1;
    rdc_detach_display_control(client, client->disp);
    return 0;
}

int32_t rdc_client_test_dispatch_resize(RDCFreeRDPClient *client,
                                        uint32_t width, uint32_t height) {
    return rdc_dispatch_display_control_resize(client, width, height);
}

uint32_t rdc_client_test_sent_display_layout_count(RDCFreeRDPClient *client) {
    return client ? client->test_sent_display_layout_count : 0;
}

uint32_t rdc_client_test_sent_display_layout_width(RDCFreeRDPClient *client) {
    return client ? client->test_sent_display_layout.Width : 0;
}

uint32_t rdc_client_test_sent_display_layout_height(RDCFreeRDPClient *client) {
    return client ? client->test_sent_display_layout.Height : 0;
}
