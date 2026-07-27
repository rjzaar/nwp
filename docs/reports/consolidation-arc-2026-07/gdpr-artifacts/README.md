# Art.9 depthcontent evidence — what is preserved here, and what is not

**Recoverable artifact:** `ssc-depthcontent-art9-20260726.patch` (338 KB).
It reconstructs `mod/depthcontent` exactly as of commit
`bcc7f496c3d5daa9d9878366317516750534fec3` ("gdpr(depthcontent): track the
vendored plugin + Art.9 fixes"), all 40 files including the three binaries.

It is generated **against the empty tree**, not against the commit's parent, so
it depends on nothing at all:

```
$ mkdir restore && cd restore
$ git apply --binary .../ssc-depthcontent-art9-20260726.patch
$ find mod/depthcontent -type f | wc -l
40
```

That was not a free choice. The obvious artifact — `git show bcc7f496` — is a
diff against the parent commit, and 1 of the 38 changed files (`lib.php`) is a
*modification*, so that form silently needs a pre-image the reader may not have.
It is also not applicable at all as plain `git show` output: three files under
`amd/build/` and `pix/icon.png` are binary, and without `--binary --full-index`
git refuses them ("cannot apply binary patch … without full index line"). Both
defects were found by trying to apply it, which is the only way they show up.

Verified, not asserted: applying this patch to an empty directory and diffing
the result against `git archive bcc7f496 mod/depthcontent` gives **40 files each
and zero differences**.

The operator's authorship line is deliberately replaced with a placeholder —
`nwp/nwp` is the public-release track and `operator-personal-email` is a leakage
rule. The identity is in the canonical repo.

## The bundle that used to sit here was a brick — it was removed

`ssc-depthcontent-art9-20260726.bundle` was committed as the durable copy of the
same work by the *rescue-untracked-deliverables* pass, which committed a set of
untracked files wholesale without running `pl snapshot audit` over them. It was
created with a revision range, so it was a **thin** bundle: it carried the
objects since an earlier commit and recorded that commit as a prerequisite it
did not contain.

Reproduced in an empty repository:

```
$ git bundle verify ssc-depthcontent-art9-20260726.bundle
error: Repository lacks these prerequisite commits:
error: 346025ce13dc2151c0a6d084c1b24c19b713aa91
```

`346025ce…` is the ops#118 Moodle-side Art.9 consent-gate commit. It is **not**
in this repository, and it is **not** in the canonical plugin repo either —
checked, not assumed: `GET /projects/33/repository/commits/346025ce…` → 404, and
the same for the bundle head `bcc7f49…`. The content was re-committed onto
`nwp/ss-moodle-plugins` under different shas, so the bundle's prerequisite is
reachable from exactly one place on earth: the `sites/ssc/dev` working copy on
the authoring laptop. Outside it, the bundle restores **nothing**.

This is the second instance of the same defect in this arc. The first is
documented at `../ssc-118-artifact/README.md`, and the resolution here is
deliberately the same one, for the same reasons.

### Why deleted rather than declared

The alternative was a `.prereq.json` naming a source to fetch `346025ce…` from.
There is no such source — the commit is not published anywhere. Writing a
`--prereq-source` URL that does not contain the object would have made
`pl snapshot audit` green while leaving the artifact exactly as unrestorable as
it was, which is the original defect with a certificate stapled to it.

### Nothing was lost — verified, not asserted

The Art.9 content is preserved in the canonical repo. Checked by clone and diff,
not by reading a claim:

```
$ git clone --depth 1 --branch gdpr/art9-depthcontent-fixes \
      git@git.nwpcode.org:nwp/ss-moodle-plugins.git
$ git archive bcc7f496 mod/depthcontent | tar -x -C bundleside
$ diff -rq plugcheck/mod/depthcontent bundleside/mod/depthcontent
   → no differences, 40 files each
```

Spot-check of the file the evidence is actually about,
`mod/depthcontent/classes/privacy/provider.php`: blob
`020adf0afd7daa38b835f619bfe344247ba79434` on both sides.

And the bundle blob itself remains in this repository's history forever:

```
git show e82c87340a090761a0ca26f5db53ca868772c846 > ssc-depthcontent-art9-20260726.bundle
```

## Checking this before you commit an artifact

| Need | Command |
|---|---|
| Make a bundle that is provably restorable | `pl snapshot bundle <repo> --out=<file>` |
| Check one | `pl snapshot verify <bundle>` |
| Check every bundle in the tree (the gate) | `pl snapshot audit` |
