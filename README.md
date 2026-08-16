HDGL — FOUR-ELEMENT BARE-METAL Z[φ] SUBSTRATE WITH WU-WEI ORACLE
======
* TARGET:     x86-64 / BIOS / QEMU
* BUILD:      nasm -f bin hdgl_wuwei.asm -o hdgl_wuwei.img
* RUN:        qemu-system-x86_64 -drive format=raw,file=hdgl_wuwei.img -smp 4 -m 128M -boot c
* RUFUS makes burning bootable images (.img) very simple!

<img width="846" height="260" alt="image" src="https://github.com/user-attachments/assets/e465eae3-536a-474a-94ca-60e233946fd4" />

A multi-core, bare-metal x86-64 mathematical simulation environment written in raw assembly language. It bypasses any standard operating system to execute numeric algorithms directly on the processor hardware.

---

## 🚀 Quick Start

### Build Prerequisites
* **NASM** (Netwide Assembler)
* **QEMU** (Processor Emulator)

### Assembly and Execution Commands
```bash
# Compile the code into a raw 64-sector bootable image
nasm -f bin hdgl_wuwei.asm -o hdgl_wuwei.img

# Launch the bare-metal environment in QEMU simulating 4 CPU cores
qemu-system-x86_64 -drive format=raw,file=hdgl_wuwei.img -smp 4 -m 128M -boot c
```

---

## 🏗️ Boot Stages & System Lifecycle

The machine controls initialization sequentially, starting from basic hardware operations and progressing into standard modern architecture components:


<img width="666" height="416" alt="image" src="https://github.com/user-attachments/assets/b5a2b670-d74a-48dd-9561-30428e0ebf64" />

* **Milestone Indicators**: As the software passes initialization steps, it outputs markers directly onto the terminal layer (`B`, `T`, `A`, `G`, `P` during real-mode, and `1`, `2`, `3`, `4` upon protecting and paging).

---

## ☸️ System Architecture: The Four Core Elements

When multi-core processes are functional, the scheduler distributes evaluation tracks into separate physical logical threads, categorizing loops using natural design nomenclature:

* 🔥 **FIRE (CPU 0)**: The Central Operator. This component drives state counters, monitors state boundaries, schedules display loops, and sets logic branches.
* 💧 **WATER (CPU 1)**: Inverse Verification. This loop runs step algorithms in reverse to guarantee absolute state parity and guard against processor logic exceptions.
* 🪨 **EARTH (CPU 2)**: Pattern Matrix Oracle. This sector tracking code checks step boundaries based on the algebraic ring algorithm $N_\phi(a,b) = -a^2 + ab + b^2$.
* 🌬️ **WIND (CPU 3)**: Fixed-Point Residual Engine. This calculator models tracking error thresholds relative to the optimal mathematical golden ratio constant ($\phi$).

*Note: Multi-core worker bringing-up features are safely bypassed by default within the main source file to bypass legacy BIOS platform compatibility issues, running all routines cleanly inside a serial sequence on CPU 0.*

---

## ☯️ The Wu-Wei State Control Strategy

Adhering to the operational concepts of ancient philosophy (*"Wu-Wei"* or effortless alignment with tracking cycles), the infrastructure avoids classic crash traps. Structural variation points are identified as helpful metrics inside a bitfield status matrix (`ORACLE`).

The central manager analyzes status bits and immediately matches instructions to operational modes:

| Mode Index | State Strategy | Operational Behavior |
| :--- | :--- | :--- |
| **0x00** | `FLOWING RIVER` | Calculations are regular and uniform. Continue sequencing safely. |
| **0x02** | `NON-ACTION` | Variations identified within normal tracks. Pause state changes and log. |
| **0x04** | `REDIRECT` | Structural boundary values crossed. Rebase parameters to seed standards. |
| **0x08** | `CONVERGENCE` | Optimal algebraic matching confirmed. Log metrics and scale adjustments. |
| **0x80+** | `CRITICAL` | Severe processing anomaly. Halt processor operations and alert console layers. |

---

## 🕵️ Prime Extraction Engine (Iris Subsystem)

To optimize processing times during tracking loops, numerical properties are validated through a two-tiered hardware filter configuration:

1. **Iris Stutter-Step Adaptive Gate**: An efficient strong pseudoprime extraction mechanism utilizing a fixed-point constant pattern (`GOLDEN64`). It filters composite numbers quickly, avoiding complex math calculations on over 99% of variables.
2. **Two-Coefficient Frobenius Test**: Survivor metrics pass down into full modular fast doubling blocks (`modfib` and `zpow_mod`), filtering structural pseudoprimes with highly accurate parity validation steps.

<img width="490" height="664" alt="image" src="https://github.com/user-attachments/assets/af714e81-1a3d-46ef-82b0-416fe3147ee2" />
<img width="422" height="194" alt="image" src="https://github.com/user-attachments/assets/29c8be90-36b3-4843-bb3b-1e02d70e1431" />
<img width="662" height="700" alt="image" src="https://github.com/user-attachments/assets/bde75c2b-c9bc-4b4d-ba4b-bf2066e75f5b" />
<img width="675" height="501" alt="image" src="https://github.com/user-attachments/assets/0ecdb998-5834-4c37-8d1c-9bab4cf9db9d" />
<img width="673" height="624" alt="image" src="https://github.com/user-attachments/assets/167abe71-c496-4c3d-a108-1ebdd6a91edd" />
2. The Cryptographic Hunt: Dual-Gate CostsTesting every single iteration for prime candidates using big-integer math slows down performance dramatically on raw hardware. To preserve throughput, the engine implements strict structural pacing:


                            [ FIRE Loop Iteration ]
                                       │
                                       ▼
                       Is Iteration Counter (STATE_K) 
                        Divisible by 128 (Stride)?
                                  /         \
                                YES          NO
                                /             \
                               ▼               ▼
                ┌────────────────────────┐   ┌────────────────────────┐
                │ Run Prime Test Engine  │   │ Bypass Prime Engine    │
                │ (Compute Cost Applied) │   │ (Zero Overhead Applied)│
                └───────────┬────────────┘   └───────────┬────────────┘
                            │                            │
                            └────────────┬───────────────┘
                                         │
                                         ▼
                             [ Advance State Machine ]


By adding a throttling mask (test rax, 127), the compute cost is amortized across 128 baseline iterations, giving the system near-native baseline speeds [File: 4]. When a candidate lands on a stride tick, it runs through two nested gating architectures:Gate A: The Iris Pre-Filter (iris_prp_step)This filter drops over 99% of composite numbers at a highly optimized speed curve:Base Generation (iris_base): Costs exactly 2 standard integer multiplications (mul) to resolve a pseudo-random Weyl equidistribution base via GOLDEN64.Strong Pseudo-Prime Test (strong_sprp): Executes a plain scalar modular exponentiation loop (modpow_u64). In the worst-case scenario, this takes up to 16 sequential probes (IRIS_MAX_PROBES). Each probe runs a binary square-and-multiply loop that costs roughly \(\log_2(P)\) steps. Each step requires a heavy mul (128-bit product) and an div (64-bit hardware division) instruction.

<img width="676" height="640" alt="image" src="https://github.com/user-attachments/assets/6d39938b-a493-4d23-9b03-660430202fba" />
<img width="673" height="197" alt="image" src="https://github.com/user-attachments/assets/0bcb3b10-7ff3-4b92-8a42-291db940c858" />

```
                       True Mathematical Value (Exceeds 64-bits)
                                      │
                                      ▼
             1 ┌────────────────────────────────────────────────┐
               │ 00000000 00000000 00000000 00000000 000005C2 │ (Dropped Lower Data)
               └────────────────────────────────────────────────┘
               ▲
               │
       [ Hardware Carry Flag (CF = 1) ] -> Ignored by native 'add' instruction
```

<img width="642" height="122" alt="image" src="https://github.com/user-attachments/assets/29ddb4b4-d739-4a94-9fbb-da80b4b4e573" />
<img width="668" height="563" alt="image" src="https://github.com/user-attachments/assets/718e93af-3f8a-46eb-80bc-8f1bc39be88f" />



YOU MUST AGREE TO COPYRIGHT LICENSING FOR COMMERICAL USE OF ANY KIND!  PERSONAL USE IS ALSO VERY LIMITED!  JUST PAY ME FOR MY WORK!  DEMO ONLY!

https://zchg.org/t/legal-notice-copyright-applicable-ip-and-licensing-read-me/440
