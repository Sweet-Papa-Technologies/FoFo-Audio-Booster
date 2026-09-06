#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FFBridge FFBridge;
FFBridge * _Nullable ff_bridge_create(const char * _Nonnull path);
FFBridge * _Nullable ff_bridge_open(const char * _Nonnull path);
void ff_bridge_close(FFBridge * _Nullable bridge);
void ff_bridge_mark_dead(FFBridge * _Nullable bridge);
int32_t ff_bridge_fault_slot(FFBridge * _Nullable bridge);
uint32_t ff_bridge_failed_slots(FFBridge * _Nullable bridge);
uint32_t ff_bridge_misses(FFBridge * _Nullable bridge);
void ff_bridge_set_editing(FFBridge * _Nullable bridge, int32_t slot);
// Parent audio callback: bounded lock-free exchange; late/dead worker uses delayed dry audio.
bool ff_bridge_exchange(FFBridge * _Nonnull bridge, float * _Nonnull left, float * _Nonnull right, uint32_t frames);
// Worker only. These functions never execute in the parent audio callback.
OSStatus ff_bridge_add_unit(FFBridge * _Nonnull bridge, AudioUnit _Nonnull unit, uint32_t slot);
void ff_bridge_worker_start(FFBridge * _Nonnull bridge);
void ff_bridge_worker_stop(FFBridge * _Nonnull bridge);
// Deterministic worker fault injection, available only through the explicit validation command.
void ff_bridge_test_fault(FFBridge * _Nonnull bridge, int32_t slot);
#ifdef __cplusplus
}
#endif
