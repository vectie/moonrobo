///|
/// Compatibility facade for existing learning packages. Concrete types and
/// implementations belong to the independent shared numerical module, so
/// Moonphys and learning use one Tape/MLP/Adam implementation and type identity.
/// The previous source text and SHA256 are archived in
/// docs/migration-baselines/shared-numerics/learning-numeric-before-moonnum.json.
pub using @canonical {
  type Value,
  type Tape,
  type Rng,
  type MLP,
  type Normalization,
  type Adam,
  finite,
  fit_normalization,
}
