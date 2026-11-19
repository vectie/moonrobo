///|
/// One explicit inference backend, with deterministic release. Portable CPU
/// reference selection is explicit and never a fallback from Ascend execution.
pub struct Actor {
  priv bundle : Bundle
  priv predict : (Array[Array[Double]], Array[Double]) -> Array[Double] raise
  priv release : () -> Unit raise
  priv mut closed : Bool
}

///|
pub fn Actor::open_ascend(
  bundle : Bundle,
  library : String,
  model : String,
  device~ : Int32 = 0,
) -> Self raise {
  let runtime = @ascend.Runtime::open(library)
  let session = {
    errdefer (runtime.close() catch { _ => () })
    runtime.prepare(model, bundle.spec, device~)
  }
  let history_buffer = FixedArray::make(bundle.spec.history_width(), 0.0F)
  let goals_buffer = FixedArray::make(bundle.spec.goal_width(), 0.0F)
  let actions = FixedArray::make(29, 0.0F)
  {
    bundle,
    predict: (history, goals) => {
      for frame, row in history {
        for feature, value in row {
          history_buffer[frame * bundle.spec.observation_width + feature] = Float::from_double(
            value,
          )
        }
      }
      for index, value in goals {
        goals_buffer[index] = Float::from_double(value)
      }
      session.run_into(history_buffer, goals_buffer, actions)
      Array::makei(29, index => actions[index].to_double())
    },
    release: () => {
      {
        errdefer (runtime.close() catch { _ => () })
        session.close()
      }
      runtime.close()
    },
    closed: false,
  }
}

///|
pub fn Actor::reference(bundle : Bundle, parameters : BytesView) -> Self raise {
  let reference = @portable.Reference::prepare(bundle.spec, parameters)
  {
    bundle,
    predict: (history, goals) => {
      let flat : Array[Double] = []
      for row in history {
        flat.append(row)
      }
      reference.run(flat[:], goals[:])
    },
    release: () => (),
    closed: false,
  }
}

///|
pub fn Actor::bundle(self : Self) -> Bundle {
  self.bundle
}

///|
pub fn Actor::forward_embedded(
  self : Self,
  history : Array[Array[Double]],
  goals : Array[Double],
) -> Array[Double] raise {
  guard !self.closed &&
    history.length() == self.bundle.history_frames() &&
    history.all(row => {
      row.length() == self.bundle.observation_width() &&
      row.all(@portable.finite)
    }) &&
    goals.length() == self.bundle.goal_width() &&
    goals.all(@portable.finite) else {
    fail("closed E1 actor or input shape/finite-value mismatch")
  }
  self.bundle.project((self.predict)(history, goals))
}

///|
pub fn Actor::forward(
  self : Self,
  history : Array[Array[Double]],
  goals : Array[Double],
) -> Array[Double] raise {
  self.forward_embedded(history, goals)[:self.bundle.joints().length()].to_owned()
}

///|
pub fn Actor::close(self : Self) -> Unit raise {
  if !self.closed {
    (self.release)()
    self.closed = true
  }
}
