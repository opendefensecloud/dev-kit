# Design decisions

## Why Nix?

Nix provides reproducible, declarative development environments. It ensures
that every developer (and CI) operates in an identical environment, eliminating
"works on my machine" issues. Nix also enables us to share modules and overlays
across projects, reducing duplication and maintaining consistency.

## Why Make over alternatives?

We evaluated several build tools:

- **magefile**: While Go-native, it is not ideal for scripting workflows that
  primarily orchestrate external binaries.

- **just**: Offers a modern syntax but lacks a built-in module sharing system.
  Migrating our Make ecosystem to just would swap one tool for another without
  meaningful architectural gains.

Make remains pragmatic: it is universally available and familiar to most
developers. While it has its quirks — tabs for indentation, the occasional `$`
escape — it provides all the features we need. The `curl common.mk` pattern
effectively gives us a module system without introducing a new dependency.

## Why not devenv?

We used [devenv](https://devenv.sh) for some time but moved away due to its
dependency on an additional binary and the complexity it introduced during
upgrades.

## Why not Go's tool directive?

Go 1.24's `tool` directive in `go.mod` pulls tooling into the local Go module
ecosystem. This often leads to dependency conflicts, as tools compiled together
with the project can clash with the project's own dependencies.
