# Modern runtime patterns

Use these patterns when specialized MCP inspection tools cannot answer the question directly.

## Return data instead of printing it

Use `get-data-by-code` for read-only custom probes and whenever the result matters to the task:

```luau
local player = game:GetService("Players").LocalPlayer

return {
    Name = player.Name,
    UserId = player.UserId,
}
```

Return raw strings, numbers, booleans, arrays, and small dictionaries. The connector serializes them. Do not call `HttpService:JSONEncode`, return whole instances, or return large/unbounded tables.

Use `execute` or `execute-file` only when the primary purpose is a side effect:

```luau
workspace.CurrentCamera.FieldOfView = 90
```

Execution now reports whether the top-level chunk completed or failed, but that acknowledgement is not proof that the intended in-game state changed. Follow it with a specialized inspection tool or a small `get-data-by-code` probe. A console read is appropriate only when logs themselves are the evidence.

## Reuse GC objects through runtime handles

Use `search-gc` when one compact first match answers the question. For investigation across several calls, start with `executor-capabilities`, create one bounded `gc-snapshot`, then page it with `gc-query`. Query results contain generation-scoped `rh_...` handles that can be passed to `runtime-inspect`, `runtime-read`, `runtime-write`, `runtime-call`, or `runtime-references` without trying to serialize the underlying closure/table/thread.

Keep the snapshot scan and query filters as narrow as the task allows. Treat `staleHandles` as a normal indication that a weakly indexed object was collected, not as an empty result or transport failure. Use `gc-diff` only on snapshots from the same live connector generation, and call `runtime-release` for pinned handles that are no longer useful.

Use `runtime-handles` when diagnosing retained-object growth. Table pages are explicitly unstable if the live table mutates between calls, so verify important fields with a focused `runtime-read` before changing them.

## Filter garbage-collected values with `filtergc`

Prefer the MCP `search-gc` tool because it bounds criteria, returns only the first match, caps table summaries, and bounds compatibility iteration. The executor may still allocate or traverse its own full GC snapshot internally. When a predicate cannot be expressed by that tool, prefer raw `filtergc` over a `getgc` loop and provide every known criterion:

```luau
local target = filtergc("function", {
    Name = "FireWeapon",
    Constants = { "Ammo", "Reload" },
}, true)

return target ~= nil
```

Function filters support `Name`, `IgnoreExecutor`, `Hash`, `Constants`, and `Upvalues`. Table filters support `Keys`, `Values`, `KeyValuePairs`, and `Metatable`. Pass `true` as the third argument only when the first match is sufficient; otherwise handle the returned match array and return only a compact summary.

By default, function filtering ignores executor-created functions. Set `IgnoreExecutor = false` only when executor-created closures are intentionally in scope.

Fall back to `getgc` only when `filtergc` is unavailable in the active executor or the required predicate cannot be expressed by its filters. Keep the fallback type-gated, bounded where possible, and return only the matches needed for the task.

Authoritative API reference: [sUNC `filtergc` documentation](https://docs.sunc.su/Environment/filtergc/).

## Filter instances with `QueryDescendants`

Prefer the MCP `search-instances` tool because it already runs `QueryDescendants` against a chosen root and limits the response. Use selectors to push filtering into the query:

```text
Part.Tagged[Anchored = false]
Model > Humanoid
#HumanoidRootPart
RemoteEvent, RemoteFunction
```

In custom Luau, keep the root as narrow as possible:

```luau
local enemies = workspace:QueryDescendants("Model.Enemy:has(Humanoid)")
local paths = {}

for index, enemy in enemies do
    if index > 20 then
        break
    end
    paths[index] = enemy:GetFullName()
end

return paths
```

Selectors can express class, tag, name, property, and attribute criteria; chained criteria; `>`, `>>`, and comma combinators; and `:not()` or `:has()`.

Use direct indexing or `FindFirstChild` for one already-known path. Use a manual `GetDescendants()` pass only when the predicate depends on logic that selectors cannot express. Even then, first narrow the root or candidate set with `QueryDescendants`.
