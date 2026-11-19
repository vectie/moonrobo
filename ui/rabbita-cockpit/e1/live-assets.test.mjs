import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { decodeMesh } from "./viewer.js";

const root = new URL("../public/e1/assets/", import.meta.url);
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
test("live model has all 23 joints and verifies every shipped geometry hash", async () => {
  const manifest = JSON.parse(await readFile(new URL("manifest.json", root)));
  assert.equal(new Set(manifest.robot.joints).size, 23);
  assert.equal(manifest.robot.default_q.length, 23);
  assert.equal(digest(await readFile(new URL("scene.xml", root))), manifest.scene_sha256);
  for (const mesh of Object.values(manifest.meshes)) {
    const bytes = await readFile(new URL(mesh.file, root));
    assert.equal(digest(bytes), mesh.sha256);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const geometry = decodeMesh(buffer);
    assert.ok(geometry.getAttribute("position").count >= 3);
    geometry.dispose();
  }
  assert.deepEqual(manifest.clips, []);
  assert.match(await readFile(new URL("NOETIX-LICENSE.txt", root), "utf8"), /Redistribution/);
});
