const files = new Map<string, { owner: string; file: string }>();
export function addVideoArtifact(owner: string, id: string, file: string) { files.set(id, { owner, file }); }
export function videoArtifact(id: string) { return files.get(id)?.file; }
export function removeVideoArtifact(owner: string, id?: string) {
  for (const [key, value] of files) if (value.owner === owner && (!id || id === key)) files.delete(key);
}
