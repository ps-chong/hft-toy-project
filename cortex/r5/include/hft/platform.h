/*
 * C ABI between the R5 trading firmware and its platform adapter.
 *
 * The AMD FreeRTOS BSP build implements these hooks in C; the host demo
 * (cortex/r5/src/host_platform.cpp) implements them over Unix sockets; the
 * freestanding CI link uses the weak stubs in firmware_main.cpp.
 *
 * Every hook documents the single execution context allowed to call it. The
 * firmware never calls a hook from two contexts, so adapters need no locks,
 * and no hook may block: each either completes or reports "not now".
 *
 * Records are opaque 64-byte IPC images whose layout is generated from
 * protocol/schema/ipc.yaml (normalized_event, order_intent, risk_config).
 */
#ifndef HFT_PLATFORM_H
#define HFT_PLATFORM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* C++ callers rely on hooks never throwing; every declaration and definition
 * of a hook must therefore carry the same exception specification. */
#ifdef __cplusplus
#define HFT_PLATFORM_NOEXCEPT noexcept
extern "C" {
#else
#define HFT_PLATFORM_NOEXCEPT
#endif

#define HFT_IPC_RECORD_SIZE 64u

/* One wire-format IPC record. Alignment is 1 so adapters may point it at any
 * DMA, RPMsg, or socket buffer; the firmware copies it into aligned storage. */
struct hft_ipc_record {
    unsigned char bytes[HFT_IPC_RECORD_SIZE];
};

/* Monotonic nanoseconds. Context: trading task. Must be wait-free. */
uint64_t hft_platform_now_ns(void) HFT_PLATFORM_NOEXCEPT;

/* Fetch the next normalized market event, or return false when none is ready.
 * Context: trading task. The adapter owns the source buffer; the firmware
 * copies `out` before returning to the adapter. */
bool hft_platform_poll_event(struct hft_ipc_record *out) HFT_PLATFORM_NOEXCEPT;

/* Offer one approved order intent to the A53 transport. Returning false means
 * "transport full, retry later": the firmware keeps the intent queued and
 * counts the refusal. Context: trading task. `intent` is valid only for the
 * duration of the call. */
bool hft_platform_publish_intent(const struct hft_ipc_record *intent) HFT_PLATFORM_NOEXCEPT;

/* Fetch the next risk_config record from the RPMsg control endpoint.
 * Context: control task only. */
bool hft_platform_poll_config(struct hft_ipc_record *out) HFT_PLATFORM_NOEXCEPT;

/* Emit one formatted diagnostic line (no terminator). Context: log drain task
 * only, so RPMsg sends are never interleaved. `text` is not NUL terminated. */
bool hft_platform_publish_log(const char *text, size_t length) HFT_PLATFORM_NOEXCEPT;

/* Hand one journaled market event to a noncritical consumer (for example a
 * telemetry endpoint). Context: journal task only. Dropping is allowed. */
bool hft_platform_publish_journal(const struct hft_ipc_record *event) HFT_PLATFORM_NOEXCEPT;

/* Cache maintenance for rings shared with the PL. Invalidate before reading
 * PL-written lines; clean after writing lines the PL reads. Context: any task;
 * must be reentrant (no shared state). Host adapters implement them as no-ops
 * because host memory is coherent. */
void hft_platform_dcache_invalidate(const void *address, size_t length) HFT_PLATFORM_NOEXCEPT;
void hft_platform_dcache_clean(const void *address, size_t length) HFT_PLATFORM_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif /* HFT_PLATFORM_H */
