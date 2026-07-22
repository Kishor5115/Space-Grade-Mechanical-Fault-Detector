# SPI Implementation — Origin, Design, and References

> **SSCS Chipathon 2026 — Track B (Sensor Circuits) | Team B22 — Team Space Jam**

---

## 1. Summary

The SPI master (`rtl/spi_master.v`) was **designed entirely by the team** specifically for the IIS3DWB sensor interface requirements. It is not adapted from an existing open-source SPI core. The design rationale and implementation choices are documented here to make the code fully evaluable by reviewers and to serve as a resource for other teams interfacing with the STMicroelectronics IIS3DWB sensor.

---

## 2. Design Requirements and Constraints

The SPI implementation was designed to meet requirements that ruled out a generic SPI controller:

| Requirement | Impact on Design |
|---|---|
| **IIS3DWB-specific boot sequence** | The sensor must receive exactly 4 configuration register writes before any data read (CTRL1_XL, FIFO_CTRL4, CTRL3_C, INT1_CTRL). A generic SPI controller would require an external state machine to drive this; `spi_master` handles it internally. |
| **48-bit multi-byte burst read** | After the 8-bit command byte (0xA8 = READ + OUTX_L address), the sensor auto-increments through 6 consecutive registers. The receiver must keep CS asserted for all 48 bits without gaps. |
| **SRAM-free RHBD constraint** | No FIFOs or shift-register arrays; all state in flip-flops only. |
| **Async DRDY synchronization** | The sensor's DRDY interrupt is asynchronous to the core clock; it must be synchronized before triggering the FSM. |
| **Area optimization** | The boot write sequence reuses the same 16-bit frame shift path as the read command byte, rather than implementing separate per-register write logic. |

---

## 3. Module Architecture

### 3.1 Sub-modules

| Sub-module | File | Purpose |
|---|---|---|
| `clk_divider_5` | `rtl/clk_divider_5.v` | Divides system clock by 5 to produce the SPI bit clock (`spc_raw`). Toggle-based: output duty cycle is 50%. |
| `ff_2_sync` (×2) | `rtl/ff_2_sync.v` | Two-stage D-FF synchronizer, instanced twice: once for `sensor_drdy` (async interrupt), once for `s_miso` (serial data from sensor). Same synchronizer cell used both times. |

### 3.2 FSM States

The `spi_master` FSM uses a **thermometer-coded** state encoding (each state is a unique one-hot-ish byte pattern) to make illegal state detection at glance more obvious:

| State | Encoding | Description |
|---|---|---|
| `CFG_INIT` | 0x01 | Power-on: loads boot register table, transitions to START with `boot_active=1` |
| `CFG_WR` | 0x41 | Shifts out a 16-bit boot configuration write frame |
| `CFG_NEXT` | 0x43 | One-cycle CS deassert between consecutive boot writes; advances `boot_idx` |
| `IDLE` | 0x03 | Waits for synchronized `sensor_drdy` to assert |
| `START` | 0x07 | Asserts `c_csn` low; routes to `CFG_WR` (boot) or `TX_ADDR` (normal read) |
| `TX_ADDR` | 0x0F | Shifts out 8-bit read command byte `0xA8` MSb-first |
| `RX_DATA` | 0x1F | Shifts in 48 data bits, sampled on rising SPC edge |
| `STOP` | 0x3F | Deasserts `c_csn`; pulses `s_data_out_valid`; waits for `core_ack` |

### 3.3 Boot Register Table

The boot sequence is stored as two 4-entry lookup arrays (address and data), indexed by a 2-bit counter `boot_idx`. This allows the same 16-bit write-frame datapath (one shift counter, one address/data mux) to service all 4 boot registers, keeping the added state to 4 flip-flops instead of replicating write logic per register:

```verilog
// 4-entry boot lookup tables (address + data for each IIS3DWB register)
boot_addr[0] = 7'h10; boot_data[0] = 8'hA0; // CTRL1_XL:   ODR=26.667kHz, FS=00
boot_addr[1] = 7'h0A; boot_data[1] = 8'h00; // FIFO_CTRL4: FIFO bypass
boot_addr[2] = 7'h12; boot_data[2] = 8'h04; // CTRL3_C:    IF_INC=1 (auto-increment)
boot_addr[3] = 7'h0D; boot_data[3] = 8'h01; // INT1_CTRL:  DRDY → INT1

// 16-bit write frame (MSb-first: R/W=0, addr[6:0], data[7:0])
wire [15:0] boot_frame = {1'b0, boot_addr[boot_idx], boot_data[boot_idx]};
```

### 3.4 Edge Detection and Data Timing

The SPI protocol timing (Mode 3) is managed using edge detectors on the divided SPI clock:

```
spc_rise = spc_raw &  ~spc_raw_d  // Rising edge:  sample MISO (in TX_ADDR) or shift in bit (in RX_DATA)
spc_fall = ~spc_raw &  spc_raw_d  // Falling edge: drive MOSI with next bit
```

This avoids clock-domain crossing: the FSM runs on the system clock but acts only at SPI clock edges.

---

## 4. SPI Protocol Compliance with IIS3DWB

| Protocol Requirement | How Satisfied |
|---|---|
| CPOL=1, CPHA=1 (Mode 3) | Clock idles high (`s_clk<=1'b1` in IDLE/START); data driven on falling edge, sampled on rising edge |
| CS high between transactions | `s_csn` deasserted in `STOP`, `IDLE`, `CFG_NEXT` |
| CS toggle between consecutive boot writes | `CFG_NEXT` state deasserts CS for one cycle between each write |
| Auto-increment burst read from OUTX_L | Command byte `0xA8` = `{1'b1, 7'h28}` (READ + addr 0x28) |
| 48-bit data reception (6 bytes) | `bit_cnt` counts from 0 to 47 in `RX_DATA`; CS stays asserted throughout |
| Data held until acknowledged | `STOP` state holds `s_data_out_valid` until `core_ack` received |

---

## 5. Clock Domain Crossing

The SPI master manages two asynchronous inputs using the team-designed `ff_2_sync.v` module:

```verilog
// Two-stage flip-flop synchronizer (generic, reusable)
module ff_2_sync (
    input  clk,
    input  async_in,
    output reg sync_out
);
    reg meta_ff;
    always @(posedge clk) begin
        meta_ff  <= async_in;
        sync_out <= meta_ff;
    end
endmodule
```

This synchronizer is used for:
1. `sensor_drdy` (async from IIS3DWB INT1 pin → synchronized for FSM trigger)
2. `s_miso` (async serial data from sensor → synchronized for data sampling)

The 2-cycle synchronization latency is negligible: at 26.667 kHz ODR against a 10 MHz system clock, there are 375 clock cycles between samples. The 2-cycle DRDY synchronization delay of 0.2 µs is immaterial compared to the ~37.5 µs sample period.

---

## 6. Verification

The SPI master is verified by `testing/spi_master_test/tb_spi_master_full.v` using `iis3dwb_model.v` — a purpose-built bus-functional model of the IIS3DWB sensor. The model:

- Accepts and validates boot write frames (checks address and data)
- Returns per-axis sample data on burst reads
- Operates on SPI Mode 3 edges (not a generic SPI slave model)

**Result: 71/71 self-checking assertions pass.**

The iis3dwb model was developed by the team for this project and can be reused by other teams interfacing with the IIS3DWB sensor. It is located at `testing/spi_master_test/iis3dwb_model.v`.

---

## 7. References

1. **STMicroelectronics IIS3DWB Datasheet** (DS12569 Rev 8)
   - Section 3.2, Figure 3: SPI Mode 3 timing diagram
   - Section 7.2: Register CTRL1_XL (0x10) — ODR and full-scale selection
   - Section 7.3: Register CTRL3_C (0x12) — IF_INC for auto-increment
   - Section 7.6: Register INT1_CTRL (0x0D) — DRDY routing to INT1
   - Section 7.8: FIFO_CTRL4 (0x0A) — FIFO mode selection
   - Available from: [STMicroelectronics product page](https://www.st.com/en/mems-and-sensors/iis3dwb.html)

2. **SPI Mode Specification**
   - Motorola SPI Block Guide V03.06 (canonical SPI Mode 3 timing reference)
   - CPOL=1 (clock polarity): clock idle state is high
   - CPHA=1 (clock phase): data is driven on the falling edge and sampled on the rising edge

3. **Goertzel algorithm reference** (for context on the data the SPI feeds into):
   - Goertzel, G. (1958). "An Algorithm for the Evaluation of Finite Trigonometric Series." *The American Mathematical Monthly*, 65(1), 34–35.
   - IEEE reference used by this project: [https://ieeexplore.ieee.org/document/10127757](https://ieeexplore.ieee.org/document/10127757)

4. **EE671 Goertzel ASIC** (related academic reference; our SPI is independently developed):
   - [https://github.com/abhineet-agarwal/EE671-Goertzel-ASIC](https://github.com/abhineet-agarwal/EE671-Goertzel-ASIC)

---

## 8. Files Available for Other Teams

The following files from this project may be useful to other teams interfacing with the IIS3DWB sensor:

| File | Description | License |
|---|---|---|
| `rtl/spi_master.v` | SPI Mode 3 master with IIS3DWB boot sequence and 48-bit burst read | See project LICENSE |
| `rtl/clk_divider_5.v` | Simple divide-by-5 clock divider for SPI clock generation | See project LICENSE |
| `rtl/ff_2_sync.v` | Generic 2-stage flip-flop synchronizer | See project LICENSE |
| `testing/spi_master_test/iis3dwb_model.v` | Bus-functional model of the IIS3DWB sensor (simulation only) | See project LICENSE |
| `testing/spi_master_test/tb_spi_master_full.v` | Self-checking testbench (71 assertions) for the SPI master | See project LICENSE |
