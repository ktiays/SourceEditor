; Adapted from tree-sitter-json v0.24.8. See Vendor/tree-sitter-json/LICENSE.
(pair
  key: (_) @property)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @keyword

(escape_sequence) @escape

(comment) @comment

["{" "}" "[" "]" ":" ","] @punctuation
