# DPU, GPU, and analytics acceleration

The baseline does not instantiate a DPU. Fixed-format parsing, book updates, and
risk rules map directly to deterministic RTL and do not benefit from neural
inference. A DPU would consume PL resources, add Vitis AI runtime/version
coupling, and introduce latency variance.

The MYD-CZU5EV-V2 Mali-400 is intended for graphics/OpenGL ES. It is not a suitable
general-purpose compute target for the trading path. It may render a future
local visualization, but the current Textual dashboard works over a serial or
SSH terminal.

Noncritical A53 analytics should first use ordinary Rust iterators and measured
batching. NEON-aware library implementations may be evaluated against a scalar
reference. Any future DPU/GPU experiment consumes immutable snapshots and
cannot feed an order decision until independently bounded, tested, and enabled
by a separate risk policy.

## ONNX Runtime on the A53

The image ships ONNX Runtime 1.20.1 (`packagegroup-hft-ml`, enabled by
`HFT_ENABLE_ONNX = "1"`) with the default CPU execution provider, whose MLAS
kernels use NEON on the Cortex-A53. It exists for noncritical analytics only:

- it is never used in the order path, and never on the core reserved for the
  OUCH gateway;
- it consumes the same lossy, immutable snapshots as the other analytics, so
  a slow model cannot back up order flow;
- `hft-onnx-smoke` (one inference of a tiny `y = 2x + 1` model) is not part
  of `hft-update-health`, so ONNX can never trigger an A/B rollback.

The build runs `hft-onnx-smoke` under QEMU user mode, so the target library
is shown to load and infer without hardware. The SDK includes
`onnxruntime-dev` for C++ and Rust consumers. DPU and Vitis AI execution
providers remain out of scope.
