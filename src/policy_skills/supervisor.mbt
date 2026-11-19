///|
fn finite(x : Double) -> Bool {
  x == x && x - x == 0.0
}

///|
fn active(state : State) -> Bool {
  match state {
    Accepted | Running => true
    _ => false
  }
}

///|
/// Pure skill lifecycle. It neither runs an actor nor grants robot authority.
/// A runner consumes accepted references and reports observed outcomes.
pub struct Supervisor {
  priv catalog_id : String
  priv skills : Array[Skill]
  priv mut context_version : Int64
  priv mut highest_sequence : Int64
  priv mut last_request : Request?
  priv mut current : Execution?
}

///|
pub fn Supervisor::new(
  catalog_id : String,
  skills : Array[Skill],
) -> Supervisor raise SkillError {
  guard !catalog_id.is_empty() && !skills.is_empty() else {
    raise InvalidSkill("empty catalog")
  }
  let seen : Map[String, Bool] = Map([])
  for skill in skills {
    guard !skill.id.is_empty() &&
      !skill.reference_id.is_empty() &&
      skill.maximum_duration_ms > 0 &&
      !seen.contains(skill.id) else {
      raise InvalidSkill("invalid or duplicate skill")
    }
    seen[skill.id] = true
    let names : Map[String, Bool] = Map([])
    for p in skill.parameters {
      guard !p.name.is_empty() &&
        !names.contains(p.name) &&
        finite(p.minimum) &&
        finite(p.maximum) &&
        finite(p.default_value) &&
        p.minimum <= p.default_value &&
        p.default_value <= p.maximum else {
        raise InvalidSkill("invalid parameter range/default")
      }
      names[p.name] = true
    }
  }
  {
    catalog_id,
    skills,
    context_version: 0L,
    highest_sequence: -1L,
    last_request: None,
    current: None,
  }
}

///|
pub fn Supervisor::catalog(self : Supervisor) -> Catalog {
  {
    catalog_id: self.catalog_id,
    context_version: self.context_version,
    last_sequence: self.highest_sequence,
    skills: self.skills,
  }
}

///|
pub fn Supervisor::version(self : Supervisor) -> Int64 {
  self.context_version
}

///|
pub fn Supervisor::snapshot(self : Supervisor, now_ms : Int64) -> Execution? {
  if self.current is Some(e) && active(e.state) && now_ms >= e.deadline_ms {
    self.current = Some({
      ..e,
      state: Interrupted,
      detail: "execution deadline expired",
    })
    self.context_version += 1L
  }
  self.current
}

///|
pub fn Supervisor::accept(
  self : Supervisor,
  request : Request,
  now_ms : Int64,
) -> Execution raise SkillError {
  ignore(self.snapshot(now_ms))
  if self.current is Some(e) && request.request_id == e.request_id {
    guard self.last_request == Some(request) else {
      raise Rejected("request id reused with different content")
    }
    return e
  }
  guard !request.request_id.is_empty() &&
    request.sequence > self.highest_sequence else {
    raise Rejected("stale request sequence")
  }
  guard request.catalog_id == self.catalog_id &&
    request.context_version == self.context_version else {
    raise Rejected("stale catalog or control context")
  }
  guard request.expires_at_ms > now_ms && now_ms >= 0L else {
    raise Rejected("request expired")
  }
  if self.current is Some(e) && active(e.state) {
    raise Rejected("another skill is active; cancel it explicitly")
  }
  guard self.skills.search_by(skill => skill.id == request.proposal.skill_id)
    is Some(index) else {
    raise Rejected("unknown skill")
  }
  let skill = self.skills[index]
  let values : Map[String, Double] = Map([])
  for key, _ in request.proposal.parameters {
    guard skill.parameters.any(p => p.name == key) else {
      raise Rejected("unknown skill parameter")
    }
  }
  for p in skill.parameters {
    let value = request.proposal.parameters
      .get(p.name)
      .unwrap_or(p.default_value)
    guard finite(value) && value >= p.minimum && value <= p.maximum else {
      raise Rejected("skill parameter outside qualified range")
    }
    values[p.name] = value
  }
  guard now_ms <= 9223372036854775807L - skill.maximum_duration_ms.to_int64() else {
    raise Rejected("deadline overflow")
  }
  let maximum = now_ms + skill.maximum_duration_ms.to_int64()
  let deadline = if request.expires_at_ms < maximum {
    request.expires_at_ms
  } else {
    maximum
  }
  let execution : Execution = {
    request_id: request.request_id,
    sequence: request.sequence,
    skill_id: skill.id,
    reference_id: skill.reference_id,
    parameters: values,
    state: Accepted,
    accepted_at_ms: now_ms,
    deadline_ms: deadline,
    detail: "",
  }
  self.current = Some(execution)
  self.highest_sequence = request.sequence
  self.last_request = Some(request)
  self.context_version += 1L
  execution
}

///|
pub fn Supervisor::start(
  self : Supervisor,
  request_id : String,
  now_ms : Int64,
) -> Execution raise SkillError {
  guard self.snapshot(now_ms) is Some(e) && e.request_id == request_id else {
    raise Rejected("unknown execution")
  }
  guard e.state is Accepted || e.state is Running else {
    raise Rejected("execution is terminal")
  }
  let next = { ..e, state: Running, }
  self.current = Some(next)
  next
}

///|
pub fn Supervisor::finish(
  self : Supervisor,
  request_id : String,
  success~ : Bool,
  detail~ : String,
) -> Execution raise SkillError {
  guard self.current is Some(e) &&
    e.request_id == request_id &&
    e.state is Running else {
    raise Rejected("only a running skill can finish")
  }
  let next = { ..e, state: if success { Completed } else { Failed }, detail, }
  self.current = Some(next)
  self.context_version += 1L
  next
}

///|
pub fn Supervisor::cancel(
  self : Supervisor,
  request_id : String,
  detail~ : String,
) -> Execution raise SkillError {
  guard self.current is Some(e) && e.request_id == request_id else {
    raise Rejected("unknown execution")
  }
  if !active(e.state) {
    return e
  }
  let next = { ..e, state: Interrupted, detail, }
  self.current = Some(next)
  self.context_version += 1L
  next
}
