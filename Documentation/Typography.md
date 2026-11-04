# Row typography

The reference is Xcode 27.1, build 27A9275, inspected using a temporary Objective-C document, local theme files, and the installed editor frameworks. These observations describe that build.

## Xcode observations

| Component | Observed behavior | Local implementation reference |
| --- | --- | --- |
| Natural font height | Rounds `ascender + abs(descender) + leading` up to a whole point. | `SourceEditor.framework`, `NSFont.lineHeight`, `0x40eb90` |
| Text baseline | Core Text fragments retain a descent rounded up to a whole point as their baseline offset from the bottom. | `CoreTextLineLayout.layout`, `0xef74` |
| Line-number font | Uses `XcodeDigits` at the source font's point size. | `SourceEditorTheme.lineNumberFont`, `0x258ca4`; `DVTWorkspaceFontTheme.lineNumberFont`, `DVTUserInterfaceKit.framework`, `0x2a8310` |
| Line-number placement | Centers the number layer in its line fragment, centers the visible glyph height within that layer, and rounds its position. | `SourceEditorGutterMarginContentView.layoutLineNumberForLine`, `0x3f16e4`; `SourceEditorFontSmoothingTextLayer.draw`, `0x2168f8` |
| Gutter sizing | Measures tabular digits and caches widths by digit count. | `SourceEditorGutterMarginContentView.layerSizeForDigits`, `0x3f26b4` |

The installed default themes specify a 1.1 line-spacing multiplier. The current custom One Dark and One Light themes specify 1.2 and configure Maple Mono at 12pt. Theme names and stored font sizes describe configuration; font resolution and size modifiers can affect the effective font.

## SourceEditor policy

SourceEditor adapts these ideas to its fixed-height logical rows using public AppKit and Core Text APIs:

```text
naturalHeight = ceil(ascender + abs(descender) + leading)
rowHeight = ceil(naturalHeight * 1.2)
textBaseline = naturalHeight - ceil(abs(descender))
             + (rowHeight - naturalHeight) / 2
numberBaseline = rowHeight / 2 + midpoint(numberGlyphBounds.y)
numberPointSize = sourcePointSize * 0.9
```

The 1.2 multiplier follows the current reference theme. Distributing the additional spacing evenly is SourceEditor's fixed-grid policy, rather than an assertion that Xcode uses this exact formula for every fragment.

Line numbers are derived from the source font's descriptor at 90% of its point size. They inherit its family, weight, style, and feature settings, preserving the font's natural glyph proportions. This relative size is SourceEditor's visual hierarchy, rather than a rule extracted from Xcode.

The bounds of `0123456789` are measured for vertical centering. Each digit's advance is measured separately, and the largest advance determines gutter width together with the document's digit count. This also accommodates fonts with proportional numerals. These metrics are cached when the source font changes. Baselines are aligned to the backing pixel grid during drawing, including after a display-scale change.

Current-line backgrounds, text selections, caret frames, hit testing, scrolling, and input-method rectangles use the same row height. Typography changes do not add work proportional to the document length.

The default source font is 12pt, with 10.8pt line numbers from the same font family. On the inspected macOS build, the default system monospaced font produces an 18pt row height and a text baseline 13.5pt below the row's top edge.

Core Text documents the [font metrics](https://developer.apple.com/documentation/coretext/ctfont) and [line measurement APIs](https://developer.apple.com/documentation/coretext/ctlinegettypographicbounds(_:_:_:_:)) used here.
