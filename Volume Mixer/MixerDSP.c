#include "MixerDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && sizeof(float) == sizeof(unsigned), "Requires lock-free 32-bit atomics");
struct MixerDSP {
    unsigned offset, inputs, channels, outputs;
    bool render;
    float current, step;
    atomic_uint target, calls, signals, faults, rms, outputRMS;
};

static unsigned bits(float x) {
    unsigned n;
    memcpy(&n, &x, sizeof(n));
    return n;
}
static float value(unsigned n) {
    float x;
    memcpy(&x, &n, sizeof(x));
    return x;
}
MixerDSP *MixerCreate(unsigned offset, unsigned inputs, unsigned channels,
                      unsigned outputs, float gain, double rate, bool render) {
    MixerDSP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->offset = offset;
    s->inputs = inputs;
    s->channels = channels;
    s->outputs = outputs;
    s->current = gain;
    s->step = (float)(1.0 / (rate * 0.005));
    s->render = render;
    atomic_init(&s->target, bits(gain));
    atomic_init(&s->calls, 0);
    atomic_init(&s->signals, 0);
    atomic_init(&s->faults, 0);
    atomic_init(&s->rms, 0);
    atomic_init(&s->outputRMS, 0);
    return s;
}
void MixerFree(MixerDSP *s) { free(s); }
void MixerGain(MixerDSP *s, float gain) {
    atomic_store_explicit(&s->target, bits(gain), memory_order_relaxed);
}
MixerMeter MixerRead(const MixerDSP *s) {
    return (MixerMeter){atomic_load(&s->calls), atomic_load(&s->signals),
                        atomic_load(&s->faults), value(atomic_load(&s->rms)),
                        value(atomic_load(&s->outputRMS))};
}

// Resolve channel pointers once per callback. Reject inconsistent sizes,
// missing planes and topology changes before reading a single sample.
static bool planes(const AudioBufferList *list, unsigned offset, unsigned count,
                   unsigned channels, float **p, unsigned *stride, unsigned *frames) {
    if (!list || offset > list->mNumberBuffers || list->mNumberBuffers-offset != count ||
        channels < 1 || channels > 2 || (count != 1 && count != channels)) return false;
    *stride = channels / count;
    for (unsigned i = 0; i < count; ++i) {
        const AudioBuffer *b = &list->mBuffers[offset+i];
        unsigned width = sizeof(float) * *stride;
        if (!b->mData || b->mNumberChannels != *stride || b->mDataByteSize % width) return false;
        unsigned length = b->mDataByteSize / width;
        if (!length || (i && length != *frames)) return false;
        *frames = length;
        for (unsigned j = 0; j < *stride; ++j)
            p[i * *stride + j] = (float *)b->mData + j;
    }
    return true;
}

OSStatus MixerIO(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                 const AudioTimeStamp *inputTime, AudioBufferList *output,
                 const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MixerDSP *s = context;
    atomic_fetch_add_explicit(&s->calls, 1, memory_order_relaxed);
    float *in[2], *out[2];
    unsigned is, os, nf = 0, no = 0;
    bool valid = planes(input, s->offset, s->inputs, s->channels, in, &is, &nf) &&
                 planes(output, 0, s->outputs, s->channels, out, &os, &no) && nf == no;
    if (!valid || !s->render) {
        if (output) for (unsigned i = 0; i < output->mNumberBuffers; ++i) {
            AudioBuffer *b = &output->mBuffers[i];
            if (b->mData) memset(b->mData, 0, b->mDataByteSize);
        }
        if (!valid) {
            atomic_fetch_add(&s->faults, 1);
            return 0;
        }
    }
    float target = value(atomic_load_explicit(&s->target, memory_order_relaxed));
    double energy = 0, outputEnergy = 0;
    for (unsigned i = 0; i < nf; ++i) {
        s->current += fmaxf(-s->step, fminf(s->step, target-s->current));
        for (unsigned ch = 0; ch < s->channels; ++ch) {
            float sample = in[ch][i*is];
            if (!isfinite(sample)) sample = 0;
            energy += (double)sample * sample;
            if (s->render) {
                float processed = fmaxf(-1, fminf(1, sample*s->current));
                out[ch][i*os] = processed;
                outputEnergy += (double)processed * processed;
            }
        }
    }
    float rms = (float)sqrt(energy / ((double)nf*s->channels));
    atomic_store_explicit(&s->rms, bits(rms), memory_order_relaxed);
    atomic_store_explicit(&s->outputRMS, bits((float)sqrt(outputEnergy / ((double)nf*s->channels))), memory_order_relaxed);
    if (rms > 0.000001f) atomic_fetch_add_explicit(&s->signals, 1, memory_order_relaxed);
    return 0;
}
