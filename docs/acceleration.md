# DPU, GPU, and analytics acceleration

The baseline does not instantiate a DPU. Fixed-format parsing, book updates, and
risk rules map directly to deterministic RTL and do not benefit from neural
inference. A DPU would consume PL resources, add Vitis AI runtime/version
coupling, and introduce latency variance.

The ZCU102 Mali-400 is intended for graphics/OpenGL ES. It is not a suitable
general-purpose compute target for the trading path. It may render a future
local visualization, but the current Textual dashboard works over a serial or
SSH terminal.

Noncritical A53 analytics should first use ordinary Rust iterators and measured
batching. NEON-aware library implementations may be evaluated against a scalar
reference. Any future DPU/GPU experiment consumes immutable snapshots and
cannot feed an order decision until independently bounded, tested, and enabled
by a separate risk policy.
