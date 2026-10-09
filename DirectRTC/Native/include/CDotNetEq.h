#ifndef C_DOT_NETEQ_H
#define C_DOT_NETEQ_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct DotNetEq DotNetEq;
typedef struct DotOpusDecoder DotOpusDecoder;

typedef struct {
    uint32_t frame_rtp_timestamp;
    uint32_t playout_end_rtp;
    int32_t playout_end_valid;
    int32_t speech_type;
    int32_t muted;
    int32_t sample_rate_hz;
    int32_t channels;
    int32_t samples_per_channel;
} DotNetEqFrameInfo;

typedef struct {
    uint64_t packets_received;
    uint64_t packets_discarded;
    uint64_t concealed_samples;
    uint64_t silent_concealed_samples;
    uint64_t concealment_events;
    uint64_t accelerated_samples;
    uint64_t preemptive_samples;
    uint64_t fec_packets_received;
    uint64_t current_buffer_ms;
    uint64_t preferred_buffer_ms;
    uint64_t packet_buffer_flushes;
    uint64_t jitter_buffer_delay_ms;
    uint64_t jitter_buffer_emitted_count;
    uint64_t interruption_count;
    uint64_t interruption_duration_ms;
} DotNetEqStats;

/* Calls are serialized by the owner. Timestamps are monotonic microseconds.
 * Original arrival is metadata; processing/render timestamps drive the clock.
 * 48 kHz mono, exactly 480 PCM16 samples for every successful 10 ms pull.
 * min/max delay bound the adaptive target, not every transient queued packet. */
DotNetEq* dot_neteq_create(int64_t now_us, int32_t min_delay_ms, int32_t max_delay_ms);
void dot_neteq_destroy(DotNetEq* receiver);
int32_t dot_neteq_reset(DotNetEq* receiver, int64_t now_us);
int32_t dot_neteq_insert(DotNetEq* receiver, const uint8_t* payload, size_t payload_length,
                        uint16_t sequence, uint32_t rtp_timestamp,
                        int64_t arrival_us, int64_t processing_us);
int32_t dot_neteq_get_audio(DotNetEq* receiver, int64_t now_us,
                           int16_t output_480[480], DotNetEqFrameInfo* frame_info);
int32_t dot_neteq_get_stats(DotNetEq* receiver, DotNetEqStats* stats);

/* Offline timestamp-reference decoder only. No device or playback is opened.
 * output_capacity is samples, max 5760; return decoded sample count or <0. */
DotOpusDecoder* dot_opus_decoder_create(void);
void dot_opus_decoder_destroy(DotOpusDecoder* decoder);
int32_t dot_opus_decoder_decode(DotOpusDecoder* decoder, const uint8_t* payload,
                               size_t payload_length, int16_t* output,
                               size_t output_capacity);
#ifdef __cplusplus
}
#endif
#endif
