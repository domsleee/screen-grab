# Non-Destructive Annotation Editing via Pixel Deltas

## Problem

Screenshot annotations (rectangles, arrows, text) are "burned" into the PNG pixels. Once saved, annotations cannot be moved, edited, or removed without losing the original image data underneath.

## Solution

Store the original pixels that each annotation covers as metadata in the PNG file. This allows:
- Moving annotations (restore old pixels, redraw at new position)
- Removing annotations (restore original pixels)
- Editing annotations (restore, modify, redraw)

## Design

### Storage Format

Use a PNG private chunk (`scGb` - ScreenGrab) to store binary data:

```
PNG File
├── Standard chunks (IHDR, IDAT, etc.) - flattened image with annotations
└── scGb chunk (private) - restoration data
```

### Chunk Data Structure

```json
{
  "version": 1,
  "annotations": [
    {
      "id": "uuid",
      "type": "rectangle|arrow|text",
      "bounds": { "x": 100, "y": 200, "width": 150, "height": 80 },
      "properties": {
        "color": "#FF0000",
        "strokeWidth": 3,
        "text": "optional for text annotations"
      },
      "originalPixels": "<zlib-compressed raw pixel data>"
    }
  ]
}
```

### Pixel Storage

- **Format:** Raw RGBA pixels, zlib compressed
- **Region:** Bounding rectangle of annotation + small padding (4px)
- **Size impact:** Only ~5-15% file size increase (just annotation-covered areas)

### Workflow

#### Capture & Save
1. User draws annotation
2. Before rendering annotation, capture bounding rect pixels from original image
3. Store bounds + compressed pixels in annotation metadata
4. Render annotation onto image
5. Save PNG with `scGb` chunk containing all annotation data

#### Edit Existing
1. Load PNG, read `scGb` chunk
2. For each annotation: restore original pixels to canvas
3. User can now move/edit/delete annotations
4. Re-capture new bounds, re-render, re-save

#### Share/Export
- PNG works everywhere (viewers ignore unknown chunks)
- Annotations visible in flattened image
- Only ScreenGrab can edit annotations

### Implementation Notes

#### PNG Private Chunks
- Chunk type: 4 ASCII characters
- First letter lowercase = ancillary (safe to ignore)
- `scGb` follows PNG spec for private ancillary chunks

#### Compression
- Use zlib (same as PNG's IDAT)
- Typical compression ratio: 2-10x for UI screenshots
- Example: 200x100 rect = 80KB raw → ~8-20KB compressed

#### Text Annotations
- Store padded bounding box (+20px) to allow text length changes
- If edited text exceeds stored region, extra pixels are left as-is

### File Size Examples

| Screenshot | No annotations | With deltas (3 annotations) |
|------------|---------------|----------------------------|
| 1920x1080 | 1.2 MB | ~1.35 MB (+12%) |
| 800x600 | 400 KB | ~440 KB (+10%) |

### Alternatives Considered

1. **Full original in metadata** - 2x file size, wasteful
2. **JSON sidecar file** - Two files to manage, can get separated
3. **Base64 encoding** - 33% overhead vs binary chunks
4. **Proprietary format** - Poor compatibility, can't preview

### Future Extensions

- Layer ordering (z-index in annotation array)
- Undo history (multiple delta states)
- Partial restore (remove single annotation)
- Export without deltas (strip `scGb` chunk for smaller file)
