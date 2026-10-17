///|
fn response_csv_label(text : String) -> String {
  let out = StringBuilder()
  out.write_string("\"")
  for c in text {
    if c == '"' {
      out.write_string("\"\"")
    } else {
      out.write_char(c)
    }
  }
  out.write_string("\"")
  out.to_string()
}

///|
fn response_time(value : Int64?) -> String {
  match value {
    Some(value) => value.to_string()
    None => ""
  }
}

///|
fn response_index(value : Int?) -> String {
  match value {
    Some(value) => value.to_string()
    None => ""
  }
}

///|
/// Long-form review table retaining missing cells and interpolation brackets.
/// This is not raw telemetry. Retain the JSON report and original recording.
pub fn EventResponses::to_csv(self : EventResponses) -> String {
  let out = StringBuilder()
  out.write_string(
    "episode_index,anchor_timestamp_ms,offset_ms,timestamp_ms,status,channel,unit,value,source_segment,left_sample_index,right_sample_index,left_timestamp_ms,right_timestamp_ms,right_weight\n",
  )
  for trial in self.trials {
    for point in trial.points {
      for ci, channel in self.channels {
        let value = match point.values {
          Some(values) => values[ci].to_string()
          None => ""
        }
        let weight = match point.right_weight {
          Some(value) => value.to_string()
          None => ""
        }
        out.write_string(
          "\{trial.episode_index},\{trial.anchor.first_timestamp_ms},\{point.offset_ms},\{response_time(point.timestamp_ms)},\{point.status},\{response_csv_label(channel)},\{response_csv_label(self.unit_labels[ci])},\{value},\{response_index(point.source_segment)},\{response_index(point.left_sample_index)},\{response_index(point.right_sample_index)},\{response_time(point.left_timestamp_ms)},\{response_time(point.right_timestamp_ms)},\{weight}\n",
        )
      }
    }
  }
  out.to_string()
}

///|
/// One descriptive summary per offset/channel. Missing support is never zero.
pub fn EventResponses::summary_csv(self : EventResponses) -> String {
  let out = StringBuilder()
  out.write_string(
    "offset_ms,channel,unit,supported_count,missing_count,exact_count,interpolated_count,mean,minimum,maximum,supported_episode_indices\n",
  )
  for summary in self.summaries {
    for ci, channel in self.channels {
      let mean = match summary.mean {
        Some(values) => values[ci].to_string()
        None => ""
      }
      let minimum = match summary.minimum {
        Some(values) => values[ci].to_string()
        None => ""
      }
      let maximum = match summary.maximum {
        Some(values) => values[ci].to_string()
        None => ""
      }
      let supported = summary.supported_episode_indices
        .map(i => i.to_string())
        .join(";")
      out.write_string(
        "\{summary.offset_ms},\{response_csv_label(channel)},\{response_csv_label(self.unit_labels[ci])},\{summary.supported_episode_indices.length()},\{summary.missing_count},\{summary.exact_count},\{summary.interpolated_count},\{mean},\{minimum},\{maximum},\{response_csv_label(supported)}\n",
      )
    }
  }
  out.to_string()
}

///|
/// Export every ORIGINAL observation and channel in one selected event window.
/// Times stay absolute and gaps stay present. No grid/interpolated/mean values
/// enter this numeric CSV. Reopen with the existing explorer/plot tools and use
/// an explicit gap limit; retain this report for selection and source anchors.
pub fn EventResponses::clip_csv(
  self : EventResponses,
  episode_index : Int,
) -> Result[String, String] {
  let mut selected : EventResponseTrial? = None
  for trial in self.trials {
    if trial.episode_index == episode_index {
      selected = Some(trial)
    }
  }
  let trial = match selected {
    Some(value) => value
    None => return Err("clip episode must be in the explicit selected episodes")
  }
  let out = StringBuilder()
  out.write_string("timestamp_ms," + self.source.channels.join(",") + "\n")
  for sample in self.source.samples {
    let offset = sample.timestamp_ms - trial.anchor.first_timestamp_ms
    if offset >= -self.before_ms && offset <= self.after_ms {
      out.write_string(sample.timestamp_ms.to_string())
      for value in sample.values {
        out.write_string("," + value.to_string())
      }
      out.write_string("\n")
    }
  }
  Ok(out.to_string())
}

///|
/// Standalone visual overlay; gray traces break at missing points or source
/// segment changes. Blue mean dots are intentionally unconnected because their
/// supporting episode sets can differ. Error bars are min/max, not uncertainty.
pub fn EventResponses::to_svg(self : EventResponses) -> Result[String, String] {
  if self.channels.length() > 8 || self.summaries.length() > 201 {
    return Err(
      "SVG supports at most 8 channels and 201 offsets; use JSON/CSV or a coarser grid",
    )
  }
  let out = StringBuilder()
  let height = 170 + self.channels.length() * 240
  let span = self.before_ms + self.after_ms
  let xs = self.summaries.map(s => {
    if span == 0L {
      580.0
    } else {
      150.0 +
      (s.offset_ms + self.before_ms).to_double() / span.to_double() * 860.0
    }
  })
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1080 \{height}\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Repeated recorded-event responses</title><desc id=\"desc\">Gray: selected episode samples and bounded linear estimates. Blue: equal-supported-episode mean dots and min/max bars, not confidence intervals. Missing points are excluded with support counts. Recorded data only.</desc>\n",
  )
  out.write_string(
    "<rect width=\"1080\" height=\"\{height}\" fill=\"#0f172a\"/><g font-family=\"sans-serif\" fill=\"#e2e8f0\">\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"34\" font-size=\"23\">Repeated recorded-event responses</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"60\" font-size=\"14\">\{self.trials.length()} selected episodes · \{self.overlaps.length()} overlapping window pairs · interpolation gap limit \{self.max_gap_ms} ms</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"83\" font-size=\"13\">Gray: episode traces. Blue: mean and min/max. Labels show support / selected. Independent Y scales.</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"104\" font-size=\"13\">Zero = first matching recorded sample. No physical event, safety, independence or causality claim.</text>\n",
  )
  for ci, channel in self.channels {
    let all : Array[Double] = []
    for trial in self.trials {
      for point in trial.points {
        if point.values is Some(values) {
          all.push(values[ci])
        }
      }
    }
    // Every selected episode has an exact anchor on the zero-containing grid.
    let mut minimum = all[0]
    let mut maximum = all[0]
    for value in all {
      minimum = minimum.min(value)
      maximum = maximum.max(value)
    }
    let top = 160 + ci * 240
    let bottom = top + 140
    let label = plot_short_label(channel + " [" + self.unit_labels[ci] + "]")
    out.write_string(
      "<g data-channel-index=\"\{ci}\"><text x=\"30\" y=\"\{top - 16}\" font-size=\"16\">\{label}</text>\n",
    )
    out.write_string(
      "<rect x=\"150\" y=\"\{top}\" width=\"860\" height=\"140\" fill=\"#172033\" stroke=\"#64748b\"/><text x=\"10\" y=\"\{top + 13}\" font-size=\"11\">\{maximum}</text><text x=\"10\" y=\"\{bottom}\" font-size=\"11\">\{minimum}</text>\n",
    )
    for trial in self.trials {
      for pi, point in trial.points {
        if point.values is Some(values) {
          let y = bottom.to_double() -
            plot_y_fraction(values[ci], minimum, maximum) * 140.0
          if pi > 0 &&
            trial.points[pi - 1].source_segment == point.source_segment &&
            trial.points[pi - 1].values is Some(previous) {
            let py = bottom.to_double() -
              plot_y_fraction(previous[ci], minimum, maximum) * 140.0
            out.write_string(
              "<line data-episode=\"\{trial.episode_index}\" x1=\"\{xs[pi - 1]}\" y1=\"\{py}\" x2=\"\{xs[pi]}\" y2=\"\{y}\" stroke=\"#94a3b8\" opacity=\"0.6\"/>\n",
            )
          }
          out.write_string(
            "<circle cx=\"\{xs[pi]}\" cy=\"\{y}\" r=\"2.5\" fill=\"#cbd5e1\"><title>episode \{trial.episode_index}; offset \{point.offset_ms} ms; \{point.status}; value \{values[ci]}</title></circle>\n",
          )
        }
      }
    }
    for si, summary in self.summaries {
      if summary.mean is Some(mean) &&
        summary.minimum is Some(mins) &&
        summary.maximum is Some(maxs) {
        let y = bottom.to_double() -
          plot_y_fraction(mean[ci], minimum, maximum) * 140.0
        let lo = bottom.to_double() -
          plot_y_fraction(mins[ci], minimum, maximum) * 140.0
        let hi = bottom.to_double() -
          plot_y_fraction(maxs[ci], minimum, maximum) * 140.0
        out.write_string(
          "<line x1=\"\{xs[si]}\" x2=\"\{xs[si]}\" y1=\"\{lo}\" y2=\"\{hi}\" stroke=\"#38bdf8\" stroke-width=\"2\"/><circle cx=\"\{xs[si]}\" cy=\"\{y}\" r=\"4\" fill=\"#38bdf8\"><title>offset \{summary.offset_ms} ms; mean \{mean[ci]}; min \{mins[ci]}; max \{maxs[ci]}; support \{summary.supported_episode_indices.length()}/\{self.trials.length()}</title></circle>\n",
        )
      }
      if self.summaries.length() <= 15 ||
        si == 0 ||
        si == self.summaries.length() - 1 ||
        summary.offset_ms == 0L {
        out.write_string(
          "<text x=\"\{xs[si]}\" y=\"\{bottom + 19}\" text-anchor=\"middle\" font-size=\"11\">\{summary.offset_ms} ms</text><text x=\"\{xs[si]}\" y=\"\{bottom + 36}\" text-anchor=\"middle\" font-size=\"11\">\{summary.supported_episode_indices.length()}/\{self.trials.length()}</text>\n",
        )
      }
    }
    out.write_string("</g>\n")
  }
  out.write_string("</g></svg>\n")
  Ok(out.to_string())
}
