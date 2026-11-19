#pragma once

#include <chrono>
#include <cstddef>

namespace moonrobo_e1_candidate {

constexpr std::size_t kMotorCount = 24;

template <typename States>
bool complete_motor_ids(const States &states) {
        if (states.size() != kMotorCount) {
                return false;
        }
        for (std::size_t i = 0; i < kMotorCount; i++) {
                if (static_cast<int>(states[i].motor_id()) !=
                    static_cast<int>(i)) {
                        return false;
                }
        }
        return true;
}

inline bool fresh_at(std::chrono::steady_clock::time_point now,
                     std::chrono::steady_clock::time_point received_at,
                     std::chrono::steady_clock::duration max_age) {
        return now >= received_at && now - received_at <= max_age;
}

} // namespace moonrobo_e1_candidate
