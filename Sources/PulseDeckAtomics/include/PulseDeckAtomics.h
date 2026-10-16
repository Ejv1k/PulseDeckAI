#ifndef PULSEDECK_ATOMICS_H
#define PULSEDECK_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

#define PD_METER_SPECTRUM_BINS 512u
#define PD_METER_FFT_SIZE 1024u

typedef struct PDMeterRing PDMeterRing;

typedef struct {
    float rms;
    float peak;
    float spectrum[PD_METER_SPECTRUM_BINS];
    double sample_rate;
    uint64_t host_time;
    uint32_t frame_count;
    uint32_t fft_size;
} PDMeterSample;

PDMeterRing *pd_meter_ring_create(void);
void pd_meter_ring_destroy(PDMeterRing *ring);
bool pd_meter_ring_is_lock_free(const PDMeterRing *ring);
bool pd_meter_ring_push_audio(
    PDMeterRing *ring,
    const float *channel0,
    const float *channel1,
    uint32_t channel_count,
    uint32_t frame_count,
    double sample_rate,
    uint64_t host_time
);
bool pd_meter_ring_pop(PDMeterRing *ring, PDMeterSample *sample);
uint64_t pd_meter_ring_dropped_count(const PDMeterRing *ring);

#endif
