///|
/// Standalone spectrum SVG from an unmodified spectrum_csv result. Stems are
/// discrete DFT bins, with amplitude and frequency tooltips. No diagnosis,
/// spectral interpolation, external resources, or executable content is added.
pub fn TelemetrySpectrum::to_svg(self : TelemetrySpectrum) -> String {
  let out = StringBuilder()
  let mut maximum = 0.0
  for bin in self.bins {
    maximum = maximum.max(bin.amplitude)
  }
  let label = plot_xml_label(self.channel + " [" + self.unit_label + "]")
  let short_label = plot_short_label(
    self.channel + " [" + self.unit_label + "]",
  )
  let first = self.samples[0].timestamp_ms
  let last = self.samples[self.samples.length() - 1].timestamp_ms
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1100 600\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Recorded signal amplitude spectrum</title><desc id=\"desc\">One-sided discrete Fourier transform. Rectangular window. Interior bins doubled; DC and even-length Nyquist undoubled. Bin spacing is not a physical resolving-power guarantee. No diagnosis or resampling.</desc>\n",
  )
  out.write_string(
    "<rect width=\"1100\" height=\"600\" fill=\"#0f172a\"/><g font-family=\"sans-serif\" fill=\"#e2e8f0\">\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"36\" font-size=\"23\">Recorded signal amplitude spectrum</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"66\" font-size=\"16\"><title>\{label}</title>\{short_label}</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"91\" font-size=\"13\">N=\{self.samples.length()} · interval=\{self.sample_interval_ms} ms · Fs=\{self.sample_rate_hz} Hz · bin spacing=\{self.frequency_resolution_hz} Hz</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"115\" font-size=\"13\">Nyquist=\{self.nyquist_hz} Hz · rectangular window · demean=\{self.demean}</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"139\" font-size=\"12\">Original timestamps: \{first} through \{last} ms</text>\n",
  )
  out.write_string(
    "<rect x=\"160\" y=\"175\" width=\"880\" height=\"290\" fill=\"#172033\" stroke=\"#64748b\"/>\n",
  )
  out.write_string(
    "<text x=\"150\" y=\"184\" text-anchor=\"end\" font-size=\"12\">\{maximum}</text><text x=\"150\" y=\"465\" text-anchor=\"end\" font-size=\"12\">0</text>\n",
  )
  for bin in self.bins {
    let x = 160.0 + bin.frequency_hz / self.nyquist_hz * 880.0
    let y = if maximum == 0.0 {
      465.0
    } else {
      465.0 - bin.amplitude / maximum * 290.0
    }
    out.write_string(
      "<g class=\"spectrum-bin\" data-bin=\"\{bin.index}\"><title>bin=\{bin.index}; frequency=\{bin.frequency_hz} Hz; amplitude=\{bin.amplitude} \{plot_xml_label(self.unit_label)}; Nyquist=\{bin.is_nyquist}</title><path d=\"M \{x} 465 V \{y}\" stroke=\"#38bdf8\"/><circle cx=\"\{x}\" cy=\"\{y}\" r=\"3\" fill=\"#7dd3fc\"/></g>\n",
    )
  }
  out.write_string(
    "<text x=\"160\" y=\"487\" font-size=\"12\">0 Hz</text><text x=\"1040\" y=\"487\" text-anchor=\"end\" font-size=\"12\">\{self.nyquist_hz} Hz</text>\n",
  )
  out.write_string(
    "<text x=\"600\" y=\"511\" text-anchor=\"middle\" font-size=\"14\">Frequency (Hz)</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"543\" font-size=\"12\">Peak amplitude: abs(DFT)/N; interior bins x2. DC and even-N Nyquist x1. Not RMS or PSD.</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"567\" font-size=\"12\">Finite recorded window: leakage and aliasing may exist. Units are supplied labels. No physical diagnosis.</text>\n",
  )
  out.write_string("</g></svg>\n")
  out.to_string()
}
