# Desktop source reproducibility gate

`Package.swift` still requires `../prim-sim` and its `PrimSimCore` product. Core host behavior, app, CLI and tests all import it; replacing that dependency with a guessed URL or stub would change an unreviewed contract.

On September 7, 2026 the execution checkout contained no sibling source. GitHub lookups for `eidos-agi/prim-sim` and `primfoundation/prim-sim` returned 404 through the connected account. This does not establish that the source was deleted; it could be private, renamed or unpushed. No source revision or licensed redistribution lineage was established.

`prove.sh` now fails before live CLI/ASMP probes when the source dependency or Swift toolchain is absent. It no longer prints `PROVE OK` after skipping the required Swift tests. Bash syntax and the missing-dependency failure were verified; no native success or signed-app result is claimed.

To close this gate, recover the authoritative source checkout and its remote/revision/license, inspect its consumers and contract boundary, then choose a pinned published Swift package or an explicit source import with provenance. Verify a clean macOS clone resolves dependencies and passes the existing host tests. Preserve the package identity and behavior until that compatibility proof exists.

Open integration PRs #2, #3, #4 and #6 remain separate reviewed work. This gate does not merge their overlapping UI/XPC/FDA changes or substitute for notarized Developer ID acceptance. Runtime identity remains `sh.prims.desktop`, team `Y6CQ4SWPWM`, and UTI `com.eidosagi.prim`.
