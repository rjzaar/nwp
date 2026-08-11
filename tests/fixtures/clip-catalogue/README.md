# `clip-catalogue` fixtures — SYNTHETIC, no corpus content

These drive `tests/unit/test-clips-integrity.bats`, which proves that every
check in `pl clips verify` can go RED and can go GREEN.

**Nothing here comes from the real corpus.** The DIR/SD corpus is
`derivative-cleared-pending` and local-only; this repository is publicly
mirrored, so the fixtures are invented prose about lantern keepers and
cartographers, with invented eleven-character video ids (`vidSAME00001` …) that
cannot collide with a real YouTube id.

| directory | what it is |
|---|---|
| `clean/` | every window exists, plays, and is honestly labelled → exit 0 |
| `defective/` | ONE learning point per defect class → exit 2, one finding each |

The two variants share identical `transcripts/`, `video-transcripts/` and
`videos.json`, so the only thing that differs between a red run and a green run
is the catalogue itself.

## The synthetic media

`transcripts/ep_0001.json` is the PODCAST side: 76 invented words at 8 s each,
so episode 1 is exactly **608 s (10:08)** long, with word-level timings in the
shape faster-whisper emits.

`video-transcripts/` is the YOUTUBE side. Each file is constructed to land in a
specific band of the linkage oracle, which decides whether a `youtube_id`
really is the episode it claims by counting **verbatim 8-grams shared between
the two transcripts** — evidence about the audio, which no title matcher can
manufacture:

| video id | duration | relationship to episode 1 | oracle verdict |
|---|---|---|---|
| `vidSAME00001` | 608 s | byte-identical timeline | corroborated, offset 0 |
| `vidLONG00001` | 1200 s | same recording, long upload | corroborated, offset 0 |
| `vidSHORT0001` | 20 s | same recording, short cut | corroborated (trips D2) |
| `vidOFFSET001` | 708 s | same words, timeline shifted +100 s | corroborated, offset +100 |
| `vidOTHER0001` | 608 s | a completely different script | refuted |
| `vidPARTIAL01` | 608 s | ~8 % shared | **unproven** — deliberately between the bands |

`vidPARTIAL01` is the important one. It exists so that the "neither proven nor
disproven" path is exercised by a test rather than assumed: a check that can
only say yes or no would report it as one or the other, and that is exactly the
swallowed-verdict shape this estate keeps finding.

## Regenerating

The JSON is generated, not hand-written. If you change the vocabulary or the
timing step, regenerate all of it together — the numbers in
`defective/catalog/Z1.yaml`'s header comment and in the bats assertions are
derived from it.
