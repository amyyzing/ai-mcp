import safeRegex from "safe-regex2";

export const MAX_SEARCH_PATTERN_CHARS = 1000;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function compileSafeSearchRegExp(
  query: string,
  literal: boolean,
  caseSensitive: boolean
): RegExp {
  if (query.length === 0) throw new Error("Pattern cannot be empty.");
  if (query.length > MAX_SEARCH_PATTERN_CHARS) {
    throw new Error(`Pattern exceeds ${MAX_SEARCH_PATTERN_CHARS} characters.`);
  }

  const pattern = literal ? escapeRegExp(query) : query;
  const regex = new RegExp(pattern, caseSensitive ? "" : "i");
  if (!literal && !safeRegex(regex)) {
    throw new Error(
      "Pattern may cause excessive backtracking. Simplify it or set literal=true."
    );
  }
  return regex;
}
