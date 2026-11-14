# Audio fixtures

These two files are synthetic test tones, not recordings of any song. They contain
a pure sine wave and nothing else. They are released under CC0 (public domain).

| File | Tone | Length | Format |
| --- | --- | --- | --- |
| `tone-220hz-90s.mp3` | 220 Hz sine | 90 s | mono, 48 kbit/s, with `artist` / `title` tags |
| `tone-440hz-4s.mp3` | 440 Hz sine | 4 s | mono, 44.1 kHz, 128 kbit/s, no tags |

The tags in the first file are test data: tests check that a title is taken from
tags, not from the file name. The bytes of both files are compared by tests, so
do not re-encode them.

They can be reproduced (the bytes will differ slightly between ffmpeg builds):

```bash
ffmpeg -f lavfi -i sine=frequency=220:duration=90 -ac 1 -b:a 48k \
  -metadata artist="Metallica" -metadata title="Nothing Else Matters" tone-220hz-90s.mp3
ffmpeg -f lavfi -i sine=frequency=440:duration=4 -ac 1 -b:a 128k tone-440hz-4s.mp3
```
