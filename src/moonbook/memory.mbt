///|
pub(all) struct MoonBookMemoryCard {
  memory_id : String
  robot_id : String
  resident_id : String
  kind : String
  priority : Int
  title : String
  summary : String
  evidence_path : String
  next_route : String
  created_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonBookMemoryPack {
  pack_id : String
  robot_id : String
  resident_id : String
  generated_at_ms : Int64
  card_count : Int
  highest_priority : Int
  cards : Array[MoonBookMemoryCard]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn card(
  robot_id : String,
  resident_id : String,
  kind : String,
  priority : Int,
  title : String,
  summary : String,
  evidence_path : String,
  next_route : String,
  created_at_ms : Int64,
) -> MoonBookMemoryCard {
  {
    memory_id: "memory-\{robot_id}-\{kind}-\{created_at_ms}",
    robot_id,
    resident_id,
    kind,
    priority,
    title,
    summary,
    evidence_path,
    next_route,
    created_at_ms,
  }
}

///|
fn resident_memory(
  resident : @resident.ResidentRobotAgent,
  generated_at_ms : Int64,
) -> MoonBookMemoryCard {
  card(
    resident.robot_id,
    resident.resident_id,
    "resident-state",
    50,
    "Resident robot state",
    "Robot is \{resident.availability}; bridge is \{resident.bridge_state}; safety is \{resident.safety_state}",
    resident.town_route,
    "/api/moontown/resident",
    generated_at_ms,
  )
}

///|
fn observation_memory(
  resident : @resident.ResidentRobotAgent,
  generated_at_ms : Int64,
) -> MoonBookMemoryCard? {
  match resident.latest_observation {
    Some(observation) =>
      Some(
        card(
          resident.robot_id,
          resident.resident_id,
          "latest-observation",
          65,
          "Latest observation",
          "\{observation.status} observation \{observation.session_id} with \{observation.telemetry_frame_count} frame(s)",
          match observation.latest_artifact_path {
            Some(path) => path
            None => "/api/replays/\{observation.session_id}"
          },
          "/api/replays/\{observation.session_id}",
          generated_at_ms,
        ),
      )
    None => None
  }
}

///|
fn latest_review(
  reviews : Array[@review.ProcessReview],
) -> @review.ProcessReview? {
  if reviews.is_empty() {
    None
  } else {
    Some(reviews[reviews.length() - 1])
  }
}

///|
fn review_memory(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  generated_at_ms : Int64,
) -> MoonBookMemoryCard? {
  match latest_review(reviews) {
    Some(review) =>
      Some(
        card(
          resident.robot_id,
          resident.resident_id,
          "latest-review",
          if review.disposition == NeedsHumanReview {
            90
          } else {
            55
          },
          "Latest process review",
          review.summary,
          "/api/reviews/\{review.review_id}",
          if review.disposition == NeedsHumanReview {
            "/api/reviews"
          } else {
            "/api/moonclaw/context"
          },
          generated_at_ms,
        ),
      )
    None => None
  }
}

///|
fn next_work_memory(
  resident : @resident.ResidentRobotAgent,
  queue : @work_queue.AgentWorkQueue,
  generated_at_ms : Int64,
) -> MoonBookMemoryCard? {
  match queue.next_item {
    Some(item) =>
      Some(
        card(
          resident.robot_id,
          resident.resident_id,
          "next-work",
          item.priority,
          item.title,
          item.summary,
          item.target_path,
          "/api/agent/next-action",
          generated_at_ms,
        ),
      )
    None => None
  }
}

///|
fn runtime_health_memory(
  resident : @resident.ResidentRobotAgent,
  latest_runtime_health : @runtime_health.RuntimeHealthRecord?,
  generated_at_ms : Int64,
) -> MoonBookMemoryCard? {
  match latest_runtime_health {
    Some(record) =>
      Some(
        card(
          resident.robot_id,
          resident.resident_id,
          "runtime-health",
          @runtime_health.priority(record),
          "Runtime health",
          @runtime_health.summary(record),
          "/runs/runtime-health/latest.json",
          if record.status == "healthy" {
            "/api/moonbook/memory"
          } else {
            "/api/runtime/health"
          },
          generated_at_ms,
        ),
      )
    None => None
  }
}

///|
fn highest_priority(cards : Array[MoonBookMemoryCard]) -> Int {
  let mut value = 0
  for card in cards {
    if card.priority > value {
      value = card.priority
    }
  }
  value
}

///|
pub fn project(
  resident : @resident.ResidentRobotAgent,
  reviews : Array[@review.ProcessReview],
  queue : @work_queue.AgentWorkQueue,
  generated_at_ms : Int64,
  latest_runtime_health? : @runtime_health.RuntimeHealthRecord? = None,
) -> MoonBookMemoryPack {
  let cards = [resident_memory(resident, generated_at_ms)]
  match observation_memory(resident, generated_at_ms) {
    Some(memory) => cards.push(memory)
    None => ()
  }
  match review_memory(resident, reviews, generated_at_ms) {
    Some(memory) => cards.push(memory)
    None => ()
  }
  match next_work_memory(resident, queue, generated_at_ms) {
    Some(memory) => cards.push(memory)
    None => ()
  }
  match
    runtime_health_memory(resident, latest_runtime_health, generated_at_ms) {
    Some(memory) => cards.push(memory)
    None => ()
  }
  {
    pack_id: "moonbook-memory-\{resident.robot_id}-\{generated_at_ms}",
    robot_id: resident.robot_id,
    resident_id: resident.resident_id,
    generated_at_ms,
    card_count: cards.length(),
    highest_priority: highest_priority(cards),
    cards,
  }
}

///|
pub fn memory_pack_json(pack : MoonBookMemoryPack, indent? : Int = 2) -> String {
  pack.to_json().stringify(indent~)
}
