///|
/// Long-form CSV: one row per occupied bucket/channel, one row per compressed
/// empty span. Source membership lists use semicolons; indices are zero-based.
/// Empty statistics stay blank. This report is not a resampled recording.
pub fn TelemetryBuckets::to_csv(self : TelemetryBuckets) -> String {
  let out = StringBuilder()
  out.write_string(
    "status,alignment,origin_ms,width_ms,window_start_ms,window_end_ms,source_sample_count,first_bucket_index,last_bucket_index,selected_start_ms,selected_end_ms,empty_bucket_count,channel,sample_count,first_timestamp_ms,last_timestamp_ms,first,last,minimum,maximum,sample_weighted_mean,source_sample_indices,source_timestamps_ms\n",
  )
  let prefix = "\{self.alignment},\{self.origin_ms},\{self.width_ms},\{self.start_ms},\{self.end_ms},\{self.source_sample_count}"
  let mut bi = 0
  let mut gi = 0
  while bi < self.buckets.length() || gi < self.gaps.length() {
    if gi < self.gaps.length() &&
      (
        bi == self.buckets.length() ||
        self.gaps[gi].first_index < self.buckets[bi].index
      ) {
      let gap = self.gaps[gi]
      let fields = [
        "empty-span",
        prefix,
        gap.first_index.to_string(),
        gap.last_index.to_string(),
        gap.selected_start_ms.to_string(),
        gap.selected_end_ms.to_string(),
        gap.empty_bucket_count.to_string(),
        "",
        "0",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
      ]
      out.write_string(fields.join(",") + "\n")
      gi += 1
    } else {
      let bucket = self.buckets[bi]
      let membership = bucket.source_sample_indices
        .map(i => i.to_string())
        .join(";")
      let timestamps = bucket.source_timestamps_ms
        .map(t => t.to_string())
        .join(";")
      for stats in bucket.statistics {
        let channel = "\"" + stats.channel.replace(old="\"", new="\"\"") + "\""
        let fields = [
          "observed",
          prefix,
          bucket.index.to_string(),
          bucket.index.to_string(),
          bucket.selected_start_ms.to_string(),
          bucket.selected_end_ms.to_string(),
          "0",
          channel,
          bucket.sample_count.to_string(),
          bucket.source_timestamps_ms[0].to_string(),
          bucket.source_timestamps_ms[bucket.sample_count - 1].to_string(),
          stats.first.to_string(),
          stats.last.to_string(),
          stats.minimum.to_string(),
          stats.maximum.to_string(),
          stats.sample_weighted_mean.to_string(),
          membership,
          timestamps,
        ]
        out.write_string(fields.join(",") + "\n")
      }
      bi += 1
    }
  }
  out.to_string()
}
