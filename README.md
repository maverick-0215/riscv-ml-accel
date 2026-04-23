# AI_Accelarator: PCPI ML Activations (Vivado Simulation)

This repository focuses on Vivado simulation of the `pcpi_ml_activations` coprocessor.

The PicoRV32 core is already present in `picorv32.v`. The coprocessor in `pcpi_ml_activations.v` uses the standard PicoRV32 PCPI handshake (`pcpi_valid`, `pcpi_insn`, `pcpi_rs1`, `pcpi_rs2`, `pcpi_wait`, `pcpi_ready`, `pcpi_wr`, `pcpi_rd`).

## Simulation Scope

- Default validation: standalone PCPI-level simulation using `testbench_pcpi_ml.v` + `pcpi_ml_activations.v`.
- picorv32 core integration : add `picorv32.v` to the project for CPU-in-loop reference/integration work.

## Required Files For Vivado

- Design Sources:
  - `pcpi_ml_activations.v`
- Simulation Sources:
  - `testbench_pcpi_ml.v`

Optional files:

- `picorv32.v` (for CPU-in-loop integration experiments)
- `pcpi_ml_activations.xdc` (synthesis/timing constraints, not required for behavioral simulation)

## Vivado Setup

1. Create a new RTL project.
2. Add `pcpi_ml_activations.v` to Design Sources.
3. Add `testbench_pcpi_ml.v` to Simulation Sources.
4. Set `testbench_pcpi_ml` as the simulation top.
5. Run Behavioral Simulation.
6. Verify transcript output:
   - Passing vectors print `PASS ...`
   - Final summary prints `Summary: passed=<N> failed=<M>`
   - Any mismatch terminates with `$fatal`

## Testbench Coverage

`testbench_pcpi_ml.v` issues custom PCPI opcodes and checks Q16.16 outputs for:

- ReLU
- Leaky ReLU
- Sigmoid approximation
- Tanh approximation

