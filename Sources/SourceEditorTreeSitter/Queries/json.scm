; Adapted from tree-sitter-json v0.24.8. See THIRD_PARTY_NOTICES.txt.
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
