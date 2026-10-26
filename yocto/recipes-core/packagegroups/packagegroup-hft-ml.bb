SUMMARY = "MYD-CZU5EV-V2 machine-learning runtime (ONNX Runtime, CPU provider)"
DESCRIPTION = "ONNX Runtime for noncritical A53 analytics. It is never used \
in the order path; see docs/acceleration.md."
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    onnxruntime \
    python3-onnxruntime \
    hft-onnx-smoke \
"
