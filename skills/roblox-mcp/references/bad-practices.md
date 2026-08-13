# Bad practices

Avoid these patterns when operating a Roblox client:

- Do not dump whole instances, large tables, complete game trees, or entire codebases through `get-data-by-code`.
- Do not start with broad descendant trees. Use summary mode, a shallow depth, and a tight root.
- Do not use semantic search when an exact identifier or regex is available.
- Do not read an entire large script when a focused line range answers the question.
- Do not use `execute` and `print` to recover data; return compact values through `get-data-by-code`.
- Do not loop over `getgc` when `filtergc` can express the same function or table criteria.
- Do not call `GetDescendants()` and manually filter every instance when a `QueryDescendants` selector can narrow the search.
- Do not assume fire-and-forget execution succeeded. Verify the effect with a small targeted read.
- Do not request remote arguments broadly. List names and counts first, then narrow.
- Do not block, ignore, unblock, or unignore a remote before listing and confirming its exact name and direction.
- Do not raise output limits before reducing the query scope.
- Do not mutate a live client when the user only requested inspection or diagnosis.

## Project-specific additions

No additional project-specific rules have been recorded yet. Add new rules here as direct “Do not …; instead …” guidance.
