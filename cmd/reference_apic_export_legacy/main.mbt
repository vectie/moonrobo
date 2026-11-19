///|
/// Offline authoring is an explicit command, never part of normal migration
/// typechecks or production replay. CONFIG is a JSON ExportConfig.
async fn main {
  let args = @env.args()
  match args {
    [_, "diagnose-sdk", config, tape, manifest, output] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      let result = @producer.trace_sdk(
        config,
        tape,
        manifest,
        output,
        diagnostic=true,
      )
      println(result.stringify(indent=2))
      guard result is { "success": true, .. } else {
        fail("SDK diagnostic failed; see preserved report")
      }
    }
    [_, "trace-sdk", config, tape, manifest, output] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @producer.trace_sdk(config, tape, manifest, output).stringify(indent=2),
      )
    }
    [_, "export", config] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@producer.export_bundle(config).stringify(indent=2))
    }
    _ =>
      fail(
        "usage: reference_apic_export_legacy export CONFIG.json | {trace-sdk|diagnose-sdk} CONFIG.json TAPE.json MANIFEST.json REPORT.json (explicit pinned SDK/CUDA work; never run by static checks)",
      )
  }
}
