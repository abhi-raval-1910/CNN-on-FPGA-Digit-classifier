# CNN-on-FPGA-Digit-classifier
Verilog-based CNN accelerator for MNIST digit classification on the Digilent Basys3 FPGA, using INT8 fixed-point inference.
# CNN Accelerator on FPGA — Basys3
<p align="center">
  <img src="./WhatsApp%20Image%202026-08-10%20at%2022.20.01.jpeg" alt="CNN Accelerator" width="600">
</p>
A **Version 1 CNN accelerator** implemented in Verilog HDL and deployed on the **Digilent Basys3 FPGA board**. The project explores how a small neural network can be mapped from software to an FPGA using fixed-point/integer arithmetic.

The accelerator performs CNN inference for **MNIST handwritten-digit classification**.

> **Project status:** Version 1 — functional prototype / proof of concept.
> The current design prioritizes simplicity and understanding of the hardware datapath over maximum performance.

---

## Overview

The project takes an MNIST image, processes it through a small CNN, and produces a predicted digit (`0–9`) on the FPGA.

The complete flow is:

```text
MNIST Image
     │
     ▼
Python / Software Preprocessing
     │
     ▼
Image → FPGA
     │
     ▼
┌─────────────────────┐
│   CNN Accelerator   │
│                     │
│  Convolution        │
│       ↓             │
│  ReLU / Scaling     │
│       ↓             │
│  Pooling            │
│       ↓             │
│  Fully Connected    │
│       ↓             │
│  Classification     │
└─────────────────────┘
     │
     ▼
Predicted Digit
```

---

## Hardware

**Target board:** Digilent Basys3
**FPGA:** Xilinx Artix-7 XC7A35T
**Clock:** 100 MHz
**HDL:** Verilog
**Development tool:** Xilinx Vivado

The design uses a simple sequential datapath rather than a highly parallel CNN architecture.

---

## CNN Architecture

The Version 1 network is intentionally small so that it can be implemented on the Basys3 FPGA.

```text
Input Image
28 × 28
   │
   ▼
Convolution
   │
   ▼
ReLU
   │
   ▼
Pooling
   │
   ▼
Fully Connected Layer
   │
   ▼
10 Output Classes
   │
   ▼
Predicted Digit
```

The exact layer dimensions and trained weights are stored in the project files.

---

## Fixed-Point / Integer Inference

The FPGA does not perform floating-point neural-network inference.

Instead, the model weights are quantized to **INT8**, and the hardware performs integer multiply-accumulate operations.

Conceptually:

```text
MAC = input × weight + accumulator
```

The accumulated value is then scaled and clamped before being passed to the next stage.

This significantly simplifies the hardware compared with implementing floating-point arithmetic.

### Important V1 limitation

The original training pipeline uses normalized MNIST pixels:

```text
0 → 1
```

while the FPGA receives image pixels as:

```text
0 → 255
```

Therefore, the software model and FPGA datapath must use the **same quantization/scaling convention** for reliable accuracy.

A bit-exact Python simulation is included to help validate the hardware arithmetic before programming the FPGA.

---

## Repository Structure

```text
basys3-cnn/
│
├── rtl/
│   ├── top.v
│   ├── conv_engine.v
│   ├── fc_engine.v
│   └── ...
│
├── constraints/
│   └── basys3.xdc
│
├── python/
│   ├── stream_to_fpga.py
│   ├── simulate_fixed_point.py
│   └── ...
│
├── weights/
│   └── ...
│
├── simulation/
│   └── ...
│
├── README.md
└── LICENSE
```

> File names may vary depending on the current repository structure.

---

## Hardware Architecture

The main CNN computation is divided into hardware modules.

### `top.v`

Top-level module that connects the CNN blocks, clock, reset, input interface, and output logic.

### `conv_engine.v`

Performs convolution using a sequential multiply-accumulate datapath.

The V1 implementation processes MAC operations one at a time rather than using a large parallel MAC array.

### `fc_engine.v`

Performs the fully connected layer and generates the class scores for the ten MNIST digits.

### Constraint File

`basys3.xdc` contains the FPGA pin assignments and timing constraints required for the Basys3 board.

---

## Software ↔ FPGA Flow

Python is used to prepare and communicate image data with the FPGA.

```text
MNIST Image
    │
    ▼
Python
    │
    ├── Resize / preprocess
    ├── Convert to integer pixels
    └── Send image
            │
            ▼
         Basys3
            │
            ▼
      CNN Hardware
            │
            ▼
      Predicted Digit
```

The Python scripts are also used for software-side validation and comparison with the FPGA result.

---

## Running the Fixed-Point Simulation

Before changing the FPGA design, the hardware arithmetic can be tested in software.

```bash
cd python
python simulate_fixed_point.py
```

The simulation reproduces the integer datapath used by the FPGA and can be used to test different scaling values.

For example:

```text
SHIFT = 0
SHIFT = 1
SHIFT = 2
...
SHIFT = 13
```

This helps identify a suitable scaling value before synthesizing the design.

---

## Building the FPGA Design

Open the project in **Vivado** and:

1. Add the Verilog RTL files.
2. Add `basys3.xdc`.
3. Verify the top module.
4. Run **Synthesis**.
5. Run **Implementation**.
6. Generate the bitstream.
7. Program the Basys3.

The design runs from the Basys3's 100 MHz clock.

---

## Version 1 Performance

The V1 architecture is intentionally simple.

The CPU implementation can be significantly faster because modern CPUs use:

* GHz-range clock frequencies
* SIMD/vector instructions
* Multiple execution units
* Highly optimized neural-network libraries

The V1 FPGA design instead uses a sequential MAC datapath at 100 MHz.

Therefore, **V1 is not intended to outperform a CPU**.

The primary goal is to demonstrate the complete path:

```text
Trained CNN
     ↓
Quantization
     ↓
Hardware Mapping
     ↓
Verilog RTL
     ↓
FPGA Synthesis
     ↓
Real Hardware Inference
```

---

## Known Limitations

### 1. Sequential computation

Only a small number of operations are performed in parallel.

This makes the design easier to understand but limits throughput.

### 2. Quantization sensitivity

The FPGA uses integer arithmetic, so scaling must match the trained model.

Incorrect input normalization or shift values can significantly reduce classification accuracy.

### 3. Limited optimization

V1 does not yet use an optimized MAC array, aggressive pipelining, DSP parallelism, or memory tiling.

### 4. CPU may be faster

This is expected for the current architecture and should not be considered the main performance target of V1.

---

## Debugging Highlights

Several issues encountered during development helped validate the complete hardware/software flow:

* Incorrect or empty FPGA constraint file
* Simulation/testbench timing issues
* Incorrect classification behavior
* CPU vs FPGA performance differences
* Input normalization mismatch
* Fixed-point scaling/quantization mismatch

The quantization mismatch was particularly important because the software model operated on normalized inputs while the FPGA received raw pixel values.

A **bit-exact fixed-point simulation** was added to make this type of hardware/software mismatch easier to identify.

---

## What V1 Demonstrates

This project demonstrates a complete, working workflow for implementing a neural-network inference engine on an FPGA:

* CNN model training
* Weight quantization
* Fixed-point arithmetic
* Verilog RTL design
* Convolution hardware
* Fully connected hardware
* FPGA synthesis and implementation
* Hardware/software communication
* Debugging hardware accuracy
* Validating RTL behavior against a software reference

---

## Future Work — V2

The next version can focus on **performance and resource optimization**.

Potential improvements:

* Parallel MAC array
* Pipelined convolution
* DSP slice utilization
* BRAM-based weight/input storage
* Better memory access patterns
* Multiple MACs per cycle
* Improved fixed-point quantization
* Hardware/software bit-exact validation
* Higher throughput
* Resource and timing optimization

The goal for V2 is to move from a **functional CNN accelerator** toward a more **parallel and performance-oriented FPGA architecture**.

---

## Project Goal

The goal of this project is not simply to run a neural network on an FPGA.

It is to understand what happens when a software CNN is translated into actual digital hardware:

> **Every multiplication, memory access, clock cycle, and quantization decision becomes a hardware design problem.**

Version 1 establishes that foundation.
