#include "CDotNetEq.h"
#include <algorithm>
#include <cstring>
#include <memory>
#include <optional>
#include <span>
#include "api/audio/audio_frame.h"
#include "api/audio_codecs/audio_decoder_factory.h"
#include "api/environment/environment_factory.h"
#include "api/make_ref_counted.h"
#include "api/neteq/default_neteq_factory.h"
#include "modules/audio_coding/codecs/opus/audio_decoder_opus.h"
#include "system_wrappers/include/clock.h"
#include "third_party/opus/src/include/opus.h"

namespace {
class OpusOnlyFactory : public webrtc::AudioDecoderFactory {
 public:
  std::vector<webrtc::AudioCodecSpec> GetSupportedDecoders() override { return {}; }
  bool IsSupportedDecoder(const webrtc::SdpAudioFormat& format) override {
    return format.name == "opus" && format.clockrate_hz == 48000;
  }
  std::unique_ptr<webrtc::AudioDecoder> Create(const webrtc::Environment& env,
                                             const webrtc::SdpAudioFormat& format) override {
    if (!IsSupportedDecoder(format)) return nullptr;
    return std::make_unique<webrtc::AudioDecoderOpusImpl>(env.field_trials(), 1, 48000);
  }
};
}
struct DotNetEq {
  int min_delay_ms, max_delay_ms;
  std::unique_ptr<webrtc::SimulatedClock> clock;
  std::optional<webrtc::Environment> environment;
  std::unique_ptr<webrtc::NetEq> receiver;
  DotNetEq(int64_t now, int min, int max) : min_delay_ms(min), max_delay_ms(max) { Reset(now); }
  void Reset(int64_t now) {
    receiver.reset(); environment.reset(); clock = std::make_unique<webrtc::SimulatedClock>(now);
    environment.emplace(webrtc::CreateEnvironment(clock.get()));
    webrtc::NetEq::Config config; config.sample_rate_hz = 48000;
    config.min_delay_ms = min_delay_ms; config.max_delay_ms = max_delay_ms;
    receiver = webrtc::DefaultNetEqFactory().Create(*environment, config, webrtc::make_ref_counted<OpusOnlyFactory>());
    receiver->SetCodecs({{111, webrtc::SdpAudioFormat("opus", 48000, 2,
      {{"stereo", "0"}, {"sprop-stereo", "0"}, {"useinbandfec", "1"}})}});
  }
  bool Advance(int64_t now) {
    if (now < clock->CurrentTime().us()) return false;
    clock->AdvanceTimeMicroseconds(now - clock->CurrentTime().us()); return true;
  }
};
struct DotOpusDecoder { OpusDecoder* decoder; };
extern "C" {
DotNetEq* dot_neteq_create(int64_t now, int32_t min, int32_t max) {
  if (now < 0 || min < 0 || min > 1000 || max < 0 || max > 2000 || (max && max < min)) return nullptr;
  try { return new DotNetEq(now, min, max); } catch (...) { return nullptr; }
}
void dot_neteq_destroy(DotNetEq* receiver) { delete receiver; }
int32_t dot_neteq_reset(DotNetEq* receiver, int64_t now) {
  if (!receiver || now < 0) return -1;
  try { receiver->Reset(now); return 0; } catch (...) { return -1; }
}
int32_t dot_neteq_insert(DotNetEq* receiver, const uint8_t* payload, size_t length,
                        uint16_t sequence, uint32_t timestamp, int64_t arrival, int64_t processing) {
  if (!receiver || !receiver->receiver || !payload || !length || length > 61440 || arrival < 0 || processing < arrival) return -1;
  try {
    if (!receiver->Advance(processing)) return -2;
    webrtc::RTPHeader header; header.payloadType = 111; header.sequenceNumber = sequence;
    header.timestamp = timestamp; header.ssrc = 1;
    return receiver->receiver->InsertPacket(header, std::span<const uint8_t>(payload, length), webrtc::Timestamp::Micros(arrival));
  } catch (...) { return -1; }
}
int32_t dot_neteq_get_audio(DotNetEq* receiver, int64_t now, int16_t* output, DotNetEqFrameInfo* info) {
  if (!receiver || !receiver->receiver || !output || now < 0) return -1;
  try {
    if (!receiver->Advance(now)) return -2;
    webrtc::AudioFrame frame; bool muted = false;
    int status = receiver->receiver->GetAudio(&frame, &muted);
    if (status != webrtc::NetEq::kOK) return status;
    if (frame.sample_rate_hz_ != 48000 || frame.num_channels_ != 1 || frame.samples_per_channel_ != 480) return -3;
    if (muted) std::memset(output, 0, 960); else std::memcpy(output, frame.data(), 960);
    if (info) {
      auto timestamp = receiver->receiver->GetPlayoutTimestamp();
      *info = {frame.timestamp_, timestamp.value_or(0), timestamp.has_value(),
        int32_t(frame.speech_type_), muted, 48000, 1, 480};
    }
    return 0;
  } catch (...) { return -1; }
}
int32_t dot_neteq_get_stats(DotNetEq* receiver, DotNetEqStats* stats) {
  if (!receiver || !receiver->receiver || !stats) return -1;
  auto lifetime = receiver->receiver->GetLifetimeStatistics();
  auto state = receiver->receiver->GetOperationsAndState();
  auto network = receiver->receiver->CurrentNetworkStatistics();
  *stats = {lifetime.jitter_buffer_packets_received, lifetime.packets_discarded,
    lifetime.concealed_samples, lifetime.silent_concealed_samples, lifetime.concealment_events,
    lifetime.removed_samples_for_acceleration, lifetime.inserted_samples_for_deceleration,
    lifetime.fec_packets_received, state.current_buffer_size_ms, network.preferred_buffer_size_ms,
    state.packet_buffer_flushes, lifetime.jitter_buffer_delay_ms, lifetime.jitter_buffer_emitted_count,
    uint64_t(std::max(0, lifetime.interruption_count)), uint64_t(std::max(0, lifetime.total_interruption_duration_ms))};
  return 0;
}
DotOpusDecoder* dot_opus_decoder_create(void) {
  int error = 0; auto decoder = opus_decoder_create(48000, 1, &error);
  if (!decoder || error != OPUS_OK) return nullptr;
  return new DotOpusDecoder{decoder};
}
void dot_opus_decoder_destroy(DotOpusDecoder* decoder) {
  if (decoder) { opus_decoder_destroy(decoder->decoder); delete decoder; }
}
int32_t dot_opus_decoder_decode(DotOpusDecoder* decoder, const uint8_t* payload,
                               size_t length, int16_t* output, size_t capacity) {
  if (!decoder || !payload || !length || length > 61440 || !output || !capacity || capacity > 5760) return -1;
  return opus_decode(decoder->decoder, payload, int32_t(length), output, int(capacity), 0);
}
}
