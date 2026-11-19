#include "../status_cdr.hpp"
#include <algorithm>
#include <limits>

using Packet = std::array<uint8_t, 1156>;
using e1_status::Layout;

void check(bool pass) {
  if (!pass) throw std::runtime_error("E1 CDR regression");
}

template<typename T>
void put(Packet& bytes, size_t at, T value) {
  std::array<uint8_t, sizeof(T)> field;
  std::memcpy(field.data(), &value, sizeof(value));
  const uint16_t one = 1;
  if ((*reinterpret_cast<const uint8_t*>(&one) == 1) != (bytes[1] == 1))
    std::reverse(field.begin(), field.end());
  std::copy(field.begin(), field.end(), bytes.begin() + at);
}

void rejected(const Packet& packet, size_t size, Layout layout) {
  try { (void)e1_status::decode(packet.data(), size, layout); }
  catch (const std::runtime_error&) { return; }
  throw std::runtime_error("invalid E1 status accepted");
}

int main() {
  for (auto layout : {Layout::captured, Layout::sdk31}) {
    for (uint8_t endian : {0, 1}) {
      Packet p{};
      p[1] = endian;
      const size_t count = layout == Layout::captured ? 372 : 376;
      // Both candidate count locations look plausible. Schema identity must win.
      put(p, 372, uint32_t{24});
      put(p, 376, uint32_t{24});
      if (layout == Layout::sdk31) put(p, 372, uint16_t{24});
      for (uint16_t j = 0; j < 24; ++j) {
        const size_t at = 380 + 32*j;
        put(p, at, j + 0.5); put(p, at+8, j - 0.5); put(p, at+16, j + 1.5);
        put(p, at+24, j); put(p, at+26, uint16_t{7}); put(p, at+28, int32_t{-10});
      }
      auto v = e1_status::decode(p.data(), p.size(), layout);
      for (size_t j = 0; j < 24; ++j) {
        const std::array<double,6> expected{double(j), j+0.5, j-0.5, j+1.5, 7, -10};
        check(std::equal(expected.begin(), expected.end(), v.begin() + 6*j));
      }
      check(v[170] == (layout == Layout::captured ? -1 : 24));
      rejected(p, p.size()-1, layout);
      put(p, count, uint32_t{0}); rejected(p, p.size(), layout);
      put(p, count, uint32_t{24});
      put(p, 380+23*32+24, uint16_t{22}); rejected(p, p.size(), layout);
      put(p, 380+23*32+24, uint16_t{23});
      put(p, 380, std::numeric_limits<double>::infinity()); rejected(p, p.size(), layout);
    }
  }
}
