import assert from "node:assert/strict";
import test from "node:test";
import { selectUpdatePackageRunner } from "../scripts/update-runner.mjs";

test("update respects the declared manager and avoids incompatible Corepack fallback", () => {
  const onlyPnpm = name => name === "pnpm";
  assert.equal(selectUpdatePackageRunner({ packageManager: "bun@1.3.13" }, onlyPnpm), "npm");
  assert.equal(selectUpdatePackageRunner({ packageManager: "pnpm@10.0.0" }, onlyPnpm), "pnpm");
  assert.equal(selectUpdatePackageRunner({ packageManager: "npm@11.0.0" }, onlyPnpm), "npm");
  assert.equal(selectUpdatePackageRunner({ packageManager: "bun@1.3.13" }, () => true), "bun");
  assert.equal(selectUpdatePackageRunner({}, onlyPnpm), "pnpm");
});
