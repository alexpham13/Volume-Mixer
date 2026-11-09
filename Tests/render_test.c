// Run with scripts/check-dsp.sh on macOS.
#include "MixerDSP.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <stddef.h>

static AudioBufferList *list(unsigned count) {
    AudioBufferList *l = calloc(1, offsetof(AudioBufferList, mBuffers) + count*sizeof(AudioBuffer));
    assert(l);
    l->mNumberBuffers = count;
    return l;
}
static void run(MixerDSP *d, AudioBufferList *in, AudioBufferList *out) {
    MixerIO(0, NULL, in, NULL, out, NULL, d);
}
int main(void) {
    // Interleaved input after a hardware mic, planar output. Test the original
    // 48 kHz, stereo Float32 layout and ensure mic samples never reach output.
    AudioBufferList *in = list(2), *out = list(2);
    float mic[4] = {1,1,1,1}, audio[8] = {.5,-.5,.5,-.5,.5,-.5,.5,-.5};
    float left[4], right[4];
    in->mBuffers[0] = (AudioBuffer){1,sizeof(mic),mic};
    in->mBuffers[1] = (AudioBuffer){2,sizeof(audio),audio};
    out->mBuffers[0] = (AudioBuffer){1,sizeof(left),left};
    out->mBuffers[1] = (AudioBuffer){1,sizeof(right),right};
    MixerDSP *probe = MixerCreate(1,1,2,2,1,48000,false);
    run(probe,in,out);
    assert(MixerRead(probe).signals == 1 && MixerRead(probe).rms == .5);
    assert(left[0] == 0 && right[3] == 0);
    MixerFree(probe);
    MixerDSP *a = MixerCreate(1,1,2,2,.5,48000,true);
    MixerDSP *b = MixerCreate(1,1,2,2,1,48000,true);
    run(a,in,out);
    assert(left[0] == .25 && right[3] == -.25);
    assert(MixerRead(a).outputRMS == .25 && MixerRead(a).rms == .5);
    MixerGain(a,0);
    for (unsigned i = 0; i < 80; ++i) run(a,in,out);
    assert(left[3] == 0 && right[0] == 0 && MixerRead(a).signals > 0);
    run(b,in,out);
    assert(left[3] == .5 && right[0] == -.5);
    audio[0] = NAN; audio[1] = 3;
    run(b,in,out);
    assert(left[0] == 0 && right[0] == 1);
    in->mBuffers[1].mDataByteSize--;
    run(b,in,out);
    assert(MixerRead(b).faults == 1 && left[3] == 0 && right[0] == 0);
    MixerFree(a); MixerFree(b);
    // Planar input -> interleaved output, then a valid silent buffer.
    in->mBuffers[0] = (AudioBuffer){1,sizeof(left),left};
    in->mBuffers[1] = (AudioBuffer){1,sizeof(right),right};
    out->mNumberBuffers = 1;
    out->mBuffers[0] = (AudioBuffer){2,sizeof(audio),audio};
    a = MixerCreate(0,2,2,1,1,48000,true);
    run(a,in,out);
    assert(MixerRead(a).calls == 1 && MixerRead(a).signals == 0);
    left[2] = .75; right[2] = -.25;
    run(a,in,out);
    assert(audio[4] == .75 && audio[5] == -.25);
    MixerFree(a); free(in); free(out);
}
