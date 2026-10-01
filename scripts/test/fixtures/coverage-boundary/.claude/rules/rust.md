# rust (fixture)

- Coverage: `cargo llvm-cov --ignore-filename-regex '(^|[\\/])(auth|admin|client)\.rs$' --fail-under-lines 90`.
  - In PowerShell wrap the value as `--ignore-filename-regex="…"` — a shape hint, not a copy.
