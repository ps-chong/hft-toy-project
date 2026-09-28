# Physical PL GTH pins from MYIR MYC-CZU3EG/4EV/5EV-V2 pinout V1.1.
# This file is intentionally excluded from the OOC AXI-stream build. It is
# consumed only by a future verified MAC/PCS wrapper exposing these port names.

set_property PACKAGE_PIN Y6 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN Y5 [get_ports sfp_refclk_n]

set_property PACKAGE_PIN W4 [get_ports sfp_gt0_tx_p]
set_property PACKAGE_PIN W3 [get_ports sfp_gt0_tx_n]
set_property PACKAGE_PIN Y2 [get_ports sfp_gt0_rx_p]
set_property PACKAGE_PIN Y1 [get_ports sfp_gt0_rx_n]

set_property PACKAGE_PIN U4 [get_ports sfp_gt1_tx_p]
set_property PACKAGE_PIN U3 [get_ports sfp_gt1_tx_n]
set_property PACKAGE_PIN V2 [get_ports sfp_gt1_rx_p]
set_property PACKAGE_PIN V1 [get_ports sfp_gt1_rx_n]

# TX-disable controls are available, but their cage-to-GTH mapping has not been
# verified from the public pinout. Keep transmitters disabled until bring-up
# confirms the physical cage map.
set_property PACKAGE_PIN P9  [get_ports sfp_rb_tx_disable]
set_property PACKAGE_PIN H2  [get_ports sfp_rt_tx_disable]
set_property PACKAGE_PIN AE5 [get_ports sfp_lb_tx_disable]
set_property PACKAGE_PIN AF5 [get_ports sfp_lt_tx_disable]
set_property IOSTANDARD LVCMOS18 \
  [get_ports {sfp_rb_tx_disable sfp_rt_tx_disable sfp_lb_tx_disable sfp_lt_tx_disable}]
