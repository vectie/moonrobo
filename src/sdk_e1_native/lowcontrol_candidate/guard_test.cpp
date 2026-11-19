// Source-only unit checks. This file has no SDK linkage or device access.
#include "guard.hpp"

#include <array>
#include <cassert>
#include <chrono>

struct FakeMotorState {
        int id;
        int motor_id() const { return id; }
};

int main() {
        std::array<FakeMotorState, 24> states{};
        for (int i = 0; i < 24; i++) {
                states[i].id = i;
        }
        assert(moonrobo_e1_candidate::complete_motor_ids(states));
        states[23].id = 22;
        assert(!moonrobo_e1_candidate::complete_motor_ids(states));
        std::array<FakeMotorState, 21> truncated{};
        assert(!moonrobo_e1_candidate::complete_motor_ids(truncated));
        const auto received = std::chrono::steady_clock::now();
        assert(moonrobo_e1_candidate::fresh_at(
            received + std::chrono::milliseconds(40), received,
            std::chrono::milliseconds(40)));
        assert(!moonrobo_e1_candidate::fresh_at(
            received + std::chrono::milliseconds(41), received,
            std::chrono::milliseconds(40)));
        assert(!moonrobo_e1_candidate::fresh_at(
            received - std::chrono::milliseconds(1), received,
            std::chrono::milliseconds(40)));
}
