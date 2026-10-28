#include "PulseDeckAtomics.h"

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PD_RING_CAPACITY 32u
#define PD_RING_MASK (PD_RING_CAPACITY - 1u)
#define PD_MAX_CALLBACK_FRAMES PD_METER_MAX_CALLBACK_FRAMES

_Static_assert((PD_RING_CAPACITY & PD_RING_MASK) == 0u, "Ring capacity must be a power of two");

struct PDMeterRing {
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t dropped_count;
    vDSP_DFT_Setup dft_setup;
    float channel0[PD_MAX_CALLBACK_FRAMES];
    float channel1[PD_MAX_CALLBACK_FRAMES];
    float mono[PD_METER_FFT_SIZE];
    float windowed[PD_METER_FFT_SIZE];
    float window[PD_METER_FFT_SIZE];
    float real[PD_METER_FFT_SIZE / 2u];
    float imaginary[PD_METER_FFT_SIZE / 2u];
    float spectrum_real[PD_METER_SPECTRUM_BINS];
    float spectrum_imaginary[PD_METER_SPECTRUM_BINS];
    PDMeterSample slots[PD_RING_CAPACITY];
};

PDMeterRing *pd_meter_ring_create(void) {
    PDMeterRing *ring = calloc(1u, sizeof(*ring));
    if (ring == NULL) {
        return NULL;
    }

    atomic_init(&ring->write_index, 0u);
    atomic_init(&ring->read_index, 0u);
    atomic_init(&ring->dropped_count, 0u);
    ring->dft_setup = vDSP_DFT_zrop_CreateSetup(NULL, PD_METER_FFT_SIZE, vDSP_DFT_FORWARD);
    if (ring->dft_setup == NULL) {
        free(ring);
        return NULL;
    }
    vDSP_hann_window(ring->window, PD_METER_FFT_SIZE, vDSP_HANN_DENORM);
    return ring;
}

void pd_meter_ring_destroy(PDMeterRing *ring) {
    if (ring == NULL) {
        return;
    }
    if (ring->dft_setup != NULL) {
        vDSP_DFT_DestroySetup(ring->dft_setup);
    }
    free(ring);
}

bool pd_meter_ring_is_lock_free(const PDMeterRing *ring) {
    return ring != NULL
        && atomic_is_lock_free(&ring->write_index)
        && atomic_is_lock_free(&ring->read_index)
        && atomic_is_lock_free(&ring->dropped_count);
}

static float pd_finite_sample(float value) {
    return isfinite(value) ? value : 0.0f;
}

bool pd_meter_ring_push_audio(
    PDMeterRing *ring,
    const float *channel0,
    const float *channel1,
    uint32_t channel_count,
    uint32_t frame_count,
    double sample_rate,
    uint64_t host_time
) {
    if (ring == NULL || channel0 == NULL || channel_count == 0u || channel_count > 2u
        || frame_count == 0u || frame_count > PD_MAX_CALLBACK_FRAMES
        || !isfinite(sample_rate) || sample_rate < 8000.0 || sample_rate > 192000.0
        || (channel_count == 2u && channel1 == NULL)) {
        if (ring != NULL) {
            atomic_fetch_add_explicit(&ring->dropped_count, 1u, memory_order_relaxed);
        }
        return false;
    }

    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    if (write_index - read_index >= PD_RING_CAPACITY) {
        atomic_fetch_add_explicit(&ring->dropped_count, 1u, memory_order_relaxed);
        return false;
    }

    PDMeterSample *sample = &ring->slots[write_index & PD_RING_MASK];
    float energy = 0.0f;
    float peak0 = 0.0f;
    float peak1 = 0.0f;
    for (uint32_t frame = 0u; frame < frame_count; ++frame) {
        ring->channel0[frame] = pd_finite_sample(channel0[frame]);
        if (channel_count == 2u) {
            ring->channel1[frame] = pd_finite_sample(channel1[frame]);
        }
    }
    vDSP_svesq(ring->channel0, 1, &energy, frame_count);
    vDSP_maxmgv(ring->channel0, 1, &peak0, frame_count);
    if (channel_count == 2u) {
        float channel_energy = 0.0f;
        vDSP_svesq(ring->channel1, 1, &channel_energy, frame_count);
        energy += channel_energy;
        vDSP_maxmgv(ring->channel1, 1, &peak1, frame_count);
    }
    sample->rms = sqrtf(energy / ((float)frame_count * (float)channel_count));
    sample->peak = fmaxf(peak0, peak1);

    const float channel_gain = 1.0f / (float)channel_count;
    for (uint32_t frame = 0u; frame < PD_METER_FFT_SIZE; ++frame) {
        float mono = 0.0f;
        if (frame < frame_count) {
            mono = ring->channel0[frame];
            if (channel_count == 2u) {
                mono += ring->channel1[frame];
            }
            mono *= channel_gain;
        }
        ring->mono[frame] = mono;
        ring->windowed[frame] = mono * ring->window[frame];
    }

    for (uint32_t sample_index = 0u; sample_index < PD_METER_FFT_SIZE / 2u; ++sample_index) {
        ring->real[sample_index] = ring->windowed[sample_index * 2u];
        ring->imaginary[sample_index] = ring->windowed[sample_index * 2u + 1u];
    }
    vDSP_DFT_Execute(ring->dft_setup, ring->real, ring->imaginary,
                     ring->spectrum_real, ring->spectrum_imaginary);
    const float scale = 1.0f / (float)PD_METER_FFT_SIZE;
    sample->spectrum[0] = fabsf(ring->spectrum_real[0]) * scale;
    for (uint32_t bin = 1u; bin < PD_METER_SPECTRUM_BINS; ++bin) {
        const float real = ring->spectrum_real[bin];
        const float imaginary = ring->spectrum_imaginary[bin];
        sample->spectrum[bin] = hypotf(real, imaginary) * scale;
    }
    sample->sample_rate = sample_rate;
    sample->host_time = host_time;
    sample->frame_count = frame_count;
    sample->fft_size = PD_METER_FFT_SIZE;
    atomic_store_explicit(&ring->write_index, write_index + 1u, memory_order_release);
    return true;
}

bool pd_meter_ring_pop(PDMeterRing *ring, PDMeterSample *sample) {
    if (ring == NULL || sample == NULL) {
        return false;
    }
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    if (read_index == write_index) {
        return false;
    }
    *sample = ring->slots[read_index & PD_RING_MASK];
    atomic_store_explicit(&ring->read_index, read_index + 1u, memory_order_release);
    return true;
}

uint64_t pd_meter_ring_dropped_count(const PDMeterRing *ring) {
    if (ring == NULL) {
        return 0u;
    }
    return atomic_load_explicit(&ring->dropped_count, memory_order_relaxed);
}
