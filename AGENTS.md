# SourceEditor Contributor Guidelines

These requirements apply to all project content, including source code, public
headers, documentation, code comments, examples, tests, scripts, configuration,
and user interface text.

## Language and terminology

- Write all project content in professional English unless the user explicitly
  requests another language for specific content.
- Use precise terminology from editor development, including text storage,
  layout, rendering, selection, caret movement, input methods, syntax parsing,
  accessibility, and the build and test tools that support them.
- Name types, methods, functions, variables, and files after their editor
  responsibilities. Keep examples about documents and editing. Avoid slang,
  playful names, unrelated metaphors, promotional language, and terminology
  borrowed from unrelated domains.
- Explain behavior, coordinate units, ownership, threading, and limitations in
  comments. Use complete, concise sentences and consistent terms.
- Express Unicode test data with Unicode escapes and explain its purpose in
  English. Preserve the characters and UTF-16 lengths required by the tests.
  Adding prose in another language requires the user's explicit instruction.
- Preserve upstream dependency sources, external API names, and license notices
  verbatim. These are external contracts; project documentation and adapters
  remain subject to the requirements above.

## Apple coding conventions

Strictly follow Apple's [Coding Guidelines for Cocoa](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CodingGuidelines/CodingGuidelines.html)
and [Objective-C conventions](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/Conventions/Conventions.html).
Use the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
for Swift declarations in the package manifest and any future Swift source.

- Use the three-letter `SCE` (Source Code Editor) prefix for project-owned
  Objective-C classes, protocols, C functions, constants, and type names.
  Apple's framework class prefixes are reserved. Match header and implementation
  filenames to their primary types.
- Use UpperCamelCase for type names and lowerCamelCase for methods, properties,
  parameters, and local variables. Spell out descriptive names; retain standard
  editor, Cocoa, and encoding terms such as UTF-16, JSON, and URL.
- Start action methods with verbs. Describe every argument with a meaningful
  selector component. Use `get` only when returning values indirectly.
- Follow Cocoa accessor conventions: use `is` for Boolean adjectives and
  `has`, `can`, or a present-tense verb when appropriate. Preserve selectors
  required by AppKit protocols and overridden methods.
- Use `NS_ENUM`, `NS_OPTIONS`, and typed string enums for suitable public types.
  Use `NSInteger`, `NSUInteger`, `CGFloat`, and `NSRange` for Cocoa values;
  retain fixed-width types where required by parser or storage interfaces.
- State object ownership with `copy`, `strong`, or `weak` as appropriate. Declare
  nullability in headers, use `instancetype` for initializers, and follow Cocoa
  initializer, error-reporting, and Core Foundation ownership conventions.
- Do not prefix private methods with an underscore. Use leading underscores for
  instance variables and leave framework selectors unchanged.

## Formatting

Apple's guidance governs API design and naming. The repository's `.clang-format`
defines reproducible whitespace and layout choices for Objective-C source.

- Use four spaces for indentation and spaces instead of tabs.
- Put opening braces on the same line as method signatures, function signatures,
  and control statements. Use braces for every control statement body.
- Put method and function bodies on separate lines, with a blank line between
  definitions. Do not compress blocks or control statements onto one line.
- Align multiline Objective-C selector components and keep lines within the
  configured 120-column limit where practical.
- Run `./script/format.sh` after editing Objective-C files and
  `./script/format.sh --check` before completing a change. Exclude downloaded
  upstream sources from formatting.
- Use `.swift-format` for the Swift package manifest. Run
  `xcrun swift-format format --in-place Package.swift` after edits and
  `xcrun swift-format lint --strict Package.swift` before completing a change.

## Structure and validation

- Keep `SourceEditor` independent of Tree-sitter. Parser integration belongs in
  the optional `SourceEditorTreeSitter` module; application configuration belongs
  in `SourceEditorDemo`.
- Public text offsets and ranges count UTF-16 code units. Use zero-based logical
  line indices internally and document any conversion for display or parser APIs.
- Access editor views on the main thread. Keep parsing on the highlighter's
  serial queue and validate document revisions before applying results.
- Update imports, consumers, examples, and documentation whenever names change.
- Use `./script/test.sh --core-only` for core changes and `./script/test.sh` when
  changing shared interfaces or the optional parser integration. These scripts
  run the Objective-C check executables; `swift test` does not run them.
- Report only validation performed for the current change. Distinguish builds
  and automated checks from visual review, input-method testing, and profiling.
