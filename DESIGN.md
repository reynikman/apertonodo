---
version: p4
name: Apertono
description: "Dark Obsidian 2.0: near-black background, graphite tiles with a thin border, one amber accent, glow only from the cover art."
source_of_truth: mobile/lib/theme.dart
colors:
  background: "#07090C"
  surface: "#0E1217"
  surfaceRaised: "#151920"
  navItemActive: "#181D24"
  border: "#FFFFFF12"
  borderStrong: "#FFFFFF1F"
  divider: "#FFFFFF0F"
  accent: "#E5A93B"
  accentHighlight: "#F5B842"
  accentSoft: "#E5A93B24"
  textPrimary: "#FFFFFF"
  textSecondary: "#8C93A4"
  textMuted: "#5D6574"
  error: "#FFB4AB"
  shadow: "#00000099"
  progressTrack: "#1B1F26"
  scrim: "#000000"
  inkOnLight: "#000000DD"
  cardGradient: ["#12161C", "#0A0D12"]
  navGradient: ["#13171D", "#0B0E13"]
typography:
  sans: Onest
  mono: JetBrains Mono
  screenTitle: { size: 26, lineHeight: 32, weight: 700, letterSpacing: -0.52 }
  sectionTitle: { size: 18, lineHeight: 22, weight: 700, letterSpacing: -0.18 }
  promoTitle: { size: 16.5, lineHeight: 20, weight: 700 }
  trackTitle: { size: 15, lineHeight: 19, weight: 600 }
  trackArtist: { size: 12.5, lineHeight: 16, weight: 400, color: textSecondary }
  artistName: { size: 12, lineHeight: 15, weight: 500 }
  time: { family: mono, size: 12, lineHeight: 16, weight: 500, tabularFigures: true }
rounded:
  xLarge: 24
  large: 22
  medium: 16
  genre: 14
  album: 12
  cover: 10
  capsule: 22
  row: 20
  pill: 26
  hairline: 2
spacing:
  screenGutter: 16
  floatingChromeGutter: 14
  rhythm: [4, 8, 10, 12, 16, 24]
  minTouchTarget: 48
---

# DESIGN.md — how Apertono looks

The general style of the app, so that the next screen is built by the rules and not "like the neighbouring one was done".
It describes what is in the code after steps 1–8 of phase P4 (01.10.2026), with numbers. Steps 6–8 (artist, "Library",
player — FT-486, FT-487, FT-489) were still being merged on that date.

- **The source of truth is the code:** colors, fonts, radii and text styles live only in `mobile/lib/theme.dart`
  (`FlowtuneColors`, `FlowtuneFonts`, `FlowtuneRadii`, `FlowtuneText`, `flowtuneTheme()`). If this file and the code
  diverge, the code is right; fix the file in the same MR.
- **Visual reference** — the owner's OpenDesign export "Dark Obsidian 2.0" (kept in the owner's local design folder,
  not in git) and the reference snapshots `mobile/test/goldens/*_360.png`, `*_412.png`. Owner decisions — `plan/decisions/`
  (Р-A27…A34, Р-A39…A41). The export outranks `docs/ui-ux-direction.md` (Р-A27).
- **A new rule** (color, size, component) appears like this: owner decision → token in `theme.dart` → a line
  here. Not the other way round.

## Character

A quiet personal music library. Dark, held together by cover art; the interface is predictable and does not argue with the music. Android,
one column, phone 360–412 dp. No neumorphism, no endless feed, no big shadows and no glowing buttons.
There is no light theme and there will not be.

## Color

| Role | Token | Where |
|---|---|---|
| Screen background | `background` `#07090C` | all screens, AppBar, splash |
| Tile, card | `surface` `#0E1217` | "Library" rows, search cards, player queue, search field, chips |
| Raised surface | `surfaceRaised` `#151920` | round buttons on the player, empty fan slot, SnackBar |
| Home cards, mini-player, bar | `cardGradient`, `navGradient` | top to bottom, only there |
| Thin border | `border` (white 7 %) | on every tile and card, 1 px |
| Stronger border, divider | `borderStrong`, `divider` | rest of the seek bar; lines between rows |
| Text | `textPrimary` white; `textSecondary` `#8C93A4`; `textMuted` | secondary — artist, captions, time |
| **Action** | `accent` `#E5A93B` | see below — only there |
| Error | `error` `#FFB4AB` | error text; not amber |

**Amber is only action and "now":** the Play/Pause button (filled circle, icon in the `background` color), the selected
tab, the played part of the seek bar and its thumb, the mini-player bar, enabled "shuffle" and "repeat",
the title of the playing song in the queue, the main button of a screen ("Listen" on an artist), the search field border in focus.
Not amber: headings, section icons, hearts in headers, arrows, tile borders.

**Cover color** — only a soft glow around the large cover on the player (`CoverGlow`): it does not recolor buttons,
bars and tabs (Material You is rejected). No cover, no glow; this is not an error.

A song that is not playable (no source) is the same row, pale: `onSurface` at opacity 0.38, still tappable.

## Font

Onest — the whole interface (full Cyrillic, OFL, Р-A32). JetBrains Mono — only time and technical numbers, with
tabular figures (`FlowtuneText.time`): "2:14" does not jitter. CJK characters — in the system font. Fonts are bundled as files in
`mobile/fonts/`; loading fonts from the network is forbidden.

| Style | Size/line, weight | Used for |
|---|---|---|
| `screenTitle` | 26/32, 700 | tab title: "Home", "Library", "Browse" |
| `sectionTitle` | 18/22, 700 | block heading (`Heading`) |
| `promoTitle` | 16.5/20, 700 | Home tile title, genre |
| `trackTitle` | 15/19, 600 | song title, "Library" rows |
| `trackArtist` | 12.5/16, 400, `textSecondary` | artist, captions, counters |
| `artistName` | 12/15, 500 | name under a round photo |
| `time` | Mono 12/16, 500 | time, duration |

Larger than these there are only the artist name on the photo (34/40, 700) and the title on the full player (22/28, 700). Second-level
pages (album, playlist, "Liked songs") take the AppBar title from the theme: 22, 600.

## Shape and spacing

- **Radii:** big Home tile 22 (`large`); tab bar 24 (`xLarge`); player cover, search field,
  chips 16 (`medium`); genre 14; album cover 12; small cover 10 (`cover`); tab capsule 22. "Library"
  rows, the artist card in search and the mini-player — 20 (`row`), the "Listen" button — 26 (`pill`), the mini-player bar — 2 (`hairline`).
  The Play, "back/forward" buttons on the player and the player header buttons are circles.
- **Screen margins — 16.** Floating elements (mini-player, tab bar) and the content of Home tiles — 14.
- **Rhythm:** 4 / 8 / 10 / 12 / 16 / 24. Between tiles in a column — 10; between tiles in a grid — 12; block heading —
  16 above, 4 below; between large parts — 24.
- **Tap target** — at least 48×48 of touch area, even if the circle is smaller (mini-player Play is 44 — area 48).
- **Depth** — by surface tone and border. A shadow exists only on the floating tab bar. Glow — only on the
  player cover and the amber spot of the mini-player.

## Screen frame

- Five tabs: **Home · Browse · News · Search · Library** (Р-A83) — a floating bar 66 high (margins 14, bottom 8, radius
  24, `navGradient`, border, shadow), the capsule of the selected one 68×44 with radius 22 on `navItemActive`, the icon amber and
  filled; unselected — outline, `textSecondary`. Under the icon there is a label (Р-A108 item 5, owner's word 08.10; there were no labels before); the label size and the new
  bar height follow the approved prototype "Podcasts and books".
- **Mini-player** — above the bar, gap 8, on all browsing screens.
- **Tab screen** — no AppBar: `SafeArea`, a large `screenTitle` heading on the left with margin 16. Home has
  no brand heading.
- **Second-level screen** — AppBar with a title from the theme and a "back" arrow. Artist is the exception: a full-width
  photo and a round arrow on top.
- **Full player** — a separate screen: without the tab bar and mini-player; at the top round "collapse", heart and "⋮".
- **Large font** (up to ×2): nothing overflows or is cut silently; Home then scrolls
  (Р-A27, Р-A40), rows grow (`minHeight`, not a fixed height).

## Components

Build from these; a new variant only if the content is really different. All are in `mobile/lib/screens/`.

| Component | Code | Look |
|---|---|---|
| Tab bar | `FlowtuneNavBar` (`nav_bar.dart`) | see "Screen frame" |
| Mini-player | `MiniPlayer` (`mini_player.dart`) | card 68 (margins 14, radius 20, `navGradient`, border), cover 46 with an amber border, title 700 and status, bar 2.5 under the text, Play 44 on the right |
| Block heading | `Heading` (`parts.dart`) | `sectionTitle` in white, margins 16/16/16/4 |
| Song row | `TrackTile` (`parts.dart`) | height from 62 (with cover 46) or 56; margins 16; title and caption on one line; on the right a heart and "⋮", 48 each |
| List card | search, "Recent" | rows inside a `surface` card, radius 24, border, 1 px dividers |
| Home tile | `home_screen.dart` | `cardGradient`, border, radius 22, margins 14; icon 28, `promoTitle`, counter `trackArtist`; cover fan 100 |
| "Library" row | `_LibraryRow` (`library_screens.dart`) | `surface`, radius 20, border, height from 86, margins 16×15; white icon 28, title, caption, covers 56, `chevron_right` |
| Genre | `_GenreCard` (`catalog_screens.dart`) | 2-column grid, height 88, radius 14, photo with a dim overlay, `promoTitle` bottom left |
| Album | card 132 | cover 132, radius 12, title and year under it; sideways strip, gap 12 |
| Cover | `Cover` | sizes 44 / 46 / 56 / 64 / 100 / 132 / player; no image — `ArtistSquare` (color from the name, letters) |
| Artist photo | `ArtistAvatar` | circle 48 / 54 / 56 with a `border` border |
| Glow | `CoverGlow` (`cover_glow.dart`) | only the large player cover |
| Play/Pause | `PlayPauseButton` (`parts.dart`) | amber circle; mini-player 44, player 64 (icon 32); states: pause, waiting (not tappable), repeat, play |
| Round button | player header, artist | circle 40: on the player `surfaceRaised`, on a photo — blur and black 35 % |
| "Listen" | artist | pill 52 on `surface`, radius 26, on the left an amber circle 40 with ▶ |
| Search field | `search_screen.dart` | height 50, `surface`, border (amber in focus), radius 16, magnifier 20 `textSecondary` |
| Chip | recent queries | `ActionChip` 32 high, radius 16, `surface`, border, 13/500 `textSecondary`; on one line, scrolls sideways |
| Photo credit | artist | "photo: author, license", 11, `textSecondary`, on the right under the photo; without the credit the photo is not shown |
| Empty, error | `Message`, `Loaded`, `PagedList` | centered, `trackTitle`; error — "Retry" (`FilledButton.tonal`) and `ReportButton` |

**Full player** (step 8, FT-489): a header of three circles 40; cover `min(320, width − 88, height × 0.36)` with radius
16 and glow; title 22/28 and artist 15 on the left with margin 24; seek — bar 4, thumb 12, Mono time at the
edges; button row: "shuffle" and "repeat" without a circle, "back/forward" — circles 52 `surfaceRaised`, Play — 64; below it
the whole queue in one `surface` card (top and bottom rounded 24, rows 56 with a cover 40, time on the right), the playing one with an
amber title.

## States

Every screen with network access has three states besides data: **loading** (`CircularProgressIndicator` in the center or
a bar under the search field), **empty** (a simple phrase: "Nothing in favorites yet", "History is empty"), **error**
(the reason in words, "Retry", "Send report"). The player honestly shows "Looking for source" and "Preparing audio" without
invented percentages. Sources and their addresses are never in the interface.

## Do not

- Amber on headings, borders and section icons; a second accent color; teal (Р-A28).
- Shadows, neumorphism, glowing buttons; glow anywhere except the player cover.
- Recoloring the interface to match the cover.
- A color or radius as a number (`Color(0x…)`, `Colors.white`, `Radius.circular(16)`) — only `theme.dart` tokens; the guard is
  `mobile/test/design_literals_test.dart` (FT-491). `Theme.of(context).textTheme` in a screen is also out, only `FlowtuneText`.
- A fixed height on a row with text — only a minimum (`minHeight`).
- An icon without an action (for example, "≡" without dragging) and items that do not exist on the server (Р-A29).
- Generated portraits and covers as finished images; fake quality badges.

## How to add a screen

1. Assemble from the components above; color, font, radius — by token.
2. A look test: position and size of the key elements at 360 dp, large font without exceptions, reference snapshots
   `*_360.png` and `*_412.png` (`flutter test --update-goldens`; compared only on the Mac — `golden_support.dart`).
3. A case in `scripts/unlazy/design_negative.mjs`: a break of the screen's main spot that the test must notice.
4. Snapshots — look with your eyes next to the export frame, then the APK to the owner (Р-A31).

## Known deviations in the code

Recorded so they are not copied into a new screen; fix in a separate card.

- `textTheme` instead of `FlowtuneText`: the album card caption (`titleSmall`, `bodySmall`), the caption in the search "Recently
  played".
- No style at all: the error text and "Nothing found" in search, the artist biography, "Artist" in the search
  card, the `ReportButton` result; `ArtistSquare` letters without the Onest font.
- The heart in a song row when "in favorites" is amber, while in the player header and on Home it is white.
- Rows of different lists are built separately, not as one `TrackTile`: "Recent" on Home (cover 44, title
  14.5), the artist's "Popular" (cover 56, no heart), the player queue.
