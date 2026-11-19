///|
fn PairConstant::copy(self : PairConstant) -> PairConstant {
  {
    ..self,
    solref: self.solref.copy(),
    solreffriction: self.solreffriction.copy(),
    solimp: self.solimp.copy(),
    friction: self.friction.copy(),
  }
}

///|
fn PairConstant::validate(self : PairConstant) -> Unit raise ConstantsError {
  check_tuple(self.solref, 2, "pair solref")
  check_tuple(self.solreffriction, 2, "pair solreffriction")
  check_tuple(self.solimp, 5, "pair solimp")
  check_tuple(self.friction, 5, "pair friction")
  guard finite(self.margin) &&
    finite(self.gap) &&
    self.friction.all(value => value >= 0.0) else {
    raise Invalid("pair margin/gap/friction is invalid")
  }
}

///|
/// Real world-major optional attribute updates. Under native CCD the
/// incoming pair margin is suppressed by the caller as in Newton; the old
/// compiled margin is retained, while gap is always forwarded independently.
pub fn update_pairs(
  request : PairUpdate,
) -> Array[Array[PairConstant]] raise ConstantsError {
  let worlds = request.existing.length()
  guard worlds > 0 && request.pairs_per_world >= 0 else {
    raise Invalid("pair world count or source stride is invalid")
  }
  let count = request.existing[0].length()
  guard request.existing.all(row => row.length() == count) &&
    request.pairs_per_world >= count &&
    (
      request.pairs_per_world == 0 ||
      worlds <= 2147483647 / request.pairs_per_world
    ) else {
    raise Invalid("pair output count/world-major source stride is inconsistent")
  }
  let required = worlds * request.pairs_per_world
  let input = request.overrides
  for
    (values, width, label) in [
      (input.solref, 2, "solref"),
      (input.solreffriction, 2, "solreffriction"),
      (input.solimp, 5, "solimp"),
      (input.friction, 5, "friction"),
    ] {
    if values is Some(rows) {
      guard rows.length() == required else {
        raise Invalid(
          "pair " +
          label +
          " attribute has incorrect flat world-major cardinality",
        )
      }
      for row in rows {
        check_tuple(row, width, "pair " + label)
      }
    }
  }
  for (values, label) in [(input.margin, "margin"), (input.gap, "gap")] {
    if values is Some(items) {
      guard items.length() == required && items.all(finite) else {
        raise Invalid(
          "pair " + label + " attribute cardinality/values are invalid",
        )
      }
    }
  }
  request.existing.mapi(fn(world, row) {
    row.mapi(fn(pair, old) {
      old.validate()
      let index = world * request.pairs_per_world + pair
      let updated : PairConstant = {
        solref: match input.solref {
          Some(values) => values[index].copy()
          None => old.solref.copy()
        },
        solreffriction: match input.solreffriction {
          Some(values) => values[index].copy()
          None => old.solreffriction.copy()
        },
        solimp: match input.solimp {
          Some(values) => values[index].copy()
          None => old.solimp.copy()
        },
        friction: match input.friction {
          Some(values) => values[index].copy()
          None => old.friction.copy()
        },
        margin: if request.zero_native_ccd_margins {
          old.margin
        } else {
          match input.margin {
            Some(values) => values[index]
            None => old.margin
          }
        },
        gap: match input.gap {
          Some(values) => values[index]
          None => old.gap
        },
      }
      updated.validate()
      updated
    })
  })
}
