# M3 visualization benchmark harness

`swift run -c release hygieia-visualization-bench P03` creates only metadata-only synthetic `FileTree` data and prints source/output counts, checksum and elapsed projection/layout durations. The optional second argument overrides the default fixture size for local smoke checks.

Supported identifiers are `P01` through `P08`; P02 creates the specified balanced `12^5` tree and P03/P04 default to one million direct children. The harness deliberately does not claim RSS, GPU pacing, Instruments allocation results, or an accepted baseline: those require the documented Apple Silicon Release/Instrument manual gate.
