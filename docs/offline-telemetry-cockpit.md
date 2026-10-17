# Review a recorded telemetry projection in the cockpit

The cockpit's **Review historical telemetry** launcher opens an offline inspection
dialog. First use the existing native `telemetry_plot` CLI to turn a numeric CSV
into `moonrobo.telemetry-plot.v1` JSON; see [the producer guide](offline-telemetry-plot.md).
Then choose that local JSON file in the dialog. Files stay in browser memory;
this feature has no network, hardware, persistence or evidence-acceptance path.
It does not parse raw CSV or dataset files in the browser.

Select a primary channel, enter inclusive absolute recorded start/end milliseconds, and
apply the window. **Full projection** restores the observations present in the
loaded file, not omitted source rows. Empty windows are explicitly empty and
disable navigation. Invalid window text clears the plotted selection. Channel
selection changes the visible channel without changing the time window.

Choose a second channel in **Compare channel** to inspect two stacked plots.
Both use the same observations, horizontal recorded-time scale and gold cursor.
Their vertical ranges and units stay separate: similar shapes do not establish
correlation or interchangeable quantities. The detail area shows both exact
values at the selected observation. Amber gaps appear in both plots; exact seek
inside a gap reports no observation and keeps the prior cursor.

Comparison starts at **None (single channel)** and resets when opening another
file. Selecting the compared channel as primary clears comparison, preventing
duplicate plots; choose another comparison explicitly. A one-channel projection
disables comparison. Window changes, full reset and previous/next affect both
plots together. Empty windows clear both plots. Narrow displays can scroll the
plot area horizontally; plots remain stacked with independent labeled units.

Previous/next, the observation-position slider, and **Find exact observation**
select actual observations. Exact search never snaps to or interpolates a nearby
timestamp. The detail area retains exact timestamp strings, source sample index,
original segment, connection flag, value and unit. Timestamps are validated as
nonnegative Int64 strings and compared/subtracted using BigInt, including above
2^53. Display coordinates alone use floating point after timestamp subtraction.

## Measure recorded before/after change

Choose an observation and press **Pin current observation as reference**. Navigate
to another recorded observation using previous/next, the slider or exact seek.
The purple dashed reference line stays fixed while the gold current line moves
on both selected channel plots. The measurement panel reports both exact
timestamps/source positions, signed elapsed milliseconds (current minus
reference), and each visible channel's reference value, current value and signed
endpoint difference. Re-pin to replace the reference, or use **Clear reference**.
Channel selection preserves the reference; applying any window, Full projection,
another file or closing the dialog clears it. Empty windows disable pinning.

Elapsed milliseconds use exact BigInt subtraction, including reverse navigation.
Channel differences use floating-point arithmetic and may display rounding;
overflow is reported as outside representable range. The number of unobserved
gaps crossed is shown in either direction. Endpoint differences do not establish
continuous change across those gaps, rates, correlation or physical outcomes.
This is an in-memory exploration aid, not a saved annotation or accepted evidence.

Dots are observations, straight lines are visual guides, and amber bands denote
gaps identified by the projection's max-gap policy. There is no resampling,
interpolation or inference across gaps. The first visible observation is never
connected to an observation outside the view. Each channel uses its own visible
range; constant channels and single observations are centered. Long spans and
dense points may overlap visually; the exact detail/navigation path remains.

The loader accepts up to 2 MiB, 16 channels and 10,000 observations, with labels
up to 1,024 UTF-16 code units. Generate a narrower CLI projection if necessary.
It checks format/timebase, bounds, finite channel values and summaries, strict
timestamp order, contiguous source positions, gap topology and counts. It does
not authenticate provenance or establish immutable recording identity. Labels
are rendered as text or escaped SVG text; extra JSON fields are not rendered.
New selections and dialog closure invalidate pending reads. Closing forgets the
loaded projection and allows the same file to be selected again.

This is the existing scalar telemetry projection contract, not the proposed
`moonrobo.replay.v1` joint/trajectory protocol. There is no robot model playback,
receipt linkage, incident adjudication, readiness assessment, physical outcome
claim or authorizing control. MR-W04 step 2 gains historical timestamp inspection
only. MR-W06 physical reconciliation and full MR-W04 acceptance remain unproven.

## Validation scope

Run `node --test ui/rabbita-cockpit/telemetry-review.test.mjs` from the repository.
The tests mount production handlers on small DOM doubles and load the retained
native CLI's actual JSON fixture. They are not graphical browser validation.
`node --test ui/rabbita-cockpit/*.test.mjs` includes adjacent cockpit regressions;
its optional R37 native HTTP integration remains skipped without its host setup.
No new native sources, native build, complete cockpit bundle or browser test is
part of this slice.
