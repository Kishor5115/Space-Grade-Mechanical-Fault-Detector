# Post-Silicon Test Plan: Space-Grade Mechanical Fault Detector

SSCS Chipathon 2026, Track B, Team B22 Space Jam

| Item | Value |
|---|---|
| Device | `top` macro in the `slot_1x1` pad ring, 800 µm x 800 µm |
| Layout | LibreLane run `PADCTRL_800_r6`, GDS SHA-256 begins `01df13d571e917b246b9` |
| Supply and clock | Single 5 V supply, 16 MHz system clock |
| Audience | Whoever runs the bench bring-up |
| Status | Draft, written before silicon. No step here has been run. |

If the layout changes, re-check section 3 (net names) and the hash above.

> **RTL changed after `r6`.** Three functional bugs were found while building the golden model and are now
> fixed in RTL (section 3). `r6` has been superseded by run `PADCTRL_800_r8`, which was still running when
> this note was written. Update the layout row above and the net table in section 3 from `r8`'s results.

## 1. How this plan works

The tests form a chain. Each gate proves one thing, and later tests rely on that proof, so a later
failure can only point to what has not yet been proven.

**Rules that apply to every step**

1. Do not start a gate until the previous gate has passed on the same device.
2. If a gate fails, stop on that device. Do not continue "to see what else works". Follow the
   failure action in that gate, then restart from the gate it names.
3. Change one thing at a time. If you rework the board or firmware, re-run every gate from the
   earliest one that touched the changed part.
4. After any power cycle, repeat Gate 3 (reset and boot). The boot writes run only once per reset.
5. Log every result against the device ID as you go (section 8). A result not in the log did not
   happen.
6. Never leave an input floating. The input pads have no enabled pull-ups or pull-downs.
7. Do not connect a real IIS3DWB in this first bring-up. All SPI testing uses the automated scripts
   and the sensor emulator (section 4). Gate 10 is future work. The chip's pads swing 0 to 5 V and the
   sensor is rated about 3.6 V maximum.
8. Run gates through the test scripts where a script exists, so that every device gets the same
   stimulus and the same pass criteria.

**Where the limits come from**

| Tag | Meaning |
|---|---|
| [D] | Fixed by the design: RTL, testbench or spec. A miss is a failure. |
| [M] | Tool estimate. A miss needs investigating, and the model may be the wrong side. |
| [P] | Provisional lab limit chosen for this plan. Revise it after the first good devices. |

## 2. The chain of gates

| Gate | Proves | Why the next gate can rely on it |
|---|---|---|
| 0. Fixture, no chip | Board, supply, clock and emulator are correct | Later faults are not caused by the fixture |
| 1. Unpowered checks | No shorts or opens at the pins | Safe to apply power |
| 2. Power and clock | Device draws sane current and takes a clock | Logic is alive and not overstressed |
| 3. Reset and boot | Reset, clock tree, SPI master and output pads work | Sensor SPI output can be trusted as a probe |
| 4. Sample read | DRDY, MISO and the read state machine work | Samples reach the chip correctly |
| 5. Command SPI | Configuration writes reach the registers | Coefficients and thresholds are what we wrote |
| 6. Detection | The DSP and the alarm path work, one tone at a time | The flag can be trusted as a measurement |
| 7. Flag control | Clear, re-trip, stop and restart work | Tests can repeat on one device without a reset |
| 8. Magnitude accuracy | Trip points match the RTL model on all 9 pairs | The DSP is numerically correct |
| 9. Mode strap | `tmr_forward_en` does not change detection | Both modes are usable |
| 10. Real sensor (future) | Works with the IIS3DWB in a closed loop | The system works, not just the chip. Not required by later gates. |
| 11. Voltage and temperature | Gates 3 to 8 hold across the signed-off range | Timing and limits hold at the corners |
| 12. Clock margin | Timing margin above 16 MHz is known | Margin is measured, not assumed |
| 13. Soak | No false trips, missed trips or hangs over time | The device is stable |
| 14. Radiation (optional) | Behaviour under real upsets | Only way to test TMR on silicon |

Gate 11 re-runs earlier gates under stress, which is why it comes after them. A failure there means
the device is sensitive to voltage or temperature, because the same test has already passed at room
conditions.

## 3. What the design means for testing

**Limited visibility.** The chip has no scan chain, no BIST, no fault-injection pin and no register
readback. The command SPI has no MISO, and neither APB master can issue a read to the outside. The
only outputs are `fault_flag_out`, `c_csn`, `c_sclk` and `c_mosi`. So:

- `STATUS`, `FAULT_MAG` and `FAULT_BIN` cannot be read off-chip.
- A configuration write can only be confirmed by its effect on detection.
- Run one tone at a time, because a trip does not say which axis or bin caused it.
- A stuck-at defect in logic these tests do not exercise will not be seen. Passing this plan is not
  a manufacturing-defect screen.

**Behaviours that shape the steps**

| Behaviour | Source | Consequence |
|---|---|---|
| Boot writes run once, after reset | `spi_master.v` `CFG_INIT` | The sensor must be powered and ready before reset is released. There is no retry. |
| `sys_rst_n` feeds the logic directly, with no reset synchronizer | `top.v` | Reset release is not tied to the clock, so Gate 3 repeats it many times. |
| After reset, `run_enable` is 0 and all config registers are 0 | `tmr_reg_bank.v` | Nothing is detected until `CTRL` bit 0 is written. Write the threshold before start. |
| Sensor reads do not need `run_enable` | `spi_master.v`, `top.v` | Gate 4 can run before any configuration. |
| DRDY is checked as a level in the idle state | `spi_master.v` | DRDY held high causes repeated bursts. Gate 4 tests this. |
| Magnitude is `|X|^2` in Q15: an on-bin tone of amplitude A gives about `(256 * A)^2 * 32768` | `magnitude_compute.v` | Thresholds are large numbers, for example 8388608 at A = 1/16. This holds only below saturation. |
| The block counter holds while stopped | `fault_flagger.v` | The first block after a restart can be partial. Allow 2 full blocks. |
| Trip is immediate, with no debounce, and sticky | `fault_flagger.v` | One magnitude above threshold latches the flag until cleared. |
| The comparator checks all 9 magnitudes in each block | `fault_flagger.v`, `magnitude_compute.v` | A trip point is the largest of the 9, not one chosen pair. The golden model must report all 9. |
| A coefficient of 0 does not turn a bin off | Goertzel recurrence, `C = 0` gives a filter tuned to Fs/4, 6667 Hz | "Unused" bins still respond to signal. Check them in the golden model when choosing any threshold. |
| Pulls are off on all input pads | `top.v`, `chip_core.sv` | The board must drive every input. |

**RTL bugs fixed after `r6`.** All three passed the earlier simulations, because those only checked that the
flag trips, and they hid one another. Gates 4, 6 and 8 are the silicon checks for them.

| Bug | Effect before the fix | Fix | Silicon check |
|---|---|---|---|
| Sample bytes swapped: the sensor sends the low byte first, and the DSP received `{low, high}` | X sent as `0x1122` reached the DSP as `0x2211` | `axis_sequencer.v` swaps each slice back | Gate 6 case 6.10 |
| Multiplier results shifted by 22 bits instead of 15 in `magnitude_compute.v` | Every product 128x too small, so the Goertzel filter did not resonate | Correct shift, and the squares keep their full range | Gate 8 |
| Read command depended on DRDY phase against the clk/8 divider in `spi_master.v` | The command went out as `0x28` instead of `0xA8` at some phases, so a sensor would see a write | `START` waits until the divided clock is high | Gate 4 step 8 |

The `_sensor_emulator` in `tb/test_top.py` also sent data out of line, which is fixed. Its old behaviour is why the
first bug stayed hidden.

**Range limit that remains.** The filter state is 24-bit Q8.15. It saturates for strong tones, which makes readings
non-monotonic. At 1041.7 Hz this starts between 1/8 and 1/4 of full scale, and the golden file shows a 1/4-scale
tone reading 12426463, lower than 33554270 at 1/8 scale in an earlier trial. At 10000.1 Hz, full scale reads
66681060, lower than 134227786 at 1/4 scale. The lowest saturated reading in the golden file is 12426463, so
set working thresholds well below that value.

**Items to confirm before the board is built**

1. **Package and pin numbers.** Not recorded in this repo. This plan uses signal names only.
2. **Supply.** Confirm with the organizers that `slot_1x1` is powered at 5 V.

`c_csn` now has its weak pad pull-up enabled in both `top.v` and `padring/src/chip_core.sv`. This takes
effect only after the chip top is rebuilt, and it cannot be measured on silicon, because the pad driver
is always on. Keep the board footprint in section 4 as a fallback.

**Known risks from signoff**

These figures are from `r6`. Replace them with the `r8` results. Layout `r6` exceeds the liberty maximum capacitance on two nets. Slew and fanout are within limits
at all 9 corners, and the other 6 corners are clean.

| Corner | Net | Driver | Cap vs limit (pF) | Over by |
|---|---|---|---|---|
| `max_ff_n40C_5v50` | `_10834_` | `_17260_`, `nand2_1`, fanout 1 | 0.21333 vs 0.20800 | 0.00533 (2.6%) |
| `max_tt_025C_5v00` | `_10834_` | `_17260_`, `nand2_1`, fanout 1 | 0.21333 vs 0.21260 | 0.00073 (0.3%) |
| `max_ss_125C_4v50` | `_11893_` | `_18319_`, `aoi21_1`, fanout 6 | 0.12151 vs 0.12080 | 0.00071 (0.6%) |

These nets cannot be probed. Gate 11 is the only check on them, so it starts with the cold high-voltage
and hot low-voltage conditions.

Power and IR drop are estimates without simulation activity or pad effects. Gate 2 gives the first
real number.

## 4. Equipment

| Item | Requirement |
|---|---|
| Bench supply | 4.5 to 5.5 V, programmable current limit, current readback |
| Current meter | Able to resolve µA for static current and mA for active current |
| Clock source | 16 MHz, 0 to 5 V swing, adjustable to at least 25 MHz for Gate 12 |
| Logic analyzer | At least 8 channels, at least 100 MS/s, SPI decode |
| Oscilloscope | At least 200 MHz, for levels and edges |
| Sensor emulator | MCU or FPGA, see below |
| Command host | Sends 40-bit mode 3 frames at up to 4 MHz, can send 39- and 41-bit frames |
| Level translation | Between 5 V chip pads and any 3.3 V parts |
| Thermal chamber | -40 °C to 125 °C for Gate 11. Board, socket and cables must survive it. |
| Custom test PCB | See below. Used for every gate from Gate 0 onward. |
| Shaker or vibration source | Future, Gate 10 only. Known frequency and amplitude. |
| IIS3DWB | Future, Gate 10 only. Must power up before reset release. |

**Custom test PCB.** Use a purpose-built board instead of a breadboard or adapter. It keeps wiring short
and repeatable at 16 MHz, makes every signal reachable, and means each device is tested the same way.

| Board feature | What it makes easier | Gate |
|---|---|---|
| Socket for the final package (footprint chosen once the package is confirmed) | Swap devices without soldering | All |
| Labeled test point and ground pad on every signal | Fast scope and logic analyzer access | 0, 3, 4 |
| Logic analyzer header on the 3 sensor SPI outputs, `fault_flag_out`, DRDY, MISO and the command SPI | Scripted capture with no re-probing | 3 to 9 |
| Removable link in series with VDD, plus a current-sense shunt | Measure static and active current without rework | 2, 11, 13 |
| Decoupling close to each supply pin, with a footprint for extra capacitance | Stable supply, and a way to test supply sensitivity | 2, 11 |
| On-board 16 MHz oscillator and an SMA input, selected by a jumper | Normal running, or a variable clock | 2, 12 |
| Source-series resistor footprints on clock and outputs | Control ringing, with 0 Ω fitted by default | 3 |
| Jumper on `tmr_forward_en`, with a defined level in both positions | Mode change without floating the input | 9 |
| Default levels on every input, overridden by the controller | No input ever floats, including with the controller unplugged | All |
| Reset button, and reset driven from the controller | Manual checks and scripted resets | 3 |
| Pull-up footprint on `c_csn`, not fitted by default | Fallback if the on-chip pull-up is not in the final chip | 3 |
| LED buffered from `fault_flag_out`, so that it does not load the pad | Quick visual check | 6, 7 |
| Connector for the controller | Plugs into the MCU or FPGA that runs the scripts | 0, 3 to 9 |
| Sensor header with level translator and separately switched 3.3 V supply, not fitted at first | Ready for the future real-sensor gate | 10 |
| Links to isolate each block | Faults can be narrowed down on the bench | All |
| Parts and connectors rated for the chamber, or a small device board on cables | Survives -40 °C to 125 °C | 11 |

Gate 0 is the board's own test. If the board is respun, repeat Gate 0, then every gate from the earliest one
the change touches.

**Automated SPI test scripts.** First bring-up does not use the real sensor, which is planned for later.
The emulator and scripts are what test the SPI paths, so these exist before silicon arrives. Keep them in
the repo with this plan.

| Script | Gate | What it does |
|---|---|---|
| `check_fixture` | 0 | Checks input levels and loops the emulator back to a known SPI master |
| `check_boot` | 3 | Resets, decodes all 4 boot frames, checks order, timing and idle bus, and repeats 1000 times |
| `check_sample_read` | 4 | Checks one frame per DRDY, frame timing, no frames without DRDY, and recovery after DRDY held high |
| `check_cmd_spi` | 5 | Runs cases 5.1 to 5.8, including 39- and 41-bit frames and rate limits |
| `check_detection` | 6 | Runs each case against `tb/golden_values.json` |
| `check_flag_control` | 7 | Runs the sticky, clear, stop and restart sequences |
| `threshold_search` | 8 | Runs the binary search on all pairs and compares results with `tb/golden_values.json` |
| `run_corner` | 11 | Runs the reduced set at one voltage and temperature |

Each script must:

1. Take its stimulus and expected values from `tb/golden_values.json` and the formulas in section 5, and
   not from hard-coded copies.
2. Stop at the first failure and report the gate, step and failing value, following the rules in section 1.
3. Log device ID, conditions, script version and result to one file per device (section 8).
4. Save the raw analyzer capture for any failure.
5. Support a dry run against the emulator with no chip fitted.

Test the scripts and emulator against RTL simulation before silicon arrives, so that a later failure
points at the chip and not the test setup. When the real sensor is added, `check_boot` and
`check_sample_read` can run unchanged with the sensor on the bus.

**Sensor emulator.** It must act as an IIS3DWB SPI slave and needs to do all of the following:

- SPI mode 3 at 2 MHz: `c_sclk` idles high, MISO changes on the falling edge, the chip samples on the
  rising edge.
- Log the 4 boot write frames.
- Answer command `0xA8` with 6 bytes in the order `OUTX_L, OUTX_H, OUTY_L, OUTY_H, OUTZ_L, OUTZ_H`,
  most significant bit first within each byte.
- Drive `sensor_drdy` at 26.667 kHz, and also on demand.
- Play sample tables for each axis in 16-bit signed format.

**Golden model.** `tb/test_golden.py` (run with `make test-golden` in `tb/`) produces the expected values
for Gates 6 and 8 in `tb/golden_values.json`. It plays the same samples and timing as the bench through
RTL simulation, using a correct IIS3DWB emulator, and records all 9 magnitudes.

| Test | What it does |
|---|---|
| `test_sample_byte_order` | Prerequisite: a sensor sample must reach the DSP unchanged |
| `test_read_command_all_drdy_phases` | Prerequisite: all 8 DRDY phases against the SPI divider must give a read |
| `test_gate6` | Measures each Gate 6 case, chooses its threshold, then confirms the flag result in simulation |
| `test_gate8` | Records the expected search result for 9 pairs at 3 amplitudes, and confirms the search method: flag low at the result, high one count below it, with repeated blocks identical |

Regenerate the file after any RTL change. The golden model reads internal signals, so it runs on RTL and
not on the flattened gate-level netlist.

## 5. Reference values

**Timing [D]**

| Quantity | Value |
|---|---|
| System clock | 16 MHz, 62.5 ns period |
| `c_sclk` | clk / 8 = 2 MHz, 500 ns period, SPI mode 3 |
| Sensor sample period | 37.5 µs at 26.667 kHz, which is 600 clocks |
| Read frame | 8 command bits + 48 data bits = 56 bits, 28 µs |
| Block length | 512 samples, 19.2 ms |
| Trip latency | Within 2 blocks of the tone starting, 38.4 ms |
| `cmd_sclk` maximum | clk / 4 = 4 MHz |

**Input levels:** VIH about 3.5 V at 5 V supply, per `docs/specs/IO_SPECIFICATION.md`.

**Boot frames in order [D]**

| Order | Register | Frame bytes | Meaning |
|---|---|---|---|
| 1 | `CTRL1_XL` | `10 A0` | Enable accelerometer, 26.667 kHz |
| 2 | `FIFO_CTRL4` | `0A 00` | FIFO bypass |
| 3 | `CTRL3_C` | `12 04` | Address auto-increment |
| 4 | `INT1_CTRL` | `0D 01` | DRDY on INT1 |

**Command frames [D].** 40 bits, most significant bit first, `cmd_csn` low for the whole frame. The
write happens when `cmd_csn` rises, and only if exactly 40 bits arrived.

| Purpose | Frame bytes |
|---|---|
| `CFG_C0`, bin 0 at 1041.7 Hz (k = 20) | `04 00 00 F8 54` |
| `CFG_C1`, bin 1 at 5000.1 Hz (k = 96) | `08 00 00 61 F8` |
| `CFG_C2`, bin 2 at 10000.1 Hz (k = 192) | `0C 00 FF 4A FB` |
| Threshold 14 (as used in simulation) | `10 00 00 00 0E` |
| Threshold maximum | `10 7F FF FF FF` |
| Start, `CTRL` bit 0 | `00 00 00 00 01` |
| Clear fault, `CTRL` bit 1 | `00 00 00 00 02` |
| Stop, `CTRL` bit 2 | `00 00 00 00 04` |

Coefficient formula: `C = round(2 * cos(2 * pi * k / 512) * 32768)`, 24-bit two's complement. Use a
whole number of cycles per 512-sample block, so that a tone lands exactly on its bin.

A threshold of 14 is close to the bottom of the range, so it only separates "any signal" from "no signal".
Take working thresholds from the golden model.

**Power [M].** Core only, from flow estimates. Pad current is not included.

| Corner | Power | Current |
|---|---|---|
| `ss_125C_4v50` | 34.1 mW | 7.6 mA |
| `tt_025C_5v00` | 41.6 to 45.9 mW | 8.3 to 9.2 mA |
| `ff_n40C_5v50` | 52.5 mW | 9.5 mA |

## 6. Test procedure

### Gate 0: Fixture check, no chip fitted

**Proves:** the fixture is correct. Everything after this assumes it.

1. Inspect the board against the pin map. Confirm the socket orientation and pin 1.
2. Power the board with the socket empty. Measure the voltage at every socket supply pin.
3. Check that each of `clk`, `sys_rst_n`, `c_miso`, `sensor_drdy`, `tmr_forward_en`, `cmd_sclk`,
   `cmd_csn` and `cmd_mosi` is driven from its source, at 0 and 5 V, with the expected logic level at
   the socket pin.
4. Check that `c_csn` is pulled high at the socket.
5. Measure the 16 MHz clock at the socket: frequency, swing and edges.
6. Loop the emulator back to a known SPI master at 2 MHz in mode 3. Read back a known 6-byte pattern
   and confirm the byte order.
7. Send one 40-bit command frame into the logic analyzer and decode it.
8. Set supply current limit to 50 mA [P].

**Pass:** all levels and frames are correct, with no socket pin above 5.5 V.

**On failure:** fix the fixture and repeat Gate 0.

**Cleared for next:** later failures are not fixture faults, unless the fixture changes.

### Gate 1: Unpowered checks

**Proves:** no assembly fault or gross die fault, so power is safe to apply.

**Entry:** Gate 0 passed. Supply off, device fitted, all sources disconnected.

1. Record the device ID and inspect the package.
2. Measure resistance between VDD and VSS in both directions.
3. Use a diode-test meter to check every signal pin to VSS and to VDD. Each pad should show its ESD
   diode.
4. Check for pin-to-pin shorts between adjacent signal pins.

**Pass:** VDD and VSS are not shorted, and all signal pins show consistent diode drops. Compare across
devices, since there is no absolute value in the spec [P].

**On failure:** reject the device. Do not apply power. Inspect the package and bonding, then start
the next device at Gate 1.

**Cleared for next:** a current fault in Gate 2 is not a simple short.

### Gate 2: Power and clock

**Proves:** the device powers up without overstress, the clock reaches the logic, and current can be
compared with the model.

**Entry:** Gate 1 passed. Current limit 50 mA [P].

1. Drive the inputs to a known state before power: `sys_rst_n` = 0, `clk` = 0, `sensor_drdy` = 0,
   `c_miso` = 0, `tmr_forward_en` = 0, `cmd_sclk` = 1, `cmd_csn` = 1, `cmd_mosi` = 0.
2. Raise VDD slowly to 5.0 V while watching the current. Stop if it hits the limit.
3. Record static current with the clock stopped and reset low. The core model predicts about 1 µA.
   Pad leakage is not modeled, so record it as a baseline.
4. Start the 16 MHz clock with reset still low, and record the current.
5. Release `sys_rst_n` and record the active current, with no DRDY and no configuration.
6. Check that `fault_flag_out` is low throughout.

**Pass:**

- Current stays below the 50 mA limit at all times, and static current is below 5 mA [P].
- Active current is 5 to 25 mA [P], around the 8 to 10 mA model [M].
- The device stays stable for 5 minutes with no drift or heating.

**On failure:**

- At the current limit: remove power at once and reject the device.
- Well outside the model but stable: record it, compare with a second device, then continue only if
  they agree. If they agree, the model is the likely error.

**Cleared for next:** the device is powered safely, and logic that follows has a working supply.

### Gate 3: Reset and boot

**Proves:** the clock tree, reset, the SPI master state machine and three output pads all work. From
here on, the sensor SPI pins can be used as a probe.

**Entry:** Gate 2 passed. Emulator connected, DRDY low.

1. Hold `sys_rst_n` low for at least 10 clocks and check the outputs: `c_csn` high, `c_sclk` high,
   `c_mosi` low, `fault_flag_out` low.
2. Release reset and capture the four boot frames on the logic analyzer.
3. Check frame content and order against section 5.
4. Measure `c_sclk`: 2 MHz, idles high, with data changing on falling edges and stable on rising edges.
5. Check `c_csn` is low for each whole frame and high between frames.
6. After the last frame, check the bus stays idle with no DRDY.
7. Measure output levels on `c_csn`, `c_sclk`, `c_mosi` with the scope: low close to 0 V, high close to
   VDD. Check edges for ringing above the supply.
8. Repeat the reset 1000 times with reset release at varied clock phase. Check every boot sequence
   automatically.

**Pass:** exact frames, in order, in all 1000 resets [D], and no extra activity on the bus.

**On failure:**

- No activity at all: re-check clock and reset at the pin, then suspect the device.
- Wrong frame content: confirm analyzer SPI settings, then suspect the SPI master.
- Occasional failure in the 1000 resets: record the rate and the failing phase. With no reset
  synchronizer, this points to reset recovery. Try a reset release timed away from the clock edge, and
  keep this as a board requirement if it clears the fault.

**Cleared for next:** reset, the clock and the SPI output path are good, so any read failure in Gate 4
is in the DRDY or MISO path or in the read state machine.

### Gate 4: Sample read

**Proves:** DRDY triggers reads, burst timing fits the sample period, and MISO reaches the chip.

**Entry:** Gate 3 passed on this device, since the last power cycle.

1. With no DRDY, check for 1 s that no read frames appear.
2. Pulse `sensor_drdy` once for 5 clocks, the same as in simulation. Check for one frame: command byte
   `0xA8`, then 48 clocks.
3. Check `c_csn` stays low for all 56 bits and rises at the end, and that `c_sclk` stays at 2 MHz.
4. Run DRDY at 26.667 kHz for 10 s. Check for one frame per pulse, with no missing or extra frames. Each
   frame should finish within the 37.5 µs period.
5. Hold DRDY high for 1 s. Bursts should repeat and the chip must not hang. Drop DRDY, check that the bus
   returns to idle, and pulse once more to prove reads still work.
6. Pulse DRDY during boot by resetting with DRDY already high. The four boot frames must still come
   first.
7. Check emulator timing at the chip pin: `c_miso` must be settled before the rising edge of `c_sclk`.
   Record the margin.
8. Step the DRDY pulse through at least 8 clock phases, repeating 1000 times with a DRDY source not locked
   to `clk`. Every command byte must be `0xA8`.

**Pass:** all frames as described [D], and timing margin above 50 ns on MISO [P].

**On failure:**

- No reads: check `sensor_drdy` at the pin. If the signal is good, suspect the DRDY synchronizer or read
  state machine.
- Hangs after DRDY held high: record the state, then reset. This needs a fix on the board if it cannot
  be avoided with the real sensor's DRDY behaviour.

This gate cannot prove that MISO data is captured correctly, because captured data cannot be read. Gate
6 checks that.

**Cleared for next:** samples are requested at the right rate, so a Gate 6 failure is not read timing.

### Gate 5: Command SPI

**Proves:** configuration writes work and bad frames are rejected. There is no readback, so each write is
proven by its effect. Start with `CTRL`, which has the most direct effect.

**Entry:** Gate 4 passed. Emulator running at 26.667 kHz, playing a full-scale 1041.7 Hz tone on X.

**Setup for all cases:** after each case, reset the device and let the boot writes finish.

| Case | Frames sent, in order | Expected `fault_flag_out` after 2 blocks |
|---|---|---|
| 5.1 No start | C0, threshold 14 | Low: `run_enable` is still 0 |
| 5.2 Start | C0, threshold 14, start | High |
| 5.3 High threshold | C0, threshold maximum, start | Low: threshold write took effect |
| 5.4 Short frame | C0, threshold 14, then start with only 39 bits | Low: frame ignored |
| 5.5 Long frame | C0, threshold 14, then start with 41 bits | Low: frame ignored |
| 5.6 Good after bad | Case 5.4, then a correct start frame | High: slave recovers |
| 5.7 Maximum rate | Case 5.2 with `cmd_sclk` at 4 MHz | High |
| 5.8 Slow rate | Case 5.2 with `cmd_sclk` at 100 kHz | High |

Run the set 10 times.

**Pass:** every case matches in all runs [D].

**On failure:**

- 5.2 stays low: this could be the command path or the DSP. Reset, then send only the start frame, leaving
  the threshold at its reset value of 0, and play the tone. If the flag goes high, `CTRL` works and the
  coefficient or threshold write is the suspect. If it stays low, check the frames at the pins with the
  analyzer. If they are correct, stop on this device, because the pins cannot separate `CTRL` from the DSP.
  Confirm the expected result of this check in the golden model first.
- 5.1 goes high: the core is running without a start. Stop and report it, since this is a design-level
  mismatch against simulation.
- Rate-dependent failure: note the highest working `cmd_sclk`, and treat that as the limit if it is below
  4 MHz.

**Cleared for next:** thresholds, coefficients and `CTRL` can be set reliably, so Gate 6 tests the DSP.

### Gate 6: Detection

**Proves:** the MISO capture, byte order, DSP and alarm path work on each axis and bin. Gate 6 also
closes the MISO data gap left open in Gate 4.

**Entry:** Gate 5 passed. `tb/golden_values.json` generated from the RTL that matches this silicon, with
`test_sample_byte_order` passing. Reset before each case.

For each case, set only the coefficient named, write the threshold from section `gate6` of the golden file,
send start, play the tone for 2 blocks, read the flag, then reset. Samples follow the formula in section 5,
with amplitude 1.0 unless stated.

| Case | Coefficient | Tone | Axis | Threshold | Expected |
|---|---|---|---|---|---|
| 6.1 | C0, k = 20 | None, all samples zero | n/a | 14 | Low |
| 6.2 | C0, k = 20 | 1041.7 Hz | X | 14 | High within 38.4 ms |
| 6.3 | C0, k = 20 | 1041.7 Hz | Y | 14 | High |
| 6.4 | C0, k = 20 | 1041.7 Hz | Z | 14 | High |
| 6.5 | C0, k = 20 | 1041.7 Hz | All 3 | 14 | High |
| 6.6 | C0, k = 20 | 1041.7 Hz | X | Maximum | Low |
| 6.7X, Y, Z | C1, k = 96 | 5000.1 Hz | Each in turn | Half of golden peak | High |
| 6.8X, Y, Z | C2, k = 192 | 10000.1 Hz | Each in turn | Half of golden peak | High |
| 6.9 | C0, k = 20 | 5000.1 Hz, off-bin | X | Midway between off-bin and on-bin peaks | Low |
| 6.10X, Y, Z | C0, k = 20 | 1041.7 Hz at amplitude 1/256 | Each in turn | Midway between correct and swapped peaks | Low |
| 6.10X, Y, Z swapped | C0, k = 20 | Same tone, bytes swapped by the emulator | Each in turn | Same threshold | High |

**Case 6.10** tests sample byte order on silicon. A low-amplitude tone gives a much larger magnitude if the
bytes are swapped, so the two orders give opposite flags at this threshold. If the silicon has swapped
bytes, the "correct" row trips and the "swapped" row does not. It checks each axis separately, but it cannot
detect one axis swapped with another, because the flag does not say which axis tripped.

**Pass:** all cases match the golden file [D], and trip latency is within 2 blocks.

**On failure:**

- All cases low, including 6.2: re-check Gate 5, then check MISO levels at the pin, then suspect the DSP.
- 6.10 gives opposite flags to those expected, on all 3 axes: the silicon has swapped sample bytes, which
  should not be possible after the section 3 fix. Check that the silicon matches this RTL, then stop and report
  it.
- One axis fails: suspect MISO data alignment or that axis path.
- 6.1 or 6.6 high: false trip. Stop and check for noise on `c_miso`, the clock or supply.
- Only one bin fails: re-check that coefficient's frame bytes, then suspect that bin.

**Cleared for next:** the flag is a trustworthy indicator, so it can be used as a measurement in Gates 7
and 8.

### Gate 7: Flag control

**Proves:** the flag is sticky, can be cleared, and can re-trip, and stop and restart work. Later gates use
these to avoid resets.

**Entry:** Gate 6 passed.

1. Trip the flag using case 6.2.
2. Stop the tone and play zeros for 10 blocks. The flag must stay high.
3. Send clear. With zeros still playing, the flag must go low within 2 blocks and stay low for 10 blocks.
4. Play the tone again. The flag must trip within 2 blocks.
5. Clear while the tone keeps playing. The flag must drop, then trip again within 2 blocks.
6. Send stop, clear the flag, then play the tone for 10 blocks. The flag must stay low, since `run_enable`
   is 0.
7. Send start and keep playing the tone. The flag must trip within 2 full blocks.
8. Reset while the flag is high. The flag must go low with reset and stay low after it, and the boot frames
   must repeat.
9. Check that a stop and restart leaves the configuration in place, by repeating step 7 without
   rewriting the coefficient or threshold.

**Pass:** all steps as described [D]. Repeat 100 times.

**On failure:**

- Flag will not clear: confirm the clear frame, then suspect `cfg_fault_clear`. Use reset between tests and
  record the gap.
- Trip after stop: stop and report it, because `run_enable` is not controlling the core.

**Cleared for next:** tests can repeat on one device without a reset.

### Gate 8: Magnitude accuracy

**Proves:** the DSP results are numerically correct, across all 9 axis and bin pairs. Flags and thresholds
together act as a readout.

**Entry:** Gate 7 passed. Section `gate8` of `tb/golden_values.json` available. It lists the expected search
result for each point, and records whether the tested pair is the largest of the 9.

Since `FAULT_MAG` cannot be read, use a binary search on `CFG_THRESHOLD`. The block counter must start from
a known position, or the block will see a different tone phase and the result will not match exactly. So
each search step starts from reset:

1. Hold DRDY low. Reset the device and wait for the boot frames to finish.
2. Write one coefficient, then write the threshold at the midpoint of the search range, then send start.
3. Start DRDY, with sample 0 of the table on the first read. Play a table that repeats exactly every 512
   samples, for 2 blocks.
4. If the flag is high, the magnitude is above the threshold, so search upward. If it is low, search
   downward.
5. Continue until the range is 1 count. The lowest threshold that leaves the flag low is the measured
   magnitude. This takes up to 32 steps of about 40 ms each, or about 1.3 s per point.
6. Repeat at 3 amplitudes (full scale, 1/4, 1/16) for all 9 axis and bin pairs.
7. Compare each result with `search_result` in the golden file, using the same table and the same start
   alignment. Where `tested_pair_is_largest` is false, the search measured a different pair, so record that
   the tested pair was not measured directly.

Points at full scale and 1/4 are in the saturated range. They must still match exactly, but do not expect them to
scale with amplitude.

**Pass:** exact match to the golden model for each point [D]. The logic is fixed point and deterministic,
so given identical samples and alignment, any difference is a real error.

**On failure:**

- Off by a constant ratio: check the sample table and golden model first.
- Result changes between repeats: this should not be possible. Suspect timing or noise, and check `c_miso`.
- Wrong on one pair only: suspect that axis and bin path, and compare with Gate 6.

**Cleared for next:** the signal path is numerically correct, so any later change is due to the new
condition.

### Gate 9: Mode strap

**Proves:** `tmr_forward_en` does not change detection. The cocotb top-level test only uses 0, so the top
level at 1 has its first full run here.

**Entry:** Gate 8 passed. Change the strap only while `sys_rst_n` is low.

1. Set `tmr_forward_en` = 1, then release reset.
2. Repeat cases 6.1, 6.2, 6.3, 6.4 and 6.6, plus Gate 7 steps 3 and 4.
3. Repeat Gate 8 on one axis and bin pair, and compare with the result at 0.
4. Send configuration frames while samples flow at 26.667 kHz, to exercise the APB arbiter under
   contention. Repeat 1000 frames, and confirm each frame took effect using threshold changes.

**Pass:** results identical to `tmr_forward_en` = 0 [D], and no lost writes.

**On failure:** run only with `tmr_forward_en` = 0, and record mode 1 as unusable on this device. The rest
of this plan can continue at 0.

**Cleared for next:** the mode for later testing is settled. Use `tmr_forward_en` = 0 unless both modes pass.

### Gate 10: Real sensor (future work)

This gate is not part of first bring-up, and no later gate depends on it. Run it once the emulator-based
gates are complete and the sensor board section is fitted. Re-run `check_boot` and `check_sample_read` with the
sensor on the bus first.

**Proves:** the chip works with the real IIS3DWB in a closed loop.

**Entry:** Gate 9 passed. Check the translator on the bench before fitting the sensor, with 0 to 5 V on the
chip side and no more than 3.6 V on the sensor side.

1. Fit the level translator on `c_sclk`, `c_mosi`, `c_csn`, `c_miso` and `sensor_drdy` if needed. Scope
   both sides at 2 MHz. Check levels against VIH of 3.5 V and the 3.6 V sensor limit.
2. Power up in this order: sensor first, wait for its turn-on time, then release `sys_rst_n`. Boot writes
   run once, so a sensor that is not ready will miss its configuration.
3. Capture the boot frames and the first reads. Check the sensor's DRDY rate is 26.667 kHz, which proves it
   took the configuration. Confirm the DRDY pulse shape does not cause the repeated-burst behaviour in
   Gate 4.
4. Check that the translator delay leaves positive timing margin on MISO.
5. With the sensor at rest, set a threshold from a measured quiet level plus margin, send start, and run for
   10 minutes. The flag must stay low.
6. On a shaker, drive a sine at 1041.7 Hz on the X axis, and increase the amplitude until the flag trips.
   Record the amplitude. Repeat for Y and Z with the sensor reoriented.
7. Confirm off-bin rejection by driving a frequency away from the bins at the same amplitude.
8. Log the sensor samples with an SPI monitor, and compare the trip behaviour with a golden model run on those
   samples.

**Pass:** the flag follows the shaker, with no false trips at rest. Trip amplitudes should be repeatable
within 10% [P], and shaker calibration limits this accuracy.

**On failure:**

- DRDY does not start: the sensor missed the boot writes. Check power sequencing and the translator on
  `c_mosi`.
- Works with emulator but not sensor: the cause is in the translator, levels or sensor setup, since Gates 3
  to 9 already cleared the chip.

**Cleared for next:** the system works at room conditions.

### Gate 11: Voltage and temperature

**Proves:** the behaviour holds across the signed-off range, including the over-limit nets in section 3.

**Entry:** Gate 8 passed at room conditions on this device. Use the emulator, not the sensor, since the sensor
has its own temperature limits. Soak for at least 15 minutes at each temperature [P].

Run in this order, so the riskiest conditions come first:

| Order | Temperature | VDD | Why |
|---|---|---|---|
| 1 | -40 °C | 5.5 V | `_10834_` at its largest overshoot |
| 2 | 125 °C | 4.5 V | Slowest timing, and `_11893_` overshoot |
| 3 | 25 °C | 5.0 V | Confirms the device was not damaged by 1 and 2, and covers `_10834_` at its smaller overshoot |
| 4 | -40 °C | 4.5 V | Cold at low voltage |
| 5 | 125 °C | 5.5 V | Hot at high voltage |
| 6 | 25 °C | 4.5 V | Room at low voltage |
| 7 | 25 °C | 5.5 V | Room at high voltage |

At each condition:

1. Record static and active current.
2. Repeat Gate 3, with 100 resets instead of 1000.
3. Repeat Gate 4 steps 2 to 4.
4. Repeat Gate 5 cases 5.2, 5.3 and 5.4.
5. Repeat Gate 6 cases 6.1, 6.2, 6.3, 6.4 and 6.6.
6. Repeat Gate 7 steps 2 to 4.
7. Repeat Gate 8 on 3 axis and bin pairs. Results must match room temperature exactly.

**Pass:** all checks pass at all conditions, and magnitude matches exactly. Current stays within limits [M]:
compare the trend against section 5.

**On failure:**

- Record the voltage and temperature boundary by stepping back toward 25 °C and 5.0 V. Then re-run row 3, to
  see whether the fault is reversible.
- Failing only at the corners from the table in section 3 points to these nets, but this cannot be proven
  from the pins. Record it as a suspected cause only.
- Do not continue to Gate 12 on a device that failed row 3.

**Cleared for next:** margin testing is meaningful, since the device works across its range.

### Gate 12: Clock margin

**Proves:** the actual maximum clock, compared with the timing model.

**Entry:** Gate 11 passed, or at least row 3. Keep emulator DRDY at 26.667 kHz. `c_sclk` scales with `clk`.

1. At 25 °C and 5.0 V, step the clock up from 16 MHz in 0.5 MHz steps.
2. At each step, repeat Gate 3 with 10 resets, Gate 5 case 5.2 and one Gate 8 point.
3. Record the highest passing frequency, then confirm it with a 10-minute run.
4. Repeat at 125 °C and 4.5 V, the slowest condition.

The flow's worst setup slack is +7.51 ns, which suggests about 18.2 MHz at the slowest corner [M]. Expect
a higher value at room conditions.

**Pass:** at least 17 MHz at 125 °C and 4.5 V [P], so that 16 MHz has real margin.

**On failure:** a limit below 16 MHz at any signed-off condition is a timing failure. Report it, then re-run
Gate 11 at the failing condition.

**Do not** operate above 16 MHz in the final system. This test only measures margin.

### Gate 13: Soak

**Proves:** long-term stability at nominal conditions.

**Entry:** Gate 11 passed. At least 3 devices [P]. Add a chamber at 85 °C if available.

1. Run for 72 hours [P] at 5.0 V and 16 MHz, with DRDY at 26.667 kHz.
2. Alternate between 1 hour of zero or below-threshold samples, and a tone burst with a clear, on a schedule.
3. Log every flag edge with a timestamp, and log supply current each minute.
4. Monitor `c_sclk` and `c_csn` for read frame counts.

**Pass:** zero false trips, zero missed trips, zero hangs, and current steady within 5% [P].

**On failure:** record the time and activity at the failure. Then re-run Gates 3, 6 and 8 to see whether the
device has been permanently changed.

### Gate 14: Radiation (optional)

**Proves:** real SEU and TID behaviour. Bench tests cannot check TMR, since a masked upset shows no change at
the pins. The `test-seu` simulations (3 of 3 passing) are the only evidence without this gate.

**Entry:** Gate 13 passed. Needs access to a heavy-ion, proton or laser facility, plus a de-lidded package for
heavy ions or laser.

1. Before exposure: repeat Gates 3, 6 and 8 and record the results and current.
2. Configure a fixed tone at a threshold just under its magnitude, and a second run just over it.
3. Run during exposure with DRDY at 26.667 kHz, and log flag edges, read frames and current.
4. Count false trips and missed trips, hangs that need a reset, and any sudden current jumps. Current jumps can
   mean latch-up: remove power at once.
5. After exposure: repeat Gates 3, 6 and 8.

**Observable results:** false or missed alarms, boot or read errors, hangs and current changes. Masked upsets
cannot be counted. A flip that has been scrubbed leaves no trace, so this gate gives a system-level error
rate and not a per-bit TMR rate.

**Pass criteria:** set them with the facility and project goals before exposure. None are proposed here.

## 7. Failure triage

Start at the earliest symptom, and use this to find which gate to return to.

| Symptom | First suspect | Return to |
|---|---|---|
| Supply hits current limit | Short, latch-up, power order | Gate 1, on a new device |
| No SPI activity after reset | Clock, reset | Gate 2 |
| Boot frames wrong | Analyzer settings, SPI master | Gate 3 |
| Occasional boot failure | Reset release timing | Gate 3 step 8 |
| No reads on DRDY | DRDY pin, synchronizer | Gate 4 |
| Flag never trips | Missing start, threshold, coefficient | Gate 5 case 5.2 |
| Flag trips with no signal | Threshold, noise on `c_miso` or supply | Gate 6 case 6.1 |
| One axis fails | MISO data alignment, that axis path | Gate 6 case 6.10 |
| Flag will not clear | Clear frame, command path | Gate 7 |
| Wrong trip point | Sample table, golden model, then DSP | Gate 8 |
| Works with emulator, not sensor | Translator, levels, power order | Gate 10 |
| Fails only at temperature or voltage extremes | Timing, over-limit nets | Gate 11 |
| Fails only after hours | Thermal, supply, intermittent logic | Gate 13 |

## 8. Test log

Keep one log per device. Each result needs a date, an operator, and raw captures where available.

| Field | Entry |
|---|---|
| Device ID, package, board ID | |
| Firmware and golden model versions | |
| Gate and step | |
| Conditions: VDD, temperature, clock | |
| Measured values | |
| Result: pass, fail or not run | |
| Capture file names | |
| Notes and any deviation from this plan | |

**Device sample plan [P]**

| Gates | Devices |
|---|---|
| 0 to 9 | All available |
| 10 (future) | At least 2 |
| 11, 12 | At least 3, including the highest and lowest current devices |
| 13 | At least 3 |
| 14 | At least 2, plus 1 unexposed reference |

A release decision for first bring-up needs Gates 0 to 9 and 11 passed on the planned sample, with any
failure explained and recorded. Gate 10 follows later.

## 9. What this plan does not cover

- **Manufacturing defect coverage.** There is no scan or BIST, so coverage is not measured and may be low.
- **Register readback.** `STATUS`, `FAULT_MAG` and `FAULT_BIN` stay unverified on silicon as outputs, and their
  values can only be inferred.
- **TMR voting and scrubbing on the bench.** Only Gate 14 touches these, and only indirectly.
- **Per-net effects of the cap overshoot.** Only the overall behaviour can be seen.
- **ESD and latch-up qualification, reliability and lifetime testing.** These need dedicated standards work and
  sample sizes.
- **On-chip IR drop.** Supply current can be measured, but internal voltage cannot be probed.

## 10. Work needed before silicon arrives

1. Generate `tb/golden_values.json` with `make test-golden`, from the RTL that matches the final layout.
2. Build the sensor emulator, and test it against RTL simulation.
3. Write the automated SPI test scripts (section 4), and dry-run them against the emulator.
4. Design and build the custom test PCB (section 4).
5. Confirm the package, pin map and supply with the organizers (section 3).
6. Re-check section 3 against final signoff. Update the hash and net list if the layout changes.
7. Review every [P] limit after the first good devices, and replace it with measured data.
8. Later: fit the sensor section of the board, and run Gate 10.
