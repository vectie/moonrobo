import test from "node:test";
import assert from "node:assert/strict";
import { parseGestureReplay, replayFrameAt, replayCurves } from "./gesture-replay.js";

const names = Array.from({ length: 23 }, (_, i) => `joint-${i}`);
function fixture() {
  const pose = angle => [0, 0, .85, 0, 0, 0, 1, ...Array(23).fill(angle)];
  return { format: "moonrobo.e1-gesture-replay.v1", published: false,
    step_ms: 20, reference_id: "typing", names: names.slice(), frames: [
      { at_ms: 0, reference: pose(.1), actor: pose(.5), measured: pose(.02) },
      { at_ms: 40, reference: pose(.2), actor: pose(.7), measured: pose(.03) },
    ] };
}

test("replay retains separate reference, unsent actor target and measured channels", () => {
  const tape = parseGestureReplay(fixture(), names);
  const [reference, actor] = replayCurves(tape, 5);
  assert.ok(Math.abs(reference[0] - .1 * 180 / Math.PI) < 1e-10);
  assert.ok(Math.abs(actor[1] - .7 * 180 / Math.PI) < 1e-10);
  assert.notDeepEqual(reference, actor);
  assert.equal(tape.frames[0].measured[12], .02);
});

test("playback uses recorded sample times without inventing a missing frame", () => {
  const tape = parseGestureReplay(fixture(), names);
  assert.equal(replayFrameAt(tape, -1), 0);
  assert.equal(replayFrameAt(tape, 20), 0);
  assert.equal(replayFrameAt(tape, 40), 1);
  assert.equal(replayFrameAt(tape, 1000), 1);
});

test("replay rejects changed joint order, invalid data and contradictory sent metadata", () => {
  const changed = fixture(); changed.names.reverse();
  assert.throws(() => parseGestureReplay(changed, names));
  const invalid = fixture(); invalid.frames[0].actor[8] = NaN;
  assert.throws(() => parseGestureReplay(invalid, names));
  const repeated = fixture(); repeated.frames[1].at_ms = 0;
  assert.throws(() => parseGestureReplay(repeated, names));
  const sent = fixture(); sent.published = true;
  assert.throws(() => parseGestureReplay(sent, names));
});
