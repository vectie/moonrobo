import test from "node:test";
import assert from "node:assert/strict";
import { TRANSFER_LAST, elbowTransferPair } from "./elbow-transfer.js";
test("elbow-only preview uses the commissioning endpoints and smooth exact return", () => {
  const args = [-1.9, -2.4, -1.4477981791899937*180/Math.PI, -.5434064639344343*180/Math.PI];
  assert.deepEqual(elbowTransferPair(0, ...args), args.slice(0,2));
  assert.deepEqual(elbowTransferPair(3000, ...args), args.slice(2));
  assert.deepEqual(elbowTransferPair(3100, ...args), args.slice(2));
  assert.deepEqual(elbowTransferPair(TRANSFER_LAST, ...args), args.slice(0,2));
  let previous = args.slice(0,2);
  for (let i=1;i<=TRANSFER_LAST;i++) {
    const actual = elbowTransferPair(i, ...args);
    actual.forEach((value,j) => {
      assert.ok(value >= Math.min(args[j],args[j+2])-1e-9 && value <= Math.max(args[j],args[j+2])+1e-9);
      assert.ok(Math.abs(value-previous[j]) <= Math.abs(args[j+2]-args[j])*1.875/60*.02+1e-9);
    });
    previous=actual;
  }
});
