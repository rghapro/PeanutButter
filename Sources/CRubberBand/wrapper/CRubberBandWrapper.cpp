#include "../include/CRubberBand.h"
#include "../vendor/rubberband/RubberBandStretcher.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

extern "C" bool rubberband_r3_process_exact(
    const float * const *inputs,
    size_t inputFrames,
    float * const *outputs,
    size_t outputFrames,
    int channels,
    double sampleRate,
    double semitones,
    double formantSemitones,
    bool preserveFormants
) {
    if (!inputs || !outputs || channels <= 0 || inputFrames == 0 || outputFrames == 0 ||
        !std::isfinite(sampleRate) || sampleRate <= 0.0 ||
        !std::isfinite(semitones) || !std::isfinite(formantSemitones)) {
        return false;
    }

    for (int c = 0; c < channels; ++c) {
        if (!inputs[c] || !outputs[c]) {
            return false;
        }
    }

    try {
        // Fast path for unity pitch, unity length, and no formant modification
        if (semitones == 0.0 && inputFrames == outputFrames && !preserveFormants && formantSemitones == 0.0) {
            for (int c = 0; c < channels; ++c) {
                if (inputs[c] != outputs[c]) {
                    std::memcpy(outputs[c], inputs[c], outputFrames * sizeof(float));
                }
            }
            return true;
        }

        RubberBand::RubberBandStretcher::Options options =
            RubberBand::RubberBandStretcher::OptionProcessOffline |
            RubberBand::RubberBandStretcher::OptionEngineFiner |
            RubberBand::RubberBandStretcher::OptionPitchHighQuality |
            RubberBand::RubberBandStretcher::OptionChannelsTogether |
            (preserveFormants
                ? RubberBand::RubberBandStretcher::OptionFormantPreserved
                : RubberBand::RubberBandStretcher::OptionFormantShifted);

        RubberBand::RubberBandStretcher stretcher(
            static_cast<size_t>(sampleRate),
            static_cast<size_t>(channels),
            options
        );

        const double timeRatio = static_cast<double>(outputFrames) / static_cast<double>(inputFrames);
        const double pitchScale = std::pow(2.0, semitones / 12.0);
        if (!std::isfinite(timeRatio) || timeRatio <= 0.0 || !std::isfinite(pitchScale) || pitchScale <= 0.0) {
            return false;
        }
        stretcher.setTimeRatio(timeRatio);
        stretcher.setPitchScale(pitchScale);
        if (formantSemitones != 0.0) {
            const double formantScale = std::pow(2.0, formantSemitones / 12.0);
            if (!std::isfinite(formantScale) || formantScale <= 0.0) {
                return false;
            }
            stretcher.setFormantScale(formantScale);
        }

        constexpr size_t kBlockFrames = 4096;
        stretcher.setMaxProcessSize(kBlockFrames);

        std::vector<const float *> inPtrs(static_cast<size_t>(channels), nullptr);
        std::vector<float *> outPtrs(static_cast<size_t>(channels), nullptr);
        std::vector<std::vector<float>> scratch(
            static_cast<size_t>(channels),
            std::vector<float>(kBlockFrames, 0.0f)
        );
        std::vector<float *> scratchPtrs(static_cast<size_t>(channels), nullptr);
        for (int c = 0; c < channels; ++c) {
            scratchPtrs[static_cast<size_t>(c)] = scratch[static_cast<size_t>(c)].data();
        }

        // Pass 1: Offline study pass
        size_t inPos = 0;
        while (inPos < inputFrames) {
            size_t chunk = std::min(kBlockFrames, inputFrames - inPos);
            bool isFinal = (inPos + chunk >= inputFrames);
            for (int c = 0; c < channels; ++c) {
                inPtrs[static_cast<size_t>(c)] = inputs[c] + inPos;
            }
            stretcher.study(inPtrs.data(), chunk, isFinal);
            inPos += chunk;
        }

        // Pass 2: Offline process + retrieve pass
        inPos = 0;
        size_t outPos = 0;
        auto drainAvailable = [&]() {
            while (true) {
                int avail = stretcher.available();
                if (avail <= 0) {
                    break;
                }
                size_t toRead = std::min(kBlockFrames, static_cast<size_t>(avail));
                if (outPos < outputFrames) {
                    size_t room = outputFrames - outPos;
                    size_t directRead = std::min(toRead, room);
                    for (int c = 0; c < channels; ++c) {
                        outPtrs[static_cast<size_t>(c)] = outputs[c] + outPos;
                    }
                    size_t got = stretcher.retrieve(outPtrs.data(), directRead);
                    outPos += got;
                    if (got == 0) {
                        break;
                    }
                } else {
                    size_t got = stretcher.retrieve(scratchPtrs.data(), toRead);
                    if (got == 0) {
                        break;
                    }
                }
            }
        };

        while (inPos < inputFrames) {
            size_t chunk = std::min(kBlockFrames, inputFrames - inPos);
            bool isFinal = (inPos + chunk >= inputFrames);
            for (int c = 0; c < channels; ++c) {
                inPtrs[static_cast<size_t>(c)] = inputs[c] + inPos;
            }
            stretcher.process(inPtrs.data(), chunk, isFinal);
            drainAvailable();
            inPos += chunk;
        }

        // Pad any remaining tail frames if Rubber Band returned slightly fewer than outputFrames
        if (outPos < outputFrames) {
            size_t missing = outputFrames - outPos;
            for (int c = 0; c < channels; ++c) {
                std::memset(outputs[c] + outPos, 0, missing * sizeof(float));
            }
        }

        return true;
    } catch (...) {
        return false;
    }
}
