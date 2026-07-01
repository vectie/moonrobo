///|
test "curation keeps accepted episodes and records rejected lineage" {
  let input = @moondata_core.dataset_manifest(
    "dataset-raw",
    "canonical",
    "active",
    10L,
    episode_ids=["ep-good", "ep-bad"],
  )
  let rejected = @moondata_core.moondata_ref(
    "episode", "ep-bad", "episodes/ep-bad.json", "operator rejected episode",
  )
  let result = @moondata_transform.curate_dataset(
    @moondata_transform.curation_request(
      "transform-1",
      "dataset-curated",
      "version-1",
      "lineage-1",
      input,
      ["ep-good"],
      20L,
      rejected_refs=[rejected],
      quality_run_ids=["quality-1"],
      summary="first curated version",
    ),
  )
  assert_eq(result.dataset.kind, "curated")
  assert_eq(result.dataset.episode_ids.length(), 1)
  assert_eq(result.version.accepted_episode_ids[0], "ep-good")
  assert_eq(result.transform.rejected_refs.length(), 1)
  assert_eq(result.lineage.edges.length(), 4)
}
