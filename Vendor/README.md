# Downloaded Tree-sitter C dependencies

These MIT-licensed sources are downloaded on demand and ignored by Git. They
are only dependencies of the optional
`SourceEditorTreeSitter` product. The `SourceEditor` target does not import,
compile or link them. No remote SwiftPM dependency or Swift wrapper is required.

- `tree-sitter` v0.27.1: runtime `lib/src`, public C headers, and LICENSE.
- `tree-sitter-json` v0.24.8: generated parser, support headers, upstream queries,
  C/Swift binding headers, and LICENSE.
- `tree-sitter-javascript` v0.25.0: generated parser, scanner, support headers,
  upstream queries, C/Swift binding headers, and LICENSE.

Run `./script/bootstrap.sh` from the repository root to install them. The demo
and full test scripts run it automatically. It requires Python 3 and curl, checks
the archive SHA-256 before extraction, and installs only the paths declared in
`versions.json`. Archives are cached in `.build/dependency-archives`; verified
installed copies are reused without network access. `./script/bootstrap.sh --check`
verifies those copies without downloading or changing files. Existing source
directories are adopted only if their contents match the pinned archive; local
changes are never overwritten.

Keep this README, `versions.json`, and `THIRD_PARTY_NOTICES.txt` in Git. Do not add
the downloaded `tree-sitter*` directories. After changing a pinned version or
path list, move the old dependency directory aside and rerun bootstrap. A clean
checkout needs no downloads for `./script/test.sh --core-only` or
`SOURCE_EDITOR_CORE_ONLY=1 swift build --target SourceEditor`.

Upstream files are kept unformatted. Editor-specific query adaptations live in
`Sources/SourceEditorTreeSitter/Queries` and use engine-independent token kinds.
