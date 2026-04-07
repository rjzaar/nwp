# Proposal: Transcript-Based Programmatic Video Editing on Ubuntu

## Overview

This proposal outlines an approach to building a programmatic video editing pipeline on Ubuntu that uses transcripts to identify, extract, and assemble video segments into new compositions — without the need for a traditional GUI video editor.

The core idea is simple: treat video editing as a **data problem**. Given a source video and its transcript with timecodes, a script can search for relevant content, extract the corresponding clips, and concatenate them into a polished output — all from the command line or a Python script.

## Problem

Manual video editing is time-consuming, especially when the task is essentially **content selection** — sifting through hours of footage to find and assemble the right moments. This is particularly true for:

- Compiling highlight reels from long-form recordings (retreats, workshops, talks)
- Extracting thematic segments from interviews or panel discussions
- Producing short-form content from long-form source material
- Creating tailored versions of existing content for different audiences

These tasks don't require creative compositing or complex effects — they require **finding the right words and cutting accordingly**.

## Proposed Architecture

The pipeline has four stages:

### 1. Transcription and Alignment

Generate a word-level timestamped transcript from the source video.

**Primary tool:** OpenAI Whisper (open-source, runs locally on Ubuntu)

Whisper takes an audio/video file as input and produces a transcript with per-word or per-segment timestamps. Output can be formatted as SRT, VTT, or JSON with precise start/end times.

If a transcript already exists (e.g. from a human transcriber), **aeneas** or **gentle** can force-align the known text against the audio to recover timecodes.

### 2. Segment Selection

Identify which portions of the transcript correspond to the desired output.

This can be done via:

- **Keyword or phrase matching** — search the transcript for specific terms or topics
- **Semantic search** — use embeddings to find segments that are *about* a topic, even if they don't use the exact words
- **Manual curation** — a human reviews the transcript and marks the segments to include
- **LLM-assisted selection** — pass the transcript to a language model with instructions like *"select all segments where the speaker discusses forgiveness"*

The output of this stage is an **Edit Decision List (EDL)**: an ordered list of timecode ranges to extract.

### 3. Clip Extraction and Assembly

Cut the source video at the specified timecodes and concatenate the resulting clips.

**Primary tools:**

- **FFmpeg** — the industry-standard command-line tool for video manipulation. Supports frame-accurate cutting, re-encoding, concatenation, and format conversion.
- **MoviePy** — a Python library wrapping FFmpeg that provides a cleaner API for scripted workflows.

Example using MoviePy:

```python
from moviepy.editor import VideoFileClip, concatenate_videoclips

edl = [
    (10.5, 25.3),
    (45.0, 60.2),
    (120.8, 145.0),
]

source = VideoFileClip("retreat_talk.mp4")
clips = [source.subclip(start, end) for start, end in edl]
final = concatenate_videoclips(clips, method="compose")
final.write_videofile("output.mp4")
```

### 4. Post-Processing (Optional)

Once the base assembly is complete, additional enhancements can be applied programmatically:

- **Crossfade transitions** between clips (MoviePy or FFmpeg)
- **Title cards and text overlays** (Pillow + MoviePy)
- **Audio normalisation** across clips (FFmpeg loudnorm filter)
- **Scene detection** to avoid cutting mid-shot (PySceneDetect)
- **Subtitle generation** for the final output (Whisper on the assembled video)

## Technology Stack

| Component | Tool | Role |
|---|---|---|
| Transcription | OpenAI Whisper | Generate timestamped transcripts from audio/video |
| Forced alignment | aeneas / gentle | Align existing transcripts to audio for timecodes |
| Segment selection | Python + optional LLM | Identify target segments from transcript |
| Video manipulation | FFmpeg | Cut, concatenate, encode video |
| Scripting layer | MoviePy (Python) | High-level API for programmatic editing |
| Scene detection | PySceneDetect | Detect shot boundaries to refine cut points |
| Subtitle handling | pysubs2 | Parse and generate SRT/VTT subtitle files |

All tools are open-source and run natively on Ubuntu.

## Example Use Cases

**Retreat highlight reel.** A 90-minute retreat talk is recorded. Whisper transcribes it. An LLM is prompted to identify the five most impactful moments. The pipeline extracts those segments, adds title cards between them, and produces a 10-minute highlight video.

**Thematic compilation.** A series of 12 workshop recordings exists. A semantic search finds every segment across all 12 videos where the speaker discusses "community service". The pipeline assembles these into a single thematic compilation.

**Quote extraction.** A speaker is known to have said something memorable but no one remembers which talk it was in. A keyword search across all transcripts locates the segment, and the pipeline extracts just that clip.

## Requirements

- **Ubuntu 22.04+** (or any modern Linux distribution)
- **Python 3.10+**
- **FFmpeg** (available via `apt install ffmpeg`)
- **Whisper** (installable via `pip install openai-whisper`; GPU recommended for speed)
- **MoviePy** (installable via `pip install moviepy`)
- Sufficient disk space for source video and intermediate files

## Next Steps

1. **Proof of concept** — Build a minimal script that takes a single source video and a list of timecode ranges, and produces a concatenated output.
2. **Whisper integration** — Add automatic transcription with word-level timestamps.
3. **Search interface** — Implement keyword and/or semantic search over transcripts to generate EDLs.
4. **Batch processing** — Extend to handle multiple source videos in a single run.
5. **LLM-assisted curation** — Integrate an LLM to intelligently select segments based on natural-language instructions.

## Conclusion

The building blocks for transcript-driven video editing are mature, open-source, and well-supported on Ubuntu. The real value lies in combining them into a coherent pipeline that turns **"find and compile the right moments"** from a manual, hours-long task into a scriptable, repeatable process.
