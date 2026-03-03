# Viewer Cluster Licence

Place your **viewer cluster** licence file here:

```
cluster/viewer/licence/Licence.lic
```

## Why a separate licence?

This licence is shared across all viewer nodes (node-1, node-2).
It should be configured for **unlimited viewer-only access** — no editor seats
needed. All viewer nodes mount the same licence file read-only.

The editor cluster has its own separate licence in `cluster/editor/licence/` which includes editor seats.

## Important

- This file is gitignored and will never be committed to the repository
- The file must be named exactly `Licence.lic`
- Without this file none of the viewer nodes will start
