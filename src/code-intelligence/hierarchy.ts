import type { HierarchyNode } from "./session.js";
import type { StoredScriptSource } from "../bridge/handlers/shared/script-source-store.js";

export interface DexRecord {
  Handle: string; ParentHandle?: string; DebugId?: string; Name: string; ClassName: string;
  Path?: string; DisplayTruncated?: boolean; ParentError?: string;
}

/** Dex is authoritative for identity; display paths never merge distinct instances. */
export class AnalysisHierarchy {
  private records = new Map<string, DexRecord>();
  observedAt?: string;
  complete = false;
  omitted = 0;
  connectorGeneration?: string;

  update(records: DexRecord[], complete: boolean, connectorGeneration?: string): void {
    if (this.connectorGeneration && connectorGeneration !== this.connectorGeneration) this.records.clear();
    this.connectorGeneration = connectorGeneration;
    const valid = records.filter(row => typeof row.Handle === "string" && typeof row.Name === "string" && typeof row.ClassName === "string"
      && !row.DisplayTruncated && !row.ParentError);
    this.omitted = records.length - valid.length;
    this.complete = complete && this.omitted === 0;
    if (this.complete) this.records.clear();
    for (const row of valid) {
      if (!this.records.has(row.Handle) && this.records.size >= 4000) { this.omitted++; this.complete = false; continue; }
      this.records.set(row.Handle, { ...row });
    }
    this.observedAt = new Date().toISOString();
  }

  build(scripts: StoredScriptSource[]): { tree: HierarchyNode; coverage: Record<string, unknown> } {
    const sources = new Map(scripts.map(script => [script.debugId, script]));
    const nodes = new Map<string, HierarchyNode>();
    let root: HierarchyNode = { Name: "game", ClassName: "DataModel", DebugId: "unobserved-root", ChildrenComplete: false, Children: [] };
    for (const row of this.records.values()) {
      const source = row.DebugId ? sources.get(row.DebugId) : undefined;
      const node: HierarchyNode = { Name: row.Name, ClassName: row.ClassName, DebugId: row.DebugId || row.Handle,
        ChildrenComplete: this.complete, Children: [], ...(source ? { sourceId: source.debugId } : {}) };
      nodes.set(row.Handle, node);
      if (row.ClassName === "DataModel") root = node;
    }
    let unlinked = 0;
    for (const row of this.records.values()) {
      const node = nodes.get(row.Handle)!;
      if (node === root) continue;
      const parent = row.ParentHandle ? nodes.get(row.ParentHandle) : undefined;
      if (!parent || parent === node) { unlinked++; continue; }
      parent.Children.push(node);
    }
    let ambiguous = 0; let linkedSources = 0; let cycleOrDepth = 0; let modulesWithoutSource = 0;
    const visited = new Set<HierarchyNode>();
    const sanitize = (node: HierarchyNode, depth: number): void => {
      visited.add(node);
      if (node.sourceId) linkedSources++;
      else if (node.ClassName === "ModuleScript") modulesWithoutSource++;
      const counts = new Map<string, number>();
      for (const child of node.Children) counts.set(child.Name, (counts.get(child.Name) ?? 0) + 1);
      node.Children = node.Children.filter(child => {
        if (counts.get(child.Name)! > 1) { ambiguous++; node.ChildrenComplete = false; return false; }
        if (visited.has(child) || depth >= 64) { cycleOrDepth++; node.ChildrenComplete = false; return false; }
        return true;
      }).sort((a, b) => a.Name.localeCompare(b.Name) || a.DebugId.localeCompare(b.DebugId));
      for (const child of node.Children) sanitize(child, depth + 1);
    };
    sanitize(root, 0);
    return { tree: root, coverage: { observedAt: this.observedAt, hierarchyComplete: this.complete && !unlinked && !ambiguous && !cycleOrDepth,
      retainedInstances: this.records.size, omittedInstances: this.omitted, unlinkedInstances: unlinked,
      ambiguousSiblingInstances: ambiguous, cycleOrDepthOmissions: cycleOrDepth, linkedSources,
      unlinkedSources: scripts.length - linkedSources, modulesWithoutSource,
      limitation: "Bounded non-atomic Dex observation. Partial refreshes retain unseen nodes; only complete scans establish removals. Duplicate sibling names are excluded from name-based resolution." } };
  }
}
