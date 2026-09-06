#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include "PluginBridge.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FFEngine FFEngine;
typedef struct { float reductionDB; float peak; float loudnessLUFS; uint32_t failures; uint64_t callbacks; uint32_t pluginFailures; float integratedLUFS; } FFMeters;
FFEngine * _Nullable ff_create(double sampleRate, uint32_t sourceCount, uint32_t inputChannelOffset, bool analysisOnly);
void ff_destroy(FFEngine * _Nullable engine);
OSStatus ff_configure_stream_usage(AudioObjectID device, AudioDeviceIOProcID _Nonnull proc, uint32_t tapStreams, bool analysisOnly);
void ff_attach_remote(FFEngine * _Nullable engine, FFBridge * _Nullable bridge);
void ff_set_source(FFEngine * _Nullable engine, uint32_t source, float db, bool muted);
void ff_set_master(FFEngine * _Nullable engine, float db, float ceilingDB, float balance, bool mono, bool loudness, float targetLUFS, float capDB);
void ff_set_fade(FFEngine * _Nullable engine, bool audible);
void ff_set_monitor_source(FFEngine * _Nullable engine, int32_t index);
void ff_set_analysis(FFEngine * _Nullable engine, bool enabled);
FFMeters ff_meters(FFEngine * _Nullable engine);
uint32_t ff_read_samples(FFEngine * _Nullable engine, float * _Nonnull destination, uint32_t capacity);
// Graph mutations below are legal only while the IOProc is stopped.
OSStatus ff_attach_plugin(FFEngine * _Nullable engine, AudioUnit _Nonnull unit, uint32_t slot, bool bypass, uint32_t extraDelayFrames);
void ff_bypass_plugin(FFEngine * _Nullable engine, uint32_t slot, bool bypass);
OSStatus ff_io_proc(AudioObjectID device, const AudioTimeStamp * _Nonnull now, const AudioBufferList * _Nonnull input,
                    const AudioTimeStamp * _Nonnull inputTime, AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
// Planar stereo offline entry point used by the DSP regression suite.
void ff_process(FFEngine * _Nullable engine, const float * _Nonnull left, const float * _Nonnull right, float * _Nonnull outLeft, float * _Nonnull outRight, uint32_t frames);
#ifdef __cplusplus
}
#endif
