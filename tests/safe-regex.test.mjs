import assert from "node:assert/strict";
import test from "node:test";

import {
  compileSafeSearchRegExp,
  MAX_SEARCH_PATTERN_CHARS,
} from "../dist/tools/safe-regex.js";

test("search regex rejects nested repetition patterns", () => {
  assert.throws(
    () => compileSafeSearchRegExp("(a+)+$", false, true),
    /excessive backtracking/
  );
});

test("literal search safely accepts regex metacharacters", () => {
  const regex = compileSafeSearchRegExp("(a+)+$", true, true);
  assert.equal(regex.test("prefix (a+)+$ suffix"), true);
});

test("search patterns have a hard length limit", () => {
  assert.throws(
    () => compileSafeSearchRegExp("a".repeat(MAX_SEARCH_PATTERN_CHARS + 1), false, true),
    /exceeds/
  );
});
