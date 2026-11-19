///|
/// Explicit fixed inputs for upstream differential execution. This is an input
/// seam into the production update, not a second learner implementation.
/// FixtureHeads selects the exact cheap heads from test_aligned_learning.py;
/// it never claims to model physical reward or Isaac execution.
pub(all) enum DifferentialHeads {
  PhysicalHeads
  FixtureHeads
} derive(Eq, Debug)

///|
pub(all) struct FixedPolicyBatch {
  starts : Array[ReplayStart]
  goals : Array[Array[Array[Double]]]
  critic_permutations : Array[Array[Int32]]
  heads : DifferentialHeads
}

///|
fn FixedPolicyBatch::validate(
  self : FixedPolicyBatch,
  c : LearnerConfig,
) -> Unit raise {
  guard !c.observation_noise else {
    fail("fixed differential input requires explicit noise-free source charter")
  }
  guard self.starts.length() == c.policy_batch &&
    self.goals.length() == c.horizon + 1 &&
    self.starts.all(s => s.history.length() == c.hist) else {
    fail("fixed policy start/history/horizon shape mismatch")
  }
  guard self.goals.all(rows => {
    rows.length() == c.policy_batch &&
    rows.all(row => row.length() == 73 * c.goal_frames && row.all(finite))
  }) else {
    fail("fixed policy goals shape or finite values mismatch")
  }
  guard self.critic_permutations.length() == c.critic_epochs else {
    fail("fixed critic epoch count mismatch")
  }
  let n = c.horizon * c.policy_batch
  for permutation in self.critic_permutations {
    let seen : Map[Int32, Bool] = {}
    for x in permutation {
      guard x >= 0 && x < n && !seen.contains(x) else {
        fail("critic permutation is not bijective")
      }
      seen[x] = true
    }
    guard permutation.length() == n else {
      fail("critic permutation length mismatch")
    }
  }
}

///|
fn fixture_heads(fixed : FixedPolicyBatch?) -> Bool {
  fixed is Some({ heads: FixtureHeads, .. })
}

///|
fn fixed_observation(
  s : State,
  previous : Array[Double],
  xi : Array[Double],
  default_q : Array[Double],
  reference : State,
  mode : ObservationMode,
  fixed : FixedPolicyBatch?,
) -> Array[Double] {
  if !fixture_heads(fixed) {
    return observation(s, previous, xi, default_q, reference, mode)
  }
  let out = s.q.copy()
  out.append(s.qd)
  out.append(s.w)
  out.append(s.rotation[6:9].map(x => -x))
  out.append(previous)
  out
}

///|
fn fixed_ad_observation(
  t : @numeric.Tape,
  s : ADState,
  previous : Array[@numeric.Value],
  xi : Array[Double],
  default_q : Array[Double],
  reference : State,
  mode : ObservationMode,
  fixed : FixedPolicyBatch?,
) -> Array[@numeric.Value] {
  if !fixture_heads(fixed) {
    return ad_observation(t, s, previous, xi, default_q, reference, mode)
  }
  let out = s.q.copy()
  out.append(s.qd)
  out.append(s.w)
  out.append(ad_scale(t, s.rotation[6:9].to_owned(), -1.0))
  out.append(previous)
  out
}

///|
fn fixed_critic_features(
  t : @numeric.Tape,
  kin : Kinematics,
  s : ADState,
  reference : State,
  bodies : Array[BodyState],
  xi : Array[Double],
  goal : Array[Double],
  fixed : FixedPolicyBatch?,
) -> Array[@numeric.Value] {
  if !fixture_heads(fixed) {
    return ad_critic_features(t, kin, s, reference, bodies, xi, goal)
  }
  let out = ad_invariant(t, s)
  out.append(t.vector(Array::make(113, 0.0)))
  out.append(t.vector(goal))
  out
}

///|
fn fixed_reward(
  t : @numeric.Tape,
  kin : Kinematics,
  s : ADState,
  reference : State,
  bodies : Array[BodyState],
  action : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  cfg : RewardConfig,
  fixed : FixedPolicyBatch?,
) -> @numeric.Value {
  if !fixture_heads(fixed) {
    return ad_reward(t, kin, s, reference, bodies, action, previous, cfg)
  }
  t.sub(
    t.scale(t.exp(t.scale(ad_square(t, s.q), -1.0 / 29.0)), 0.1),
    t.scale(ad_square(t, ad_sub(t, action, previous)), 0.002),
  )
}

///|
fn fixed_failure(
  t : @numeric.Tape,
  s : ADState,
  reference : State,
  cfg : RewardConfig,
  fixed : FixedPolicyBatch?,
) -> @numeric.Value {
  if !fixture_heads(fixed) {
    return ad_failure(t, s, reference, cfg)
  }
  t.sigmoid(t.scale(t.sub(t.scalar(0.5), s.p[2]), 50.0))
}

///|
pub fn WorldModel::fit_fixed(
  self : WorldModel,
  windows : Array[ReplayWindow],
  optimizer : @numeric.Adam,
  gradient_trace? : (String, Int32, Array[Double], Array[Double], Double) -> Unit,
) -> WorldFitMetrics raise {
  guard !windows.is_empty() && !windows[0].transitions.is_empty() else {
    fail("empty fixed differential windows")
  }
  self.fit(
    ReplayBuffer::new(1, 1),
    optimizer,
    @numeric.Rng::new(1U),
    batches=1,
    batch=windows.length(),
    window=windows[0].transitions.length(),
    fixed_windows=windows,
    gradient_trace?,
  )
}

///|
pub fn Learner::update_policy_fixed(
  self : Learner,
  input : FixedPolicyBatch,
  train_critic~ : Bool = true,
  gradient_trace? : (String, Int32, Array[Double], Array[Double], Double) -> Unit,
) -> PolicyMetrics raise {
  self.update_policy(
    ReplayBuffer::new(1, 1),
    train_critic~,
    fixed=input,
    gradient_trace?,
  )
}
