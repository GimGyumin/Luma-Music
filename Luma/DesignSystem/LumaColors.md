# Luma Color System

## Palette overview

| Token | Light | Dark | WCAG | Permitted uses |
|-------|-------|------|------|----------------|
| `lumaAccent` | `#377EEC` | `#499EF8` | ~3.9:1 on white (large text AA) | Play button, scrubber progress, active shuffle/repeat toggle, tappable artist name |
| `lumaAccentSecondary` | `#7FA8F5` | `#78B4FF` | decorative only | Gradient stop alongside `lumaAccent`, tinted backgrounds |
| `lumaAccentBackground` | `#EAF1FD` | `#0E1A30` | — | Badges, pills, selected rows |
| `lumaAccentForeground` | `#1B55B8` | `#8FC0FF` | 6.1:1 / 9.2:1 on `lumaAccentBackground` | Text/icons on `lumaAccentBackground` |
| `lumaAccentText` | white | black | adaptive | Text/icons placed on an accent-filled surface |
| `lumaCoverShadow` | rgba(0,0,0,0.15) | transparent | — | Shadow on cover art in light mode |
| `lumaCoverBorder` | — | white 8% | — | Thin border on cover art in dark mode (replaces invisible shadow) |

### Surfaces and structure

| Token | Light | Dark | Permitted uses |
|-------|-------|------|----------------|
| `lumaBackgroundPrimary` | `#F5F7FF` | `#0F1420` | App canvas / page background |
| `lumaBackgroundSecondary` | `#ECF0FB` | `#141B2A` | Grouped rows and panels |
| `lumaBackgroundTertiary` | `#FFFFFF` | `#1B2335` | Elevated cards |
| `lumaSeparator` | `#377EEC` @ 12% | `#499EF8` @ 15% | Hairlines |
| `lumaBorder` | `#377EEC` @ 18% | `#499EF8` @ 22% | Card and control outlines |

## Rules

1. **`lumaAccent` is strictly for primary interactive elements.** It must never appear on body copy, captions, metadata labels, section headers, or timestamps.
2. **Accent contrast is AA for large text only** (~3.9:1 against white in light mode; ~6.6:1 against the dark canvas). All text using the accent color must be ≥ 18pt regular or ≥ 14pt bold on light surfaces. On accent-filled surfaces use `lumaAccentText`, which flips from white to black with the color scheme so labels stay readable.
3. **Destructive actions keep the system red.** Artwork-derived colors, media-status colors, and content-category colors are not brand colors and may stay varied.
4. **Text and backgrounds use SwiftUI semantic colors** (`Color.primary`, `Color.secondary`, `Color(.systemBackground)`, etc.). Do not add custom colors for text or backgrounds unless there is a concrete, justified need.
5. **Do not add new custom colors without updating this document.**

## Dark mode behavior

- Album canvases retain the existing dominant-color palette and manual color override,
  including when artwork fills the page width. Measured edge colors decide layout
  suitability; they do not replace the page background. Preparation uses the same
  color algorithm at every power budget. Black/white ink and secondary text use
  the existing contrast utilities.

- Shadows on cover art are invisible against dark backgrounds. Use `.lumaCoverStyle()` on all cover art views — it automatically switches to a 1pt border in dark mode.
- `lumaAccent` lightens to `#499EF8` in dark mode for visibility against the near-black canvas; `lumaAccentText` becomes black to preserve contrast on that brighter fill.

## Adding a new color

1. Add the color set to `Assets.xcassets` with both Any and Dark Appearance variants.
2. Add a usage rule to this table.
3. Do not add a manual `Color` extension — Xcode generates `Color.<assetName>` automatically.
