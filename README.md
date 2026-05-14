# pcileech-cmedia-cmi8738

**PCILeech FPGA firmware — C-Media CMI8738/PCI-SX sound card emulation**

Emulates a **C-Media CMI8738/PCI-SX** (`13F6:0111 rev 0x10`) on Artix-7–based PCILeech DMA boards (Captain DMA 100T, Captain 75T, Enigma x1, Squirrel, Screamer M.2, TBX4 100T). The device appears to the host OS as a fully functional legacy PCI audio card: the driver installs, DMA channels negotiate, interrupts fire, and position counters advance — all while PCILeech operates normally underneath with zero audio TLP overhead.

> **Educational / research project.** Intended for hardware emulation research, OS driver analysis, and PCIe protocol study.

---

## Features

- **Authentic config space** — VID/DID `13F6:0111`, class `0401`, BAR0 I/O 256 B, PM cap at `0xC0`, no MSI (legacy INTx only), captured from a real CMI8738 board
- **Full CMI8738 BAR0 register map** — FUNCTRL0/1, FRAME1/2 (CH0+CH1), INT_HLDCLR, INT_STATUS, CH0/CH1 position counters, sample-rate registers
- **Null audio endpoint** — driver programs DMA buffers as on real hardware; position decrements at the correct sample rate; period interrupts (CHINT0/CHINT1) fire on schedule; zero memory-read TLPs generated
- **Fake DMA MRd generator** (Step 4) — optional periodic MRd TLPs mirroring real audio bus traffic (~1 378 MRd/s per active channel at 44.1 kHz stereo 16-bit); tag range `0xFC–0xFF` reserved, round-robin arbitration, safety gates on base/size, 100-cycle `tready` watchdog
- **PCILeech fully unaffected** — audio logic and PCILeech DMA path are completely isolated; all audio TLP work happens in the BAR controller, not in the TLP pipeline
- **Multi-board support** — single source tree, board-specific top modules and XDC constraint files

---

## Supported boards

| Board | Top module | XDC |
|---|---|---|
| Captain DMA 100T | `pcileech_100t484_x1_top` | `pcileech_100t484_x1_captaindma_100t.xdc` |
| Captain 75T | `pcileech_75t484_x1_top` | `pcileech_captain_75T.xdc` / `pcileech_75t484_x1_hackdma_75t.xdc` |
| Enigma x1 | `pcileech_enigma_x1_top` | `pcileech_enigma_x1.xdc` |
| Squirrel | `pcileech_squirrel_top` | `pcileech_squirrel.xdc` |
| Screamer M.2 | `pcileech_screamer_m2_top` | `pcileech_screamer_m2.xdc` |
| TBX4 100T | `pcileech_tbx4_100t_top` | `pcileech_tbx4_100t.xdc` |

---

## Repository layout

```
c-media/
├── src/                          # SystemVerilog / Verilog sources
│   ├── pcileech_tlps128_bar_controller.sv   # CMI8738 BAR0 register model + null endpoint
│   ├── pcileech_fake_dma_gen.sv             # Step 4: fake MRd TLP generator
│   ├── pcileech_pcie_a7.sv                  # PCIe A7 top-level
│   ├── pcileech_pcie_cfg_a7.sv              # PCIe config-space handler
│   ├── pcileech_pcie_tlp_a7.sv              # TLP pipeline
│   ├── pcileech_fifo.sv                     # FIFO infrastructure
│   ├── pcileech_tlp_tx_wrap.sv              # TLP TX wrapper (Step 4 mux)
│   ├── pcileech_*_top.sv                    # Per-board top modules
│   ├── pcileech_*.xdc                       # Per-board constraints
│   └── pcileech_header.svh                  # Shared interfaces/defines
│
├── ip/                           # Vivado IP cores (Artix-7 base)
│   ├── pcie_7x_0.xci             # PCIe 7-series IP
│   ├── bram_pcie_cfgspace.xci    # Config space BRAM
│   ├── pcileech_cfgspace.coe     # CMI8738 config space image (real HW dump)
│   ├── pcileech_cfgspace_writemask.coe
│   ├── pcileech_cfgspace_rw1c.coe
│   ├── fifo_*.xci                # FIFOs
│   └── 100t/                     # 100T-specific IP variants
│
├── pcie_7x/                      # PCIe 7-series Verilog wrappers
│
├── vivado_generate_project_captaindma_100t.tcl
└── vivado_generate_project_captain_75T.tcl
```

---

## Building

### Prerequisites

- Vivado 2023.x (tested on 2023.2)
- Artix-7 device support installed
- Target board connected via USB-JTAG

### Generate project (Captain DMA 100T example)

```tcl
# In Vivado Tcl console or vivado -mode batch:
source vivado_generate_project_captaindma_100t.tcl
```

For Captain 75T:

```tcl
source vivado_generate_project_captain_75T.tcl
```

### Synthesize and program

```
# After project generation, in Vivado GUI:
# 1. Run Synthesis
# 2. Run Implementation
# 3. Generate Bitstream
# 4. Open Hardware Manager → Program Device
```

---

## How it works

### Config space

The `.coe` file contains a byte-accurate image of a real CMI8738 board captured with Linux `lspci -xxx` (bus `2a:00.0`, post-BIOS pre-driver state). Key points versus common assumptions:

- PM capability at `0xC0`, **not** `0x40`
- No MSI capability — legacy INTx only, as per chip spec
- No PCIe Express capability (this is a PCI, not PCIe, device)
- CapPtr `0x34` = `0xC0`

### BAR0 null endpoint

The `pcileech_bar_impl_CMI8738_null` module accepts all writes the `cmpci` / `snd_cmipci` driver makes (FRAME1, FRAME2, FUNCTRL0, FUNCTRL1, INT_HLDCLR, sample-rate dividers). Internally:

- A position counter per channel decrements at the programmed sample rate (derived from the 62.5 MHz PCIe clock)
- When a counter reaches zero it reloads from the FRAME size and asserts `CHINT0`/`CHINT1` in `INT_STATUS`
- `CM_INTR` is asserted whenever any unmasked channel interrupt is pending, driving `intx_line` → INTx to the host
- `mem_wr_out` and `mem_rd_out` are permanently tied off — no memory TLPs are ever issued from this module

### Fake DMA generator (Step 4)

`pcileech_fake_dma_gen` watches the channel-state outputs of the null endpoint. When a channel is active it emits 3DW MRd TLPs (32-bit addressing, 128 B burst, matching legacy PCI 2.x audio DMA) at the correct cadence. Safety conditions that must all be true before any TLP is issued:

1. `fake_dma_enable` asserted (driver has written the global enable register)
2. `chN_frame1_written` asserted (driver has programmed at least FRAME1)
3. `chN_dma_base` ≠ 0 and ≠ `0xFFFFFFFF`
4. `chN_dma_size` ≠ 0

PCILeech real traffic always preempts via the TX mux; the fake generator only injects when the TLP pipeline is idle.

---

## Device identity (config space summary)

| Field | Value |
|---|---|
| Vendor ID | `0x13F6` (C-Media) |
| Device ID | `0x0111` (CMI8738/PCI-SX) |
| Revision | `0x10` |
| Class code | `0x040100` (Multimedia Audio) |
| BAR0 | I/O space, 256 bytes |
| Subsystem | `13F6:0111` |
| Capabilities | PM cap @ `0xC0` only |
| Interrupt | INTx (INTA), pin 1 |

---

## References

- [PCILeech](https://github.com/ufrisk/pcileech) — Ulf Frisk
- [LeechCore](https://github.com/ufrisk/LeechCore)
- CMI8738 datasheet — C-Media Electronics
- Linux kernel `sound/pci/cmipci.c` — reference for register map and driver behaviour

---

## License

Based on the PCILeech FPGA framework © Ulf Frisk, licensed under GNU GPL v3.  
CMI8738 emulation layer © 2026 — same license.
