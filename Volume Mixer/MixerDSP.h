#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <sys/types.h>

// Only the control thread creates and releases this state. The IOProc reads
// immutable layout fields and exchanges scalar gain/meter values atomically.
typedef struct MixerDSP MixerDSP;
typedef struct {
    unsigned calls, signals, faults;
    float rms, outputRMS;
} MixerMeter;

MixerDSP *MixerCreate(unsigned inputOffset, unsigned inputBuffers, unsigned channels,
                      unsigned outputBuffers, float gain, double sampleRate, bool render);
void MixerFree(MixerDSP *state);
void MixerGain(MixerDSP *state, float gain);
MixerMeter MixerRead(const MixerDSP *state);
OSStatus MixerIO(AudioObjectID device, const AudioTimeStamp *now,
                 const AudioBufferList *input, const AudioTimeStamp *inputTime,
                 AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
int MixerBufferCount(AudioObjectID device, AudioObjectPropertyScope scope);
pid_t MixerParent(pid_t pid);
OSStatus MixerDisableHardwareInputs(AudioObjectID aggregate, AudioDeviceIOProcID proc,
                                   unsigned hardwareStreams, unsigned allStreams);
