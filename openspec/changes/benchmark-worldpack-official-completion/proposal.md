# Change: Complete official structured-codec and WorldPack benchmarks

## Why

Earlier experiments used only OpenZL serial ACE, omitted ALP and WebGraph, and tested only partial PWA2 containers. Those results cannot establish the attainable result of the official workflows or the complete project architecture.

## What changes

- Add an experiment-only OpenZL parser plus complete ACE and clustering training benchmark.
- Add official ALP exact floating-point column benchmarks.
- Add official WebGraph Rust and clean Elias–Fano graph-stream benchmarks.
- Add a complete WorldPack container benchmark that counts every model, sidecar, index and manifest byte.
- Advance from minimum units to 100 MB and a complete frozen project only through strict exactness and size gates.
- Do not change production code, access the phone, build the App, or install any bundle.
