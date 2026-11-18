#ifndef CRUBBERBAND_H
#define CRUBBERBAND_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

bool rubberband_r3_process_exact(
    const float * const *inputs,
    size_t inputFrames,
    float * const *outputs,
    size_t outputFrames,
    int channels,
    double sampleRate,
    double semitones,
    double formantSemitones,
    bool preserveFormants
);

#ifdef __cplusplus
}
#endif

#endif
