// Read-only SDK low ABI. DDS resolves the publisher's topic type before
// reading serialized samples. This module never constructs a controller.
#include "status_cdr.hpp"
#include <dds/dds.h>
#include <dds/ddsi/ddsi_serdata.h>
#include <dds/ddsi/ddsi_typelib.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;
using e1_status::Layout;
constexpr char topic_name[] = "Robot_Status_Topic";
struct State {
  std::mutex data, lifecycle;
  dds_entity_t participant = 0;
  e1_status::Values values{};
  std::string fault = "no valid E1 status received";
  Clock::time_point received{};
};
State& state() { static auto* s = new State; return *s; }

template<class Op> int checked(char* error, int cap, Op op) {
  try { op(); return 0; }
  catch (const std::exception& e) {
    if (error && cap > 0) std::snprintf(error, cap, "%s", e.what());
    return -1;
  }
}
int require(int result, const char* operation) {
  if (result < 0) throw std::runtime_error(std::string(operation) + ": " + dds_strretcode(result));
  return result;
}

// Complete XTypes identifiers cover member order, names and nested types.
// In particular, padding and an SDK workmode of 24 are never motor counts.
Layout advertised_layout(const dds_typeinfo_t* type) {
  const auto* id = ddsi_typeinfo_complete_typeid(type);
  if (!id || !ddsi_typeid_is_hash(id)) throw std::runtime_error("missing complete E1 status type");
  DDS_XTypes_EquivalenceHash hash;
  ddsi_typeid_get_equivalence_hash(id, &hash);
  char hex[2 * sizeof(hash) + 1]{};
  for (size_t i = 0; i < sizeof(hash); ++i) std::snprintf(hex + i*2, 3, "%02x", hash[i]);
  if (std::strcmp(hex, "b3617b7931e35c3364f2545e5159") == 0) return Layout::captured;
  if (std::strcmp(hex, "9adb49e3135976a00830ec277a1f") == 0) return Layout::sdk31;
  throw std::runtime_error(std::string("unsupported E1 status type ") + hex);
}

void receive(dds_entity_t reader, void* context) {
  auto& s = state();
  std::lock_guard<std::mutex> lock(s.data);
  try {
    ddsi_serdata* sample = nullptr;
    dds_sample_info_t info{};
    int n = require(dds_takecdr(reader, &sample, 1, &info, DDS_ANY_STATE), "take status");
    if (!n) return;
    auto unref = [](ddsi_serdata* data) { ddsi_serdata_unref(data); };
    std::unique_ptr<ddsi_serdata, decltype(unref)> release(sample, unref);
    if (!info.valid_data) throw std::runtime_error("invalid DDS status sample");
    std::array<uint8_t,1156> bytes;
    if (ddsi_serdata_size(sample) != bytes.size()) throw std::runtime_error("unknown E1 status size");
    ddsi_serdata_to_ser(sample, 0, bytes.size(), bytes.data());
    s.values = e1_status::decode(bytes.data(), bytes.size(), *static_cast<const Layout*>(context));
    s.received = Clock::now();
    s.fault.clear();
  } catch (const std::exception& e) { s.fault = e.what(); }
}

void subscribe(dds_entity_t participant, dds_builtintopic_endpoint_t& ep) {
  const dds_typeinfo_t* type = nullptr;
  require(dds_builtintopic_get_endpoint_type_info(&ep, &type), "get status type");
  if (!type) throw std::runtime_error("status publisher has no type information");
  static Layout profiles[] = {Layout::captured, Layout::sdk31};
  auto& layout = profiles[static_cast<int>(advertised_layout(type))];
  dds_topic_descriptor_t* descriptor = nullptr;
  require(dds_create_topic_descriptor(DDS_FIND_SCOPE_GLOBAL, participant, type, DDS_SECS(4), &descriptor), "resolve advertised status type");
  std::unique_ptr<dds_topic_descriptor_t, decltype(&dds_delete_topic_descriptor)> descriptor_guard(descriptor, dds_delete_topic_descriptor);
  auto topic = require(dds_create_topic(participant, descriptor, topic_name, nullptr, nullptr), "create status topic");
  std::unique_ptr<dds_qos_t, decltype(&dds_delete_qos)> qos(dds_create_qos(), dds_delete_qos);
  uint32_t n = 0;
  char** partitions = nullptr;
  if (dds_qget_partition(ep.qos, &n, &partitions)) {
    dds_qset_partition(qos.get(), n, const_cast<const char**>(partitions));
    for (uint32_t i = 0; i < n; ++i) dds_free(partitions[i]);
    dds_free(partitions);
  }
  auto subscriber = require(dds_create_subscriber(participant, qos.get(), nullptr), "create status subscriber");
  dds_reset_qos(qos.get());
  dds_qset_reliability(qos.get(), DDS_RELIABILITY_BEST_EFFORT, 0);
  dds_qset_type_consistency(qos.get(), DDS_TYPE_CONSISTENCY_DISALLOW_TYPE_COERCION,
                           false, false, false, true, true);
  const dds_data_representation_id_t id = DDS_DATA_REPRESENTATION_XCDR1;
  dds_qset_data_representation(qos.get(), 1, &id);
  std::unique_ptr<dds_listener_t, decltype(&dds_delete_listener)> listener(dds_create_listener(&layout), dds_delete_listener);
  dds_lset_data_available(listener.get(), receive);
  require(dds_create_reader(subscriber, topic, qos.get(), listener.get()), "create status reader");
}
}  // namespace

// File-replay entry point uses exactly the same decoder as the subscription.
// Source payload is a complete encapsulated DDS StatusData, not a motor slice.
extern "C" int moonrobo_e1_status_decode(int profile, const uint8_t* bytes, size_t size, double* out, int count,
                                         char* error, int cap) {
  return checked(error, cap, [&] {
    if (!out || count != 171) throw std::runtime_error("status requires a 171-field buffer");
    if (profile != 0 && profile != 1) throw std::runtime_error("unknown E1 recording schema");
    auto v = e1_status::decode(bytes, size, static_cast<Layout>(profile));
    std::copy(v.begin(), v.end(), out);
  });
}
extern "C" int moonrobo_e1_low_init(char* error, int cap) {
  return checked(error, cap, [&] {
    auto& s = state();
    std::lock_guard<std::mutex> lock(s.lifecycle);
    if (s.participant) return;
    auto participant = require(dds_create_participant(0, nullptr, nullptr), "create participant");
    try {
      auto discovery = require(dds_create_reader(participant, DDS_BUILTIN_TOPIC_DCPSPUBLICATION, nullptr, nullptr), "discover status writer");
      const auto deadline = Clock::now() + std::chrono::seconds(6);
      while (Clock::now() < deadline) {
        void* sample = nullptr;
        dds_sample_info_t info{};
        if (require(dds_take(discovery, &sample, &info, 1, 1), "read discovery")) {
          auto* ep = static_cast<dds_builtintopic_endpoint_t*>(sample);
          bool match = info.valid_data && std::strcmp(ep->topic_name, topic_name) == 0 &&
                       std::strcmp(ep->type_name, "RobotStatus::StatusData") == 0;
          try { if (match) subscribe(participant, *ep); }
          catch (...) { dds_return_loan(discovery, &sample, 1); throw; }
          dds_return_loan(discovery, &sample, 1);
          if (match) { dds_delete(discovery); s.participant = participant; return; }
        } else std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      throw std::runtime_error("E1 status publisher was not discovered");
    } catch (...) { dds_delete(participant); throw; }
  });
}
extern "C" int moonrobo_e1_low_capture(double* out, int count, int64_t* age, char* error, int cap) {
  return checked(error, cap, [&] {
    auto& s = state();
    std::lock_guard<std::mutex> lock(s.data);
    if (!s.fault.empty()) throw std::runtime_error(s.fault);
    if (!out || !age || count != 171) throw std::runtime_error("invalid status buffer");
    std::copy(s.values.begin(), s.values.end(), out);
    *age = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - s.received).count();
  });
}
extern "C" int moonrobo_e1_low_joint_index(const char* name, int32_t* index, char* error, int cap) {
  static const char* names[] = {"arm_l1_joint","arm_l2_joint","arm_l3_joint","arm_l4_joint","arm_l5_joint",
    "leg_l1_joint","leg_l2_joint","leg_l3_joint","leg_l4_joint","leg_l5_joint","leg_l6_joint",
    "arm_r1_joint","arm_r2_joint","arm_r3_joint","arm_r4_joint","arm_r5_joint",
    "leg_r1_joint","leg_r2_joint","leg_r3_joint","leg_r4_joint","leg_r5_joint","leg_r6_joint","waist_1_joint","waist_2_joint"};
  return checked(error, cap, [&] {
    if (name && index) for (int i = 0; i < 24; ++i)
      if (std::strcmp(name, names[i]) == 0) { *index = i; return; }
    throw std::runtime_error("unknown E1 SDK joint");
  });
}
extern "C" int moonrobo_e1_low_publish(const double*, int, char* error, int cap) {
  return checked(error, cap, [] { throw std::runtime_error("read-only E1 status adapter"); });
}
