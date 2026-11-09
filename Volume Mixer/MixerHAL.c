#include "MixerDSP.h"
#include <libproc.h>
#include <stddef.h>
#include <stdlib.h>

pid_t MixerParent(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return (pid_t)info.pbi_ppid;
}
int MixerBufferCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size)) return -1;
    if (size == 0) return 0;
    AudioBufferList *list = malloc(size);
    if (!list) return -1;
    int result = -1;
    if (!AudioObjectGetPropertyData(device, &a, 0, NULL, &size, list) &&
        size >= offsetof(AudioBufferList, mBuffers) &&
        list->mNumberBuffers <= (size - offsetof(AudioBufferList, mBuffers))/sizeof(AudioBuffer))
        result = (int)list->mNumberBuffers;
    free(list);
    return result;
}
OSStatus MixerDisableHardwareInputs(AudioObjectID device, AudioDeviceIOProcID proc,
                                   unsigned hardware, unsigned total) {
    if (hardware == 0) return 0;
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + total * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = total;
    for (unsigned i = hardware; i < total; ++i) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
