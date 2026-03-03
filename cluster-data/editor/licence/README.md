# Editor Cluster Licence

Place your **editor cluster** licence file here:

```
cluster/editor/licence/Licence.lic
```

## Why a separate licence?

This cluster runs the **editor node** — the single Omniscope instance that
has full read/write access and can execute workflows. Its licence must include
**editor seats** (i.e. users with editor-level permissions).

The viewer cluster has its own separate licence in `cluster/viewer/licence/` which is configured for unlimited viewer-only access.

## Important

- This file is gitignored and will never be committed to the repository
- The file must be named exactly `Licence.lic`
- Without this file the editor node will refuse to start
