///|
/// This command is intentionally never invoked by static migration checks.
async fn main {
  let args = @env.args()
  match args {
    [_, "list"] =>
      println(@differential.contract_inventory().stringify(indent=2))
    [_, "export", template, source_root, library, output] => {
      let manifest : @differential.FixtureManifest = @json.from_json(
        @artifacts.load_json(template),
      )
      let sha = @differential.export_oracle_fixture(
        manifest, source_root, library, output,
      )
      println(
        (
          {
            "fixture_sha256": sha,
            "oracle_kind": manifest.oracle_kind,
            "upstream_python_executed": false,
          } : Json).stringify(),
      )
    }
    [_, "run", folder, source_root, sha, library, output] =>
      println(
        @differential.run_fixture(folder, source_root, sha, library, output)
        .to_json()
        .stringify(indent=2),
      )
    [_, "verify-capture", folder, source_root, sha, capture, output] =>
      println(
        @differential.verify_capture(folder, source_root, sha, capture, output)
        .to_json()
        .stringify(indent=2),
      )
    _ =>
      fail(
        "usage: reference_differential list | export TEMPLATE SOURCE_ROOT LIBTORCH_ORACLE OUTPUT | run FIXTURE SOURCE_ROOT MANIFEST_SHA LIBTORCH_ORACLE OUTPUT | verify-capture FIXTURE SOURCE_ROOT MANIFEST_SHA CAPTURE OUTPUT_JSON",
      )
  }
}
