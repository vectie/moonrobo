///|
/// Long-form CSV, one row per channel per compared sample and one row per gap.
/// Rows stay in elapsed-time order. Missing values are empty, never zero-filled.
pub fn Comparison::to_csv(self : Comparison) -> String {
  let out = StringBuilder()
  out.write_string(
    "elapsed_ms,baseline_timestamp_ms,candidate_left_timestamp_ms,candidate_right_timestamp_ms,status,channel,baseline,candidate,delta\n",
  )
  let mut next_sample = 0
  let mut next_gap = 0
  while next_sample < self.samples.length() || next_gap < self.gaps.length() {
    if next_gap < self.gaps.length() &&
      (
        next_sample == self.samples.length() ||
        self.gaps[next_gap].elapsed_ms < self.samples[next_sample].elapsed_ms
      ) {
      let gap = self.gaps[next_gap]
      out.write_string(
        "\{gap.elapsed_ms},\{gap.baseline_timestamp_ms},,,\{gap.reason},,,,\n",
      )
      next_gap += 1
    } else {
      let sample = self.samples[next_sample]
      let status = if sample.interpolated { "interpolated" } else { "exact" }
      for i, channel in self.channels {
        let escaped = channel.replace(old="\"", new="\"\"")
        out.write_string(
          "\{sample.elapsed_ms},\{sample.baseline_timestamp_ms},\{sample.candidate_left_timestamp_ms},\{sample.candidate_right_timestamp_ms},\{status},\"\{escaped}\",\{sample.baseline[i]},\{sample.candidate[i]},\{sample.delta[i]}\n",
        )
      }
      next_sample += 1
    }
  }
  out.to_string()
}
