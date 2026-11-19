#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>

// Full, fixed-size XCDR1 status shapes observed on E1 and in SDK 3.1.
// Both occupy 1156 bytes. In the capture the uint32 sequence length is at
// byte 372; 3.1 puts workmode there and the length at 376. Alignment puts
// the 24 motor records at the same offset in both layouts.
namespace e1_status {
using Values = std::array<double, 171>;
enum class Layout { captured = 0, sdk31 = 1 };

class Cdr {
 public:
  Cdr(const uint8_t* bytes, size_t size) : bytes_(bytes) {
    if (!bytes || size != 1156 || bytes[0] != 0 || bytes[1] > 1 ||
        bytes[2] != 0 || bytes[3] != 0)
      throw std::runtime_error("expected complete E1 XCDR1 status");
    little_ = bytes[1] == 1;
  }

  template<typename T> T get(size_t offset) const {
    T value;
    const uint16_t one = 1;
    const bool native_little = *reinterpret_cast<const uint8_t*>(&one) == 1;
    auto* dest = reinterpret_cast<uint8_t*>(&value);
    if (little_ == native_little) std::memcpy(dest, bytes_ + offset, sizeof(T));
    else for (size_t i = 0; i < sizeof(T); ++i) dest[i] = bytes_[offset + sizeof(T) - i - 1];
    return value;
  }

 private:
  const uint8_t* bytes_;
  bool little_;
};

inline Values decode(const uint8_t* bytes, size_t size, Layout layout) {
  Cdr c(bytes, size);
  if (c.get<uint32_t>(layout == Layout::captured ? 372 : 376) != 24)
    throw std::runtime_error("E1 status requires exactly 24 motors for the selected schema");
  Values out{};
  for (size_t slot = 0; slot < 24; ++slot) {
    const size_t at = 380 + 32 * slot;
    if (c.get<uint16_t>(at + 24) != slot)
      throw std::runtime_error("E1 status motor ID differs from its SDK slot");
    const size_t i = 6 * slot;
    out[i] = slot;
    out[i + 1] = c.get<double>(at);
    out[i + 2] = c.get<double>(at + 8);
    out[i + 3] = c.get<double>(at + 16);
    out[i + 4] = c.get<uint16_t>(at + 26);
    out[i + 5] = c.get<int32_t>(at + 28);
  }
  for (size_t i = 0; i < 4; ++i) out[144 + i] = c.get<double>(4 + 8 * i);
  for (size_t i = 0; i < 3; ++i) {
    out[148 + i] = c.get<double>(108 + 8 * i);
    out[151 + i] = c.get<double>(204 + 8 * i);
  }
  for (size_t i = 0; i < 2; ++i) out[154 + i] = c.get<double>(300 + 8 * i);
  for (size_t i = 0; i < 14; ++i) out[156 + i] = c.get<int32_t>(316 + 4 * i);
  out[170] = layout == Layout::captured ? -1 : static_cast<int>(c.get<uint16_t>(372));
  for (double v : out) if (!std::isfinite(v)) throw std::runtime_error("nonfinite E1 telemetry");
  return out;
}
}  // namespace e1_status
