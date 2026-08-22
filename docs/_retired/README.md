# `docs/_retired/` — documents that were retired, not deleted

Everything under this directory was measured dead and moved here by
`pl docs retire`. **Nothing here was removed from the repository.** If a
retirement turns out to have been a mistake, one command undoes it.

| Question | Command |
|---|---|
| What has been retired, when, why, and at what sha256? | `pl docs retired --list` |
| The same, machine-readable | `pl docs retired --json` |
| Including things already restored | `pl docs retired --all` |
| Put one back | `pl docs restore <original-path>` |
| Retire something else | `pl docs retire <path> --reason='…' --ref=ops#N` |

The index is [`MANIFEST.md`](MANIFEST.md). It is generated — do not hand-edit
it. Each row records the original path, the retirement date, the reason, the
issue ref, the sha256 of the content **at the moment of retirement**, where the
bytes now live, and the exact command that puts them back.

## Layout

```
docs/_retired/
├── MANIFEST.md                       the ledger (generated)
├── README.md                         this file
└── <YYYY-MM-DD>-<slug>/              one bucket per retirement
    ├── SHA256SUMS                    per-file hashes (directory retirements only)
    └── <the original relative path>  e.g. docs/reference/commands/backup.md
```

A retired file keeps its original relative path inside its bucket, so you can
find it by the path you remember it having.

## Why the bytes are never edited

`pl docs restore` proves a round trip by comparing the sha256 in the manifest
against the file on disk, and **refuses** when they differ. Editing an archived
document — even to fix a dead link — breaks that proof. That is deliberate: an
archive you are allowed to touch is not an archive.

For the same reason `pl doc-truth` skips `docs/_retired/*/*`. The dead links
inside these documents are not drift to be fixed; they are the evidence for why
the document was retired. `MANIFEST.md` and this `README.md` are **not** skipped
— an index whose own links rot is the exact failure this estate keeps finding.

## Retiring something

```bash
pl docs retire docs/some/stale-thing.md \
  --reason='measured: 3 of 40 cases; superseded by pl verify gates' \
  --ref=ops#123
```

`--reason` is mandatory. A retirement with no recorded reason is
indistinguishable from a mistake, and this directory exists precisely so that
mistakes stay recoverable. The verb also prints every tracked line still
pointing at the old path — fix those in the same merge request, or
`pl doc-truth` will fail on the markdown links among them.
