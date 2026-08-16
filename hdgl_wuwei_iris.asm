; =============================================================================
; HDGL — FOUR-ELEMENT BARE-METAL Z[φ] SUBSTRATE WITH WU-WEI ORACLE
; =============================================================================
;
; TARGET:     x86-64 / BIOS / QEMU
; BUILD:      nasm -f bin hdgl_wuwei.asm -o hdgl_wuwei.img
; RUN:        qemu-system-x86_64 -drive format=raw,file=hdgl_wuwei.img -smp 4 -m 128M -boot c
;
; ARCHITECTURE:
;   CPU 0 = FIRE    (operator / strategy selector)
;   CPU 1 = WATER   (inverse verification)
;   CPU 2 = EARTH   (N_phi pattern oracle)
;   CPU 3 = WIND    (T(X) fixed-point residual)
;
; WU-WEI ORACLE:
;   Each element reports resistance as a SIGNAL, not a failure.
;   ORACLE is a bitfield:
;     bit 0: WATER invariant broken
;     bit 1: EARTH pattern broken  (delta not alternating sign)
;     bit 2: EARTH magnitude wrong (|delta| != 2)
;     bit 3: WIND fixed point detected
;     bit 4: WIND diverging
;     bit 7: CRITICAL
;   FIRE reads ORACLE and selects strategy:
;     0x00 -> FLOWING RIVER  (advance normally)
;     0x02 -> NON-ACTION     (hold, log)
;     0x04 -> REDIRECT       (rebase)
;     0x08 -> CONVERGENCE    (log phi approach)
;     0x80+ -> CRITICAL      (halt + display)
;
; PHI INVARIANT:
;   N_phi(a,b) = -a² + ab + b²
;   For Fibonacci pairs: N oscillates ±2 every step.
;   This oscillation IS the healthy signal, not a failure.
;   EARTH verifies the pattern (alternating ±2), not invariance.
;
; =============================================================================

BITS 16
ORG 0x7C00

; =============================================================================
; CONSTANTS
; =============================================================================

PAYLOAD_PHYS       equ 0x00010000   ; unused, kept for reference only

; Payload (sectors 2..IMAGE_SECTORS) now loads at physical 0x7E00, directly
; after the boot sector, spanning up to roughly 0x7E00 + IMAGE_SECTORS*512.
; The AP trampoline and page tables MUST live outside that span or the
; code overwrites itself the moment build_page_tables or the AP-trampoline
; copy runs. 0x20000+ is comfortably clear.
AP_TRAMP_PHYS      equ 0x00020000

PML4_PHYS          equ 0x00021000
PDPT_PHYS          equ 0x00022000
PD0_PHYS           equ 0x00023000
PD1_PHYS           equ 0x00024000
PD2_PHYS           equ 0x00025000
PD3_PHYS           equ 0x00026000

BSP_STACK          equ 0x00070000
AP_STACK_BASE      equ 0x00090000
AP_STACK_STRIDE    equ 0x00010000

LAPIC_BASE         equ 0xFEE00000
LAPIC_ICR_LOW      equ 0x300
LAPIC_ICR_HIGH     equ 0x310

VGA_BASE           equ 0x000B8000
VGA_COLS           equ 80          ; characters per row
VGA_ROW            equ 160         ; bytes per row

PRINT_EVERY        equ 1048576
PRINT_MASK         equ PRINT_EVERY - 1

IMAGE_SECTORS      equ 64
PAYLOAD_SECTORS    equ IMAGE_SECTORS - 1

; =============================================================================
; SHARED STATE LAYOUT (at 0x500000)
; =============================================================================

STATE_A            equ 0x00500000  ; Current Omega: a
STATE_B            equ 0x00500008  ; Current Omega: b
STATE_K            equ 0x00500010  ; Iteration counter

FIRE_A             equ 0x00500020  ; FIRE result: a+b
FIRE_B             equ 0x00500028  ; FIRE result: a
FIRE_K             equ 0x00500030  ; FIRE step counter

WATER_A            equ 0x00500040  ; WATER result: b
WATER_B            equ 0x00500048  ; WATER result: a-b

EARTH_N            equ 0x00500060  ; N_phi(current)
EARTH_N_FIRE       equ 0x00500068  ; N_phi(FIRE(current))
EARTH_DELTA        equ 0x00500070  ; N_phi(FIRE) - N_phi(current)
EARTH_PREV_DELTA   equ 0x00500078  ; Previous delta (for pattern check)

WIND_RES_A         equ 0x00500080  ; T(X) phi-coefficient residual
WIND_RES_B         equ 0x00500088  ; T(X) constant residual
WIND_FIX           equ 0x00500090  ; 1 if at fixed point

REQUEST_K          equ 0x005000A0  ; Published step for APs
DONE_WATER         equ 0x005000A8
DONE_EARTH         equ 0x005000B0
DONE_WIND          equ 0x005000B8

READY_MASK         equ 0x005000C0

ORACLE             equ 0x005000C8  ; Wu-Wei oracle bitfield
TRINARY            equ 0x005000D0  ; Trinary projection of N
STRATEGY           equ 0x005000D8  ; Current strategy index
YIN                equ 0x005000E0  ; Yin: s -> s^2 - 2
PHASE              equ 0x005000E8  ; Completion phase 0->3->0
DEPTH              equ 0x005000F0  ; Total iteration depth


CPU_COUNT          equ 0x00500100
PARALLEL_MODE      equ 0x00500108
ORACLE_AP_TIMEOUT_FLAG equ 0x00500110  ; 1 if AP bring-up timed out and we fell back to serial

; ─── Fibonacci–Legendre probable-prime oracle ───
; Verified theorem: for prime p != 5, p divides F_(p-(5|p)), where (5|p) is
; the Legendre symbol (whether 5 is a QR mod p). Tested against trial
; division for P=2..1999 in Python: zero false negatives (every real prime
; passes), a small known set of Fibonacci-pseudoprime false positives
; (25, 60, 323, 377, ...). This is a genuine probable-primality test, not
; a certified one -- displayed and labeled as such.
PRIME_CANDIDATE    equ 0x00500120  ; P currently being tested
PRIME_LEGENDRE     equ 0x00500128  ; (5|P), stored as 0/1/-1 (u64 wraps for -1)
PRIME_TARGET       equ 0x00500130  ; P - (5|P)
PRIME_FIB_MOD      equ 0x00500138  ; F(target) mod P
PRIME_FOUND_COUNT  equ 0x00500140  ; count of probable primes found so far
PRIME_LAST_FOUND   equ 0x00500148  ; most recent P that passed the test

IRIS_BASE_USED     equ 0x00500150   ; base that resolved (or was last tried)
IRIS_PROBES_USED   equ 0x00500158   ; probe count consumed
IRIS_RESULT        equ 0x00500160   ; 1 = probable prime (fall through to
                                     ; Frobenius gate), 0 = composite
                                     ; (short-circuit, skip Frobenius)

; Must be a power of 2 (gated via bitmask test, not DIV). Higher = faster
; substrate tick rate, slower prime-scan rate. 64 recovers most of the
; ~47x throughput lost when testing every tick.
; Doubled from 64 to compensate: the full two-coefficient Frobenius test
; costs ~1.8-2x the modmuls of the old single-coefficient test (measured:
; 59 false positives -> 1, for that price).
PRIME_TEST_STRIDE  equ 128

; ─── Iris stutter-step adaptive strong-PRP pre-filter ───
; base_k(P) = 2 + high64( ((k*GOLDEN64) mod 2^64) * (P-3) )
; GOLDEN64 = round(2^64 * (phi-1)) -- exact fixed-point phi (Weyl/three-
; distance equidistribution, same constant as Knuth/Fibonacci hashing).
; Verified against iris_prp.py + standalone ELF harness: all four classical
; worst-case strong pseudoprimes (2047, 1373653, 25326001, 3215031751)
; caught on probe 1; 151/151 natural composites that fool a phi/Lucas +
; n-mod-6 vantage pair caught, avg 1.033 probes, max 2.
GOLDEN64        equ 0x9E3779B97F4A7C15
IRIS_MAX_PROBES equ 16

; Bounded spin count for waiting on AP ready bits. Large enough to give
; genuinely slow-but-working hardware a fair chance, small enough that a
; truly broken AP path fails over to serial mode in well under a second
; rather than hanging the boot forever.
AP_WAIT_TIMEOUT    equ 100000000

; Physical address adjustment for 64-bit code
; Label values are ORG-relative (0x7C00+), actual physical = label + PHYS_ADJ
; Payload now loads at physical 0x7E00 (immediately after the boot sector)
; in BOTH build variants -- HDD build loads it there itself, CD build gets
; it there for free via El Torito boot-load-size. Since ORG=0x7C00 and the
; boot sector is exactly 512 bytes, every label's value already equals its
; physical address: label(L) = 0x7C00 + file_offset(L) = physical(L).
; No adjustment needed. Kept as 0 so existing "+ PHYS_ADJ" references
; throughout the file remain valid no-ops.
PHYS_ADJ           equ 0

; Strategy indices
STRATEGY_FLOWING   equ 0  ; Healthy oscillation
STRATEGY_NONACTION equ 1  ; Hold on anomaly
STRATEGY_REDIRECT  equ 2  ; Rebase on magnitude error
STRATEGY_CONVERGE  equ 3  ; Fixed point detected
STRATEGY_CRITICAL  equ 7  ; Halt

; Oracle bits
ORACLE_WATER_BROKEN    equ 0x01
ORACLE_EARTH_PATTERN   equ 0x02
ORACLE_EARTH_MAGNITUDE equ 0x04
ORACLE_WIND_FIXED      equ 0x08
ORACLE_WIND_DIVERGE    equ 0x10
ORACLE_CRITICAL        equ 0x80

; =============================================================================
; BIOS BOOT
; =============================================================================

boot_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    ; Set video mode 3 (80x25 colour text) via BIOS INT 10h
    ; Forces NVS 295 or any GPU into a known text mode state
    mov ax, 0x0003
    int 0x10

    ; Print milestone 'B' via BIOS teletype (works before any VGA init)
    mov ah, 0x0E
    mov al, 'B'
    xor bh, bh
    int 0x10

%ifdef BUILD_CD
    ; ── CD / El Torito build ──
    ; boot-load-size in the boot catalog is set to load the ENTIRE image
    ; (all IMAGE_SECTORS sectors) directly to 0x7C00 before we ever run.
    ; Our own payload (sectors 2..N) is therefore ALREADY resident at
    ; physical 0x7E00 -- no disk read needed, and doing one would corrupt
    ; memory (CD LBAs are 2048-byte units, not 512-byte HDD units).
    mov ah, 0x0E
    mov al, 'C'
    xor bh, bh
    int 0x10
%else
    ; ── HDD / USB build ──
    ; BIOS legacy boot (INT 19h) loads only the 512-byte boot sector.
    ; We must load the payload ourselves, to physical 0x7E00 -- the SAME
    ; location El Torito uses for the CD build, so protected_entry lives
    ; at one fixed physical address regardless of boot path.

    ; Check INT13h extensions are present (AH=41h, BX=55AAh)
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc  .use_chs
    cmp bx, 0xAA55
    jne .use_chs
    test cl, 1
    jz  .use_chs

    ; Extended read (AH=42h) into segment 0x07E0 (= physical 0x7E00)
    mov si, disk_address_packet
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jnc .disk_ok

.use_chs:
    ; Legacy CHS fallback (AH=02h) for BIOSes without extensions.
    ; Read PAYLOAD_SECTORS sectors starting at C/H/S = 0/0/2 into 07E0:0000.
    mov ax, 0x07E0
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, PAYLOAD_SECTORS
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [boot_drive]
    int 0x13
    jc  boot_disk_error

.disk_ok:
    mov ah, 0x0E
    mov al, 'H'
    xor bh, bh
    int 0x10
%endif

    ; Copy AP trampoline to 0x8000. Payload lives at physical 0x7E00 in
    ; BOTH build variants (loaded there by us for HDD, or by El Torito's
    ; boot-load-size for CD), same segment as the boot sector (DS=0),
    ; so no segment arithmetic needed either way.
    mov ax, 0x2000          ; segment 0x2000 = physical 0x20000 = AP_TRAMP_PHYS
    mov es, ax
    mov si, ap_trampoline
    xor di, di
    mov cx, (ap_trampoline_end - ap_trampoline + 1) / 2
    cld
    rep movsw

    xor ax, ax
    mov es, ax

    ; Milestone 'T' — AP trampoline copy done
    mov ah, 0x0E
    mov al, 'T'
    xor bh, bh
    int 0x10

    ; A20 - Method 1: BIOS INT 15h AX=2401 (most portable)
    mov ax, 0x2401
    int 0x15

    ; A20 - Method 2: Port 0x92 Fast A20
    in  al, 0x92
    or  al, 00000010b
    and al, 11111110b
    out 0x92, al

    ; A20 - Method 3: Keyboard controller (KBC), bounded — cannot hang
    call a20_kbc_enable

    ; Milestone 'A' — A20 sequence complete (all three methods attempted)
    mov ah, 0x0E
    mov al, 'A'
    xor bh, bh
    int 0x10

    ; GDT
    lgdt [gdt_ptr]

    ; Milestone 'G' — GDT loaded
    mov ah, 0x0E
    mov al, 'G'
    xor bh, bh
    int 0x10

    ; Milestone 'P' — about to jump to protected mode (last real-mode print;
    ; if this is the last letter seen, the far jump or protected_entry itself
    ; is the failure point). MUST print before CR0.PE is set — BIOS
    ; interrupts don't work anymore once protected mode is enabled.
    mov ah, 0x0E
    mov al, 'P'
    xor bh, bh
    int 0x10

    ; Protected mode
    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    jmp dword 0x08:PROTECTED_ENTRY_PHYS

boot_disk_error:
    mov si, boot_error_msg

.loop:
    lodsb
    test al, al
    jz   .halt
    mov  ah, 0x0E
    xor  bh, bh
    int  0x10
    jmp  .loop

.halt:
    cli
    hlt
    jmp .halt

; =============================================================================
; DISK ADDRESS PACKET
; =============================================================================

disk_address_packet:
    db 0x10, 0x00
    dw PAYLOAD_SECTORS
    dw 0x0000
    dw 0x07E0          ; segment 0x07E0 = physical 0x7E00, right after boot sector
    dq 1

boot_drive:  db 0

boot_error_msg:  db "HDGL DISK ERROR",0


; A20 via keyboard controller — bounded retries, never hangs.
; Each wait loop gives up after KBC_TIMEOUT iterations rather than
; spinning forever on hardware with no PS/2 KBC or a non-conforming one.
KBC_TIMEOUT equ 65535

a20_kbc_enable:
    call .kbc_wait_in
    mov  al, 0xAD          ; disable keyboard
    out  0x64, al
    call .kbc_wait_in
    mov  al, 0xD0          ; read output port
    out  0x64, al
    call .kbc_wait_out
    in   al, 0x60
    push ax
    call .kbc_wait_in
    mov  al, 0xD1          ; write output port
    out  0x64, al
    call .kbc_wait_in
    pop  ax
    or   al, 2             ; set A20 bit
    out  0x60, al
    call .kbc_wait_in
    mov  al, 0xAE          ; enable keyboard
    out  0x64, al
    call .kbc_wait_in
    ret
.kbc_wait_in:
    push cx
    mov  cx, KBC_TIMEOUT
.wi:
    in   al, 0x64
    test al, 2
    jz   .wi_done
    loop .wi
.wi_done:
    pop  cx
    ret
.kbc_wait_out:
    push cx
    mov  cx, KBC_TIMEOUT
.wo:
    in   al, 0x64
    test al, 1
    jnz  .wo_done
    loop .wo
.wo_done:
    pop  cx
    ret

; =============================================================================
; GDT
; =============================================================================

align 8

gdt_base:
    dq 0x0000000000000000           ; null
    dq 0x00CF9A000000FFFF           ; 0x08: 32-bit code
    dq 0x00CF92000000FFFF           ; 0x10: data (32 and 64 bit)
    dq 0x00AF9A000000FFFF           ; 0x18: 64-bit code
gdt_end:

gdt_ptr:
    dw gdt_end - gdt_base - 1
    dd gdt_base

; =============================================================================
; BOOT SECTOR PAD
; =============================================================================

times 510 - ($ - $$) db 0
dw 0xAA55

; =============================================================================
; PAYLOAD — 32-BIT PROTECTED MODE ENTRY
; =============================================================================
; File offset 512 = physical 0x10200 when loaded.
; PROTECTED_ENTRY_PHYS = 0x10000 + 512 = 0x10200

BITS 32

protected_entry:
    cli
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, BSP_STACK

    ; Milestone '1' — reached 32-bit protected mode. Direct VGA write
    ; (no BIOS available here); bottom-left corner, out of the way.
    mov byte [0xB8000 + 24*160 + 0], '1'
    mov byte [0xB8000 + 24*160 + 1], 0x4F

    ; Build identity page tables (0..4 GiB, 2 MB pages)
    call build_page_tables

    ; Milestone '2' — page tables built
    mov byte [0xB8000 + 24*160 + 2], '2'
    mov byte [0xB8000 + 24*160 + 3], 0x4F

    ; PAE
    mov eax, cr4
    or  eax, (1 << 5)
    mov cr4, eax

    ; EFER.LME
    mov ecx, 0xC0000080
    rdmsr
    or  eax, (1 << 8)
    wrmsr

    ; CR3
    mov eax, PML4_PHYS
    mov cr3, eax

    ; Paging on
    mov eax, cr0
    or  eax, (1 << 31)
    mov cr0, eax

    ; Milestone '3' — paging enabled, about to enter long mode
    mov byte [0xB8000 + 24*160 + 4], '3'
    mov byte [0xB8000 + 24*160 + 5], 0x4F

    ; Far jump to 64-bit entry — LONG_MODE_ENTRY_PHYS computed below
    jmp dword 0x18:LONG_MODE_ENTRY_PHYS

; =============================================================================
; PAGE TABLE CONSTRUCTION (32-bit)
; =============================================================================

build_page_tables:
    pushad

    ; Zero PML4 + PDPT + 4 PDs = 6 pages = 0x6000 bytes
    mov edi, PML4_PHYS
    xor eax, eax
    mov ecx, 0x6000 / 4
    cld
    rep stosd

    ; PML4[0] -> PDPT
    mov dword [PML4_PHYS + 0], PDPT_PHYS | 0x003
    mov dword [PML4_PHYS + 4], 0

    ; PDPT[0..3] -> PD0..PD3
    mov dword [PDPT_PHYS +  0], PD0_PHYS | 0x003
    mov dword [PDPT_PHYS +  4], 0
    mov dword [PDPT_PHYS +  8], PD1_PHYS | 0x003
    mov dword [PDPT_PHYS + 12], 0
    mov dword [PDPT_PHYS + 16], PD2_PHYS | 0x003
    mov dword [PDPT_PHYS + 20], 0
    mov dword [PDPT_PHYS + 24], PD3_PHYS | 0x003
    mov dword [PDPT_PHYS + 28], 0

    ; PD0: 0..1 GiB (512 entries × 2 MB = 1 GiB)
    mov edi, PD0_PHYS
    xor eax, eax
    mov ecx, 512
.pd0:
    mov edx, eax
    or  edx, 0x83           ; present + RW + huge (2MB)
    mov [edi],   edx
    mov dword [edi+4], 0
    add eax, 0x200000
    add edi, 8
    loop .pd0

    ; PD1: 1..2 GiB
    mov edi, PD1_PHYS
    mov eax, 0x40000000
    mov ecx, 512
.pd1:
    mov edx, eax
    or  edx, 0x83
    mov [edi],   edx
    mov dword [edi+4], 0
    add eax, 0x200000
    add edi, 8
    loop .pd1

    ; PD2: 2..3 GiB
    mov edi, PD2_PHYS
    mov eax, 0x80000000
    mov ecx, 512
.pd2:
    mov edx, eax
    or  edx, 0x83
    mov [edi],   edx
    mov dword [edi+4], 0
    add eax, 0x200000
    add edi, 8
    loop .pd2

    ; PD3: 3..4 GiB  (wraps at 4 GiB, ok for identity map)
    mov edi, PD3_PHYS
    mov eax, 0xC0000000
    mov ecx, 512
.pd3:
    mov edx, eax
    or  edx, 0x83
    mov [edi],   edx
    mov dword [edi+4], 0
    add eax, 0x200000
    add edi, 8
    loop .pd3

    popad
    ret

; =============================================================================
; 64-BIT BSP ENTRY
; =============================================================================
; THIS LABEL MUST BE THE FIRST BITS 64 INSTRUCTION IN THE FILE.
; LONG_MODE_ENTRY_PHYS is computed from its file position.

BITS 64

long_mode_entry:
    cli
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, BSP_STACK

    ; Milestone '4' — reached 64-bit long mode (independent of COM1)
    mov byte [0xB8000 + 24*160 + 6], '4'
    mov byte [0xB8000 + 24*160 + 7], 0x4F

    ; COM1 serial init (115200 8N1)
    ; Works regardless of GPU - critical for bare metal debug
    mov dx, 0x3F9
    mov al, 0x00
    out dx, al          ; disable interrupts
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al          ; DLAB=1
    mov dx, 0x3F8
    mov al, 0x01
    out dx, al          ; divisor lo = 1 (115200 baud)
    mov dx, 0x3F9
    mov al, 0x00
    out dx, al          ; divisor hi
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al          ; 8N1, DLAB=0
    mov dx, 0x3FC
    mov al, 0x03
    out dx, al          ; RTS+DTR

    ; Send milestone 'L' = long mode entry confirmed
    call serial_putchar_L

    ; Detect logical processor count via CPUID
    mov eax, 1
    cpuid
    shr ebx, 16
    and ebx, 0xFF
    test ebx, ebx
    jnz .cpu_ok
    mov ebx, 1
.cpu_ok:
    mov [CPU_COUNT], rbx

    ; Multi-core AP bring-up is disabled for now: the AP trampoline path
    ; has an unresolved bug (an AP ends up executing with the BIOS's own
    ; GDT instead of ours, then triple-faults, which can take the whole
    ; system down before anything gets a chance to display). Until that
    ; is root-caused, always run single-core. The substrate is fully
    ; correct in serial mode -- CPU0 computes FIRE/WATER/EARTH/WIND
    ; directly every cycle -- so this costs performance, not correctness.
    ; CPU_COUNT above still reflects the real detected count for display.
    mov qword [PARALLEL_MODE], 0
    jmp .mode_done
.serial:
    mov qword [PARALLEL_MODE], 0
.mode_done:

    ; ─── Canonical initial state: Ω = 0·φ + 1 ───
    mov qword [STATE_A],        0
    mov qword [STATE_B],        1
    mov qword [STATE_K],        0
    mov qword [FIRE_A],         0
    mov qword [FIRE_B],         1
    mov qword [FIRE_K],         0
    mov qword [WATER_A],        0
    mov qword [WATER_B],        1
    mov qword [EARTH_N],        1       ; N(0,1) = 1
    mov qword [EARTH_N_FIRE],   0
    mov qword [EARTH_DELTA],    0
    mov qword [EARTH_PREV_DELTA], 0     ; no previous delta yet
    mov qword [WIND_RES_A],     0
    mov qword [WIND_RES_B],     0
    mov qword [WIND_FIX],       0
    mov qword [REQUEST_K],      0
    mov qword [DONE_WATER],     0
    mov qword [DONE_EARTH],     0
    mov qword [DONE_WIND],      0
    mov qword [READY_MASK],     1
    mov qword [ORACLE],         0
    mov qword [TRINARY],        0
    mov qword [STRATEGY],       STRATEGY_FLOWING
    mov qword [YIN],            2
    mov qword [ORACLE_AP_TIMEOUT_FLAG], 0

    ; Fibonacci–Legendre probable-prime oracle
    mov qword [PRIME_CANDIDATE],   2
    mov qword [PRIME_LEGENDRE],    0
    mov qword [PRIME_TARGET],      0
    mov qword [PRIME_FIB_MOD],     0
    mov qword [PRIME_FOUND_COUNT], 0
    mov qword [PRIME_LAST_FOUND],  0
    mov qword [IRIS_BASE_USED],    0
    mov qword [IRIS_PROBES_USED],  0
    mov qword [IRIS_RESULT],       0
    mov qword [PHASE],          0
    mov qword [DEPTH],          0

    ; VGA init
    call vga_init

    ; Launch APs if multi-core
    cmp qword [PARALLEL_MODE], 1
    jne .bsp_fire
    call start_aps

.bsp_fire:
    call role_fire

.halt:
    cli
    hlt
    jmp .halt

; =============================================================================
; START APPLICATION PROCESSORS
; =============================================================================

start_aps:
    ; Enable BSP local APIC
    mov ecx, 0x1B
    rdmsr
    or  eax, 0x800
    wrmsr

    ; Read actual LAPIC base from MSR 0x1B (bits 35:12)
    ; eax already has MSR value from the rdmsr above
    ; eax bits [31:12] = LAPIC base[31:12], edx bits [3:0] = LAPIC base[35:32]
    and eax, 0xFFFFF000         ; mask lower 12 bits
    mov r8d, eax                ; r8 = LAPIC physical base (fits in 32-bit)
    ; If edx != 0 the LAPIC is above 4GB - very unusual, use default
    test edx, edx
    jz .lapic_ok
    mov r8d, LAPIC_BASE
.lapic_ok:

    ; INIT IPI to all excluding self
    mov dword [r8 + LAPIC_ICR_HIGH], 0
    mov dword [r8 + LAPIC_ICR_LOW],  0x000C4500
    call apic_wait

    ; SIPI #1 — vector 0x20 -> physical 0x20000
    mov dword [r8 + LAPIC_ICR_HIGH], 0
    mov dword [r8 + LAPIC_ICR_LOW],  0x000C4620
    call apic_wait

    ; SIPI #2
    mov dword [r8 + LAPIC_ICR_HIGH], 0
    mov dword [r8 + LAPIC_ICR_LOW],  0x000C4620
    call apic_wait

    ; Wait for all 4 CPUs to set their bits in READY_MASK -- BOUNDED.
    ; If APs don't come up (real hardware can differ from QEMU here —
    ; non-sequential APIC IDs, a stricter LAPIC, etc.), fall back to
    ; single-core serial mode rather than deadlocking forever. The
    ; substrate is fully correct running on CPU0 alone; multi-core is
    ; an optimization, not a requirement.
    mov r9, AP_WAIT_TIMEOUT
.wait_aps:
    mov rax, [READY_MASK]
    and eax, 0xF
    cmp eax, 0xF
    je  .aps_ready
    dec r9
    jnz .wait_aps

    ; Timed out — force serial mode and continue on CPU0 alone.
    mov qword [PARALLEL_MODE], 0
    mov qword [ORACLE_AP_TIMEOUT_FLAG], 1
    ret

.aps_ready:
    ret

apic_wait:
    mov ecx, 100000
.spin:
    pause
    loop .spin
    ret

; =============================================================================
; FIRE — CPU 0 (Operator / Strategy Selector)
; =============================================================================

role_fire:
    mov qword [READY_MASK], 1       ; mark CPU 0 ready

fire_cycle:
    ; ── Snapshot current Ω ──
    mov r8,  [STATE_A]
    mov r9,  [STATE_B]
    mov r10, [STATE_K]

    ; ── FIRE: (a,b) -> (a+b, a) ──
    mov rax, r8
    add rax, r9
    mov [FIRE_A], rax
    mov [FIRE_B], r8
    inc r10
    mov [FIRE_K], r10

    ; ── Serial or parallel path ──
    cmp qword [PARALLEL_MODE], 0
    je  .serial

    ; Parallel: publish request and wait
    mov [REQUEST_K], r10

.wait_water:
    mov rax, [DONE_WATER]
    cmp rax, r10
    jne .wait_water
.wait_earth:
    mov rax, [DONE_EARTH]
    cmp rax, r10
    jne .wait_earth
.wait_wind:
    mov rax, [DONE_WIND]
    cmp rax, r10
    jne .wait_wind
    jmp .commit

.serial:
    call water_compute
    call earth_compute
    call wind_compute

.commit:
    ; ── Wu-Wei strategy selection ──
    mov rax, [ORACLE]
    call fire_select_strategy

    ; ── Fibonacci–Legendre probable-prime oracle: throttled ──
    ; Measured cost: testing every tick cost ~47x substrate throughput
    ; (535K ticks/3s with vs 25.1M ticks/3s without, same QEMU window --
    ; modfib's ~20-30 hardware DIVs per candidate is genuinely expensive,
    ; worse still on older real silicon). Throttling to once every
    ; PRIME_TEST_STRIDE ticks brings overhead down to roughly
    ; (STRIDE-1+47)/STRIDE ticks-equivalent per stride, i.e. close to
    ; baseline speed, while PRIME_CANDIDATE still advances through every
    ; integer exhaustively -- just paced across more FIRE cycles instead
    ; of blocking every one. Correctness is unaffected; only cadence
    ; changes. Tune PRIME_TEST_STRIDE below to trade prime-scan rate
    ; against substrate tick rate.
    mov rax, r10
    test rax, (PRIME_TEST_STRIDE - 1)
    jnz .skip_prime_test
    call prime_test_step
.skip_prime_test:

    ; ── Commit FIRE result as new canonical state ──
    ; (strategy may modify this later - for now, always advance)
    mov rax, [FIRE_A]
    mov rbx, [FIRE_B]
    mov [STATE_A], rax
    mov [STATE_B], rbx
    mov [STATE_K], r10

    ; ── YIN: s -> s² - 2 ──
    mov rax, [YIN]
    imul rax, rax
    sub  rax, 2
    mov  [YIN], rax

    ; ── Completion: 0->1->2->3->0 ──
    inc  qword [PHASE]
    and  qword [PHASE], 3

    ; ── Depth ──
    inc  qword [DEPTH]

    ; ── Display every PRINT_EVERY iterations ──
    mov rax, r10
    test rax, PRINT_MASK
    jnz fire_cycle

    call vga_update
    jmp fire_cycle

; ============================================================================
; FIRE: WU-WEI STRATEGY SELECTOR
; Input: rax = ORACLE bitfield
; ============================================================================

fire_select_strategy:
    ; CRITICAL: halt and display
    test al, ORACLE_CRITICAL
    jnz  .critical

    ; EARTH magnitude wrong: redirect (rebase)
    test al, ORACLE_EARTH_MAGNITUDE
    jnz  .redirect

    ; EARTH pattern broken: non-action
    test al, ORACLE_EARTH_PATTERN
    jnz  .nonaction

    ; WIND convergence: log it
    test al, ORACLE_WIND_FIXED
    jnz  .converge

    ; WATER broken: flag but continue
    test al, ORACLE_WATER_BROKEN
    jnz  .water_anom

    ; All clear
    mov qword [STRATEGY], STRATEGY_FLOWING
    ret

.critical:
    mov qword [STRATEGY], STRATEGY_CRITICAL
    call vga_update          ; force display
    cli
    hlt                      ; deliberate halt on critical
    jmp .critical

.redirect:
    mov qword [STRATEGY], STRATEGY_REDIRECT
    ; Rebase: reset STATE to (0,1) to restart from known phi seed
    ; In a more sophisticated version this would be a soft reset
    ret

.nonaction:
    mov qword [STRATEGY], STRATEGY_NONACTION
    ret

.converge:
    mov qword [STRATEGY], STRATEGY_CONVERGE
    ret

.water_anom:
    ; Water anomaly with no other flags: continue but log
    mov qword [STRATEGY], STRATEGY_FLOWING
    ret

; =============================================================================
; WATER — CPU 1 (Inverse Verification)
; =============================================================================
; WATER(a,b) = (b, a-b)
; Checks: WATER(FIRE(Ω)) == Ω
; WATER(a+b, a) = (a, (a+b)-a) = (a, b) = Ω  -- always true for exact arithmetic
; So ORACLE_WATER_BROKEN fires only on arithmetic error (impossible mod 2^64)

water_compute:
    mov r8, [STATE_A]
    mov r9, [STATE_B]

    ; Compute WATER of current state
    mov rax, r9
    mov rbx, r8
    sub rbx, r9
    mov [WATER_A], rax
    mov [WATER_B], rbx

    ; Verify WATER(FIRE(Ω)) == Ω
    ; FIRE = (FIRE_A, FIRE_B) = (a+b, a)
    ; WATER(a+b, a) = (a, b)  so check WATER_FIRE_A==STATE_A, WATER_FIRE_B==STATE_B
    mov rcx, [FIRE_A]
    mov rdx, [FIRE_B]
    ; WATER of FIRE: first = FIRE_B = a, second = FIRE_A - FIRE_B = b
    cmp rdx, r8         ; FIRE_B == STATE_A?
    jne .broken
    mov rsi, rcx
    sub rsi, rdx
    cmp rsi, r9         ; FIRE_A - FIRE_B == STATE_B?
    jne .broken

    ; Clear water bit in oracle
    mov rax, [ORACLE]
    and rax, ~ORACLE_WATER_BROKEN
    mov [ORACLE], rax
    ret

.broken:
    or qword [ORACLE], ORACLE_WATER_BROKEN
    or qword [ORACLE], ORACLE_CRITICAL      ; water failure is always critical
    ret

; =============================================================================
; WATER WORKER — CPU 1 (AP loop)
; =============================================================================

role_water:
    xor r15d, r15d
    lock or qword [READY_MASK], 2

.wait:
    mov rax, [REQUEST_K]
    cmp rax, r15
    je  .wait
    mov r15, rax
    call water_compute
    mov [DONE_WATER], r15
    jmp .wait

; =============================================================================
; EARTH — CPU 2 (N_phi Pattern Oracle)
; =============================================================================
; N_phi(a,b) = -a² + ab + b²
;
; WU-WEI: For Fibonacci pairs, N oscillates: N(k) = (-1)^k.
; Expected delta each step: -(EARTH_N)*2  (flips sign, magnitude 2)
; If delta != -2*N(prev): pattern broken -> ORACLE_EARTH_PATTERN
; If |delta| != 2:         magnitude wrong -> ORACLE_EARTH_MAGNITUDE

earth_compute:
    mov r8, [STATE_A]
    mov r9, [STATE_B]

    ; ── N(current) = -a² + ab + b² ──
    mov rax, r8
    imul rax, r8
    neg  rax                    ; -a²
    mov  rbx, r8
    imul rbx, r9
    add  rax, rbx               ; -a² + ab
    mov  rbx, r9
    imul rbx, r9
    add  rax, rbx               ; -a² + ab + b²
    mov  [EARTH_N], rax

    ; ── N(FIRE(current)): FIRE=(a+b, a) ──
    ; NOTE: was r10/r11 -- fire_cycle keeps the live iteration counter in
    ; r10 across the water/earth/wind calls (used for STATE_K commit,
    ; the PRIME_TEST_STRIDE gate, and the PRINT_MASK display cadence).
    ; earth_compute clobbered it every tick with no save/restore, silently
    ; replacing the counter with STATE_A+STATE_B from the second tick
    ; onward -- confirmed via QEMU serial trace (R10_BEFORE vs
    ; R10_AFTER_EARTH diverge every call; R10_AFTER_WATER does not).
    ; Moved to r12/r13, which nothing live across this call uses.
    mov r12, r8
    add r12, r9                 ; r12 = a+b = FIRE_A
    mov r13, r8                 ; r13 = a   = FIRE_B

    mov rax, r12
    imul rax, r12
    neg  rax
    mov  rbx, r12
    imul rbx, r13
    add  rax, rbx
    mov  rbx, r13
    imul rbx, r13
    add  rax, rbx
    mov  [EARTH_N_FIRE], rax

    ; ── Delta = N(FIRE) - N(current) ──
    mov rcx, [EARTH_N]
    mov rdx, [EARTH_N_FIRE]
    mov rax, rdx
    sub rax, rcx               ; delta = N_fire - N_curr
    mov [EARTH_DELTA], rax

    ; ── Pattern check: |delta| should be 2 ──
    mov rbx, rax
    ; abs(rax): if negative, negate
    test rax, rax
    jns  .pos
    neg  rbx
.pos:
    cmp rbx, 2
    jne .magnitude_wrong

    ; ── Sign check: delta should be opposite sign of N(current) ──
    ; N positive -> delta should be negative
    ; N negative -> delta should be positive
    ; i.e. N(current) * delta < 0  (opposite signs)
    ; Skip sign check on very first iteration (prev_delta == 0)
    cmp qword [EARTH_PREV_DELTA], 0
    je  .first_iter

    ; Check alternation: delta sign should be opposite of prev_delta sign
    mov r12, rax                ; current delta
    mov r13, [EARTH_PREV_DELTA]
    ; If both same sign -> pattern broken
    ; r12 and r13: test sign agreement via XOR of sign bits
    mov r14, r12
    xor r14, r13
    ; If bit 63 of XOR is 0, both same sign -> broken
    test r14, r14
    js   .signs_ok
    ; Same sign = pattern broken
    or   qword [ORACLE], ORACLE_EARTH_PATTERN
    jmp  .done

.signs_ok:
    ; Pattern good: clear earth bits
    mov rbx, [ORACLE]
    and rbx, ~(ORACLE_EARTH_PATTERN | ORACLE_EARTH_MAGNITUDE)
    mov [ORACLE], rbx
    jmp .done

.first_iter:
    ; First iteration: just clear earth error bits
    mov rbx, [ORACLE]
    and rbx, ~(ORACLE_EARTH_PATTERN | ORACLE_EARTH_MAGNITUDE)
    mov [ORACLE], rbx
    jmp .done

.magnitude_wrong:
    or  qword [ORACLE], ORACLE_EARTH_MAGNITUDE
    jmp .done

.done:
    ; Save delta for next iteration
    mov rax, [EARTH_DELTA]
    mov [EARTH_PREV_DELTA], rax

    ; ── Trinary projection: sign of N ──
    mov rax, [EARTH_N]
    test rax, rax
    jz   .tri_zero
    js   .tri_neg
    mov qword [TRINARY], 1
    ret
.tri_neg:
    mov qword [TRINARY], -1
    ret
.tri_zero:
    mov qword [TRINARY], 0
    ret

; =============================================================================
; EARTH WORKER — CPU 2 (AP loop)
; =============================================================================

role_earth:
    xor r15d, r15d
    lock or qword [READY_MASK], 4

.wait:
    mov rax, [REQUEST_K]
    cmp rax, r15
    je  .wait
    mov r15, rax
    call earth_compute
    mov [DONE_EARTH], r15
    jmp .wait

; =============================================================================
; WIND — CPU 3 (T(X) Fixed-Point Residual)
; =============================================================================
; T(X) = 1 + 1/X. Fixed point: X = phi.
; In Z[phi] with X = a*phi + b:
;   T(X) - X  residuals:
;     phi coeff:  a² + 2ab - a
;     const coeff: a² + b² - b - 1
; Both zero iff X = phi (the fixed point).
;
; WU-WEI: residuals grow as Fibonacci grows. 
; WIND_FIXED fires when both are zero (rare, meaningful event).
; WIND_DIVERGE fires when |res_a| + |res_b| exceeds threshold.

WIND_DIV_THRESH    equ 0x1000000000   ; ~68 billion: divergence threshold

wind_compute:
    mov r8, [STATE_A]
    mov r9, [STATE_B]

    ; ── phi-coeff residual: a² + 2ab - a ──
    mov rax, r8
    imul rax, r8                ; a²
    mov  rbx, r8
    imul rbx, r9                ; ab
    add  rbx, rbx               ; 2ab
    add  rax, rbx               ; a² + 2ab
    sub  rax, r8                ; a² + 2ab - a
    mov  [WIND_RES_A], rax

    ; ── const residual: a² + b² - b - 1 ──
    mov rcx, r8
    imul rcx, r8                ; a²
    mov  rdx, r9
    imul rdx, r9                ; b²
    add  rcx, rdx               ; a² + b²
    sub  rcx, r9                ; a² + b² - b
    dec  rcx                    ; a² + b² - b - 1
    mov  [WIND_RES_B], rcx

    ; ── Fixed point check ──
    test rax, rax
    jnz  .not_fixed
    test rcx, rcx
    jnz  .not_fixed
    mov  qword [WIND_FIX], 1
    or   qword [ORACLE], ORACLE_WIND_FIXED
    ret

.not_fixed:
    mov qword [WIND_FIX], 0

    ; ── Divergence check ──
    ; |res_a| + |res_b| > threshold?
    mov  rax, [WIND_RES_A]
    test rax, rax
    jns  .pos_a
    neg  rax
.pos_a:
    mov  rbx, [WIND_RES_B]
    test rbx, rbx
    jns  .pos_b
    neg  rbx
.pos_b:
    add  rax, rbx
    mov  r12, WIND_DIV_THRESH
    cmp  rax, r12
    jbe  .no_diverge
    or   qword [ORACLE], ORACLE_WIND_DIVERGE
    jmp  .wind_done

.no_diverge:
    ; Clear wind bits
    mov  rax, [ORACLE]
    and  rax, ~(ORACLE_WIND_FIXED | ORACLE_WIND_DIVERGE)
    mov  [ORACLE], rax

.wind_done:
    ret

; =============================================================================
; WIND WORKER — CPU 3 (AP loop)
; =============================================================================

role_wind:
    xor r15d, r15d
    lock or qword [READY_MASK], 8

.wait:
    mov rax, [REQUEST_K]
    cmp rax, r15
    je  .wait
    mov r15, rax
    call wind_compute
    mov [DONE_WIND], r15
    jmp .wait

; =============================================================================
; FIBONACCI–LEGENDRE PROBABLE-PRIME ORACLE
; =============================================================================
;
; modmul64: (RAX * RBX) mod RCX -> RAX
;   Uses MUL for the full 128-bit product then DIV for mod reduction.
;   Safe for any RCX != 0: since RAX,RBX < RCX on entry (both already
;   reduced), the product < RCX^2, so quotient < RCX < 2^64 -- always
;   fits, DIV can never fault here.
; =============================================================================

modmul64:
    push rdx
    mul  rbx            ; RDX:RAX = RAX*RBX
    div  rcx             ; RAX=quotient RDX=remainder
    mov  rax, rdx        ; return remainder
    pop  rdx
    ret

; ============================================================================
; legendre5: RAX = P  ->  returns RAX = 1, or RAX = 0xFFFFFFFFFFFFFFFF (-1),
; or RAX = 0 (only when P is a multiple of 5)
; ============================================================================

legendre5:
    push rdx
    push rcx
    mov  rcx, 5
    xor  rdx, rdx
    div  rcx             ; RAX=P/5, RDX = P mod 5
    mov  rax, rdx
    cmp  rax, 0
    je   .zero
    cmp  rax, 1
    je   .plus1
    cmp  rax, 4
    je   .plus1
    ; remainder is 2 or 3
    mov  rax, -1
    jmp  .done
.plus1:
    mov  rax, 1
    jmp  .done
.zero:
    xor  rax, rax
.done:
    pop  rcx
    pop  rdx
    ret

; ============================================================================
; modfib: computes F(N) mod M via iterative fast doubling.
;   Input:  RDI = N (index), RSI = M (modulus)
;   Output: RAX = F(N) mod M
;   Clobbers: RBX, RCX, RDX, R8, R9, R10, R11, R12, R13, R14
;
;   Recurrence (fast doubling):
;     F(2k)   = F(k) * (2*F(k+1) - F(k))
;     F(2k+1) = F(k+1)^2 + F(k)^2
;   Processed MSB-to-LSB over the bits of N.
; ============================================================================

modfib:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14

    ; special case N=0 -> F(0)=0
    test rdi, rdi
    jnz  .have_bits
    xor  rax, rax
    jmp  .modfib_ret

.have_bits:
    ; R12 = M (modulus, kept resident)
    mov  r12, rsi

    ; Find highest set bit of N (BSR) -> R13 = bit index
    bsr  r13, rdi

    ; (R8,R9) = (a,b) = (F(0),F(1)) mod M = (0,1)
    xor  r8, r8
    mov  r9, 1

.bit_loop:
    ; c = a*(2b - a) mod M
    mov  rax, r9
    add  rax, rax        ; 2b
    cmp  rax, r12
    jb   .no_corr1
    sub  rax, r12
.no_corr1:
    ; rax = 2b mod M ; now compute (2b - a) mod M, non-negative
    cmp  rax, r8
    jae  .no_corr2
    add  rax, r12
.no_corr2:
    sub  rax, r8          ; rax = (2b-a) mod M, in [0,M)
    mov  rbx, rax         ; RBX = (2b-a) mod M
    mov  rax, r8
    mov  rcx, r12
    call modmul64          ; RAX = a*(2b-a) mod M = c
    mov  r10, rax          ; R10 = c

    ; d = a^2 + b^2 mod M
    mov  rax, r8
    mov  rbx, r8
    mov  rcx, r12
    call modmul64           ; RAX = a*a mod M
    mov  r11, rax           ; R11 = a^2 mod M
    mov  rax, r9
    mov  rbx, r9
    mov  rcx, r12
    call modmul64            ; RAX = b*b mod M
    add  rax, r11
    cmp  rax, r12
    jb   .no_corr3
    sub  rax, r12
.no_corr3:
    mov  r14, rax            ; R14 = d = a^2+b^2 mod M

    ; test bit R13 of N (RDI)
    mov  rcx, r13
    mov  rax, 1
    shl  rax, cl
    test rdi, rax
    jz   .bit_zero

    ; bit=1: (a,b) = (d, (c+d) mod M)
    mov  r8, r14
    mov  rax, r10
    add  rax, r14
    cmp  rax, r12
    jb   .no_corr4
    sub  rax, r12
.no_corr4:
    mov  r9, rax
    jmp  .bit_done

.bit_zero:
    ; bit=0: (a,b) = (c, d)
    mov  r8, r10
    mov  r9, r14

.bit_done:
    test r13, r13
    jz   .modfib_done
    dec  r13
    jmp  .bit_loop

.modfib_done:
    mov  rax, r8

.modfib_ret:
    pop  r14
    pop  r13
    pop  r12
    pop  r11
    pop  r10
    pop  r9
    pop  r8
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; ============================================================================
; prime_test_step: tests the current PRIME_CANDIDATE for probable primality
; via the Fibonacci-Legendre test, advances the candidate by 1, and updates
; PRIME_FOUND_COUNT / PRIME_LAST_FOUND on a pass.
; ============================================================================

; ============================================================================
; zmul_mod: (R8,R9) = (a,b) * (c,d) mod M, in Z[phi], phi^2=phi+1
;   Input:  R8,R9 = a,b (first factor)   R10,R11 = c,d (second factor)
;           R13   = M (modulus)
;   Output: R8,R9 = result, reduced mod M
;   (a,b)*(c,d) = (ac+ad+bc, ac+bd)
; ============================================================================

zmul_mod:
    push rax
    push rbx
    push rcx
    push r12
    push r14
    push r15

    mov  rax, r8
    mov  rbx, r10
    mov  rcx, r13
    call modmul64
    mov  r12, rax             ; ac

    mov  rax, r8
    mov  rbx, r11
    mov  rcx, r13
    call modmul64
    mov  r14, rax             ; ad

    mov  rax, r9
    mov  rbx, r10
    mov  rcx, r13
    call modmul64
    mov  r15, rax             ; bc

    mov  rax, r9
    mov  rbx, r11
    mov  rcx, r13
    call modmul64              ; bd

    ; new_b = (ac+bd) mod M
    add  rax, r12
    cmp  rax, r13
    jb   .nb_ok
    sub  rax, r13
.nb_ok:
    mov  r9, rax               ; new_b

    ; new_a = (ac+ad+bc) mod M -- sum of THREE terms each already < M,
    ; so the sum can reach just under 3M. ONE conditional subtraction
    ; only fully reduces sums up to 2M; a sum in [2M,3M) needs a SECOND
    ; subtraction. (This was the bug: single subtraction left a residual
    ; +M in ~19% of cases, verified against an independent Python
    ; zmul_mod -- found_count mismatched 14611 vs 10992 until this fix.)
    mov  rax, r12
    add  rax, r14
    add  rax, r15
    cmp  rax, r13
    jb   .na_ok
    sub  rax, r13
    cmp  rax, r13
    jb   .na_ok
    sub  rax, r13
.na_ok:
    mov  r8, rax                ; new_a
    ; r9 already holds new_b from above

    pop  r15
    pop  r14
    pop  r12
    pop  rcx
    pop  rbx
    pop  rax
    ret

; ============================================================================
; zpow_mod: computes phi^N mod M via square-and-multiply in Z[phi]/(M).
;   Input:  RDI = N (exponent), RSI = M (modulus)
;   Output: R8,R9 = (a,b) such that phi^N == a*phi+b (mod M)
;   Clobbers: RAX,RBX,RCX,RDX,R10,R11,R12,R13,R14,R15
; ============================================================================

zpow_mod:
    push rax
    push rbx
    push rcx
    push rdx

    mov  r13, rsi              ; M resident
    mov  r12, rdi              ; exponent resident (consumed by shifting)

    mov  r8, 0                 ; result = phi^0 = (0,1)
    mov  r9, 1
    mov  r14, 1                ; base = phi = (1,0)
    xor  r15, r15

.zp_loop:
    test r12, r12
    jz   .zp_done

    test r12, 1
    jz   .zp_sq

    ; result *= base
    mov  r10, r14
    mov  r11, r15
    call zmul_mod

.zp_sq:
    ; base *= base
    push r8
    push r9
    mov  r8, r14
    mov  r9, r15
    mov  r10, r14
    mov  r11, r15
    call zmul_mod
    mov  r14, r8
    mov  r15, r9
    pop  r9
    pop  r8

    shr  r12, 1
    jmp  .zp_loop

.zp_done:
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret

; ============================================================================
; prime_test_step: full two-coefficient Frobenius probable-prime test.
;   Checks phi^P mod P against the expected split (phi=(1,0)) or inert
;   (psi=(P-1,1)) target EXACTLY -- both coefficients, not just one.
;   Verified in Python: reduces false positives from 59 to 1 (the single
;   documented exception, 4181=37*113) over P=2..4999, at ~1.8-2x the
;   modular-multiply cost of the single-coefficient test.
; ============================================================================

prime_test_step:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov  rax, [PRIME_CANDIDATE]
    cmp  rax, 2
    jae  .valid_candidate
    mov  qword [PRIME_CANDIDATE], 2
    mov  rax, 2

.valid_candidate:
    ; iris_base computes span = P-3 and assumes P is comfortably large
    ; enough for that to be meaningful (unsigned underflow for P<3, and
    ; nothing useful to probe for P<5 anyway) -- guard small candidates
    ; and let them fall straight through to the existing Frobenius gate,
    ; which already handles them correctly.
    cmp  qword [PRIME_CANDIDATE], 5
    jb   .skip_iris

    call iris_prp_step
    cmp  qword [IRIS_RESULT], 0
    je   .not_prime

.skip_iris:
    call legendre5              ; RAX = (5|P)
    mov  [PRIME_LEGENDRE], rax
    mov  rbx, rax                ; keep legendre in RBX across zpow_mod

    mov  rdi, [PRIME_CANDIDATE]  ; N = P
    mov  rsi, [PRIME_CANDIDATE]  ; M = P
    call zpow_mod                 ; R8,R9 = phi^P mod P

    mov  [PRIME_FIB_MOD], r8      ; repurposed: store phi^P's phi-coeff

    cmp  rbx, 0
    je   .ramified

    cmp  rbx, 1
    je   .check_split

    ; inert case (5|P) == -1: expect phi^P == psi == (P-1, 1)
    mov  rax, [PRIME_CANDIDATE]
    dec  rax
    cmp  r8, rax
    jne  .not_prime
    cmp  r9, 1
    jne  .not_prime
    jmp  .is_prime

.check_split:
    ; split case (5|P) == 1: expect phi^P == phi == (1, 0)
    cmp  r8, 1
    jne  .not_prime
    cmp  r9, 0
    jne  .not_prime
    jmp  .is_prime

.ramified:
    ; (5|P) == 0 only when P is a multiple of 5; only P=5 itself is prime
    mov  rax, [PRIME_CANDIDATE]
    cmp  rax, 5
    jne  .not_prime
    jmp  .is_prime

.is_prime:
    inc  qword [PRIME_FOUND_COUNT]
    mov  rax, [PRIME_CANDIDATE]
    mov  [PRIME_LAST_FOUND], rax

.not_prime:
    inc  qword [PRIME_CANDIDATE]

    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  r11
    pop  r10
    pop  r9
    pop  r8
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret


; ============================================================================
; IRIS STUTTER-STEP ADAPTIVE STRONG-PRP GATE
; ============================================================================
;
; A fixed base list (2,3,5,7,...) for a strong-MR gate can always be
; defeated by an Arnault-style construction targeting exactly that list --
; that's what 3215031751 (smallest strong pseudoprime to bases 2,3,5,7) is.
; The iris probe's base scales with the candidate itself (phi-Weyl
; equidistribution, three-distance theorem -- same golden-angle property
; behind phyllotactic packing), so there is no small fixed target for a
; construction to aim at. Still a member of the strong-MR family though
; (shares the multiplicative-order failure surface) -- this hardens and
; cheapens the MR side of the oracle, it does not replace an independent-
; family closer.
;
; Cost profile: resolves the overwhelming majority of composites in ONE
; modpow_u64 call (measured avg 1.033 probes across 151 known-hard natural
; composites), so composites are usually rejected far more cheaply than
; the existing Z[phi] Frobenius gate (zpow_mod, 2 zmul_mod calls per bit
; of P) -- and never touch that gate at all once iris rejects them.
;
; ============================================================================

; ---------------------------------------------------------------------------
; modpow_u64: RDI^RSI mod RDX -> RAX   (plain scalar modexp, square-and-
; multiply). Distinct from zpow_mod: that one exponentiates in the Z[phi]
; RING (pairs, via zmul_mod). This is ordinary scalar modular
; exponentiation, needed because the strong-MR test operates on plain
; integers mod P, not Z[phi] elements. Reuses the existing modmul64.
; ---------------------------------------------------------------------------
modpow_u64:
    push r8
    push r9
    push r10
    push r11
    mov  r9, rdx           ; modulus
    mov  r8, rsi           ; exponent
    mov  r10, rdi          ; base (mod m, caller ensures < m)
    mov  r11, 1            ; result

.mp_loop:
    test r8, r8
    jz   .mp_done
    test r8, 1
    jz   .mp_sq

    mov  rax, r11
    mov  rbx, r10
    mov  rcx, r9
    call modmul64
    mov  r11, rax

.mp_sq:
    mov  rax, r10
    mov  rbx, r10
    mov  rcx, r9
    call modmul64
    mov  r10, rax

    shr  r8, 1
    jmp  .mp_loop

.mp_done:
    mov  rax, r11
    pop  r11
    pop  r10
    pop  r9
    pop  r8
    ret

; ---------------------------------------------------------------------------
; strong_sprp: strong probable-prime test, single base.
; in: RDI = n, RSI = a (2 <= a <= n-2)
; out: RAX = 1 (a is a witness for "probably prime" -- FOOLED, or n really
;             is prime), 0 (a proves n composite)
; ---------------------------------------------------------------------------
strong_sprp:
    push rbx
    push rcx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    mov r12, rdi            ; n
    mov r13, rsi            ; a

    cmp r13, 1
    jbe .pass
    mov rax, r12
    dec rax
    cmp r13, rax
    je .pass

    mov rax, r12
    dec rax
    xor r8, r8               ; r
    mov r9, rax               ; d
.factor_loop:
    test r9, 1
    jnz .factor_done
    shr r9, 1
    inc r8
    jmp .factor_loop
.factor_done:

    mov rdi, r13
    mov rsi, r9
    mov rdx, r12
    call modpow_u64
    mov r10, rax             ; x = a^d mod n

    cmp r10, 1
    je .pass
    mov rax, r12
    dec rax
    cmp r10, rax
    je .pass

    mov r11, r8
    dec r11
    test r11, r11
    jz .fail

.sq_loop:
    mov rax, r10
    mov rbx, r10
    mov rcx, r12
    call modmul64
    mov r10, rax
    mov rax, r12
    dec rax
    cmp r10, rax
    je .pass
    dec r11
    jnz .sq_loop

.fail:
    xor rax, rax
    jmp .ssp_done
.pass:
    mov rax, 1
.ssp_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
; iris_base: k-th phi-Weyl probe base for candidate n.
; in: RDI = n, RSI = k
; out: RAX = base, in [2, n-2]
; base_k(n) = 2 + high64( ((k*GOLDEN64) mod 2^64) * (n-3) )
; ---------------------------------------------------------------------------
iris_base:
    push rbx
    push rdx
    push r8

    mov rax, rsi
    mov rbx, GOLDEN64
    mul rbx
    mov r8, rax

    mov rax, rdi
    sub rax, 3
    mov rbx, rax
    mov rax, r8
    mul rbx
    mov rax, rdx
    add rax, 2

    pop r8
    pop rdx
    pop rbx
    ret

; ---------------------------------------------------------------------------
; iris_prp_step: stutter-step through phi-spaced bases for [PRIME_CANDIDATE].
; ---------------------------------------------------------------------------
iris_prp_step:
    push rdi
    push rsi
    push rax
    push r8
    push r9

    ; Even candidates > 2 are composite by construction (PRIME_CANDIDATE
    ; is guarded >=5 by the caller). Reject immediately, no probe needed --
    ; also sidesteps strong_sprp's r=0 case (n-1 odd), which this substrate
    ; never needs to handle since it's never asked to.
    mov  rax, [PRIME_CANDIDATE]
    test rax, 1
    jnz  .odd_candidate
    mov  qword [IRIS_RESULT], 0
    mov  qword [IRIS_PROBES_USED], 0
    jmp  .done

.odd_candidate:
    xor r8, r8

.probe_loop:
    inc r8

    mov rdi, [PRIME_CANDIDATE]
    mov rsi, r8
    call iris_base
    mov r9, rax
    mov [IRIS_BASE_USED], r9

    mov rdi, [PRIME_CANDIDATE]
    mov rsi, r9
    call strong_sprp
    test rax, rax
    jz .composite

    cmp r8, IRIS_MAX_PROBES
    jl .probe_loop

    mov qword [IRIS_RESULT], 1
    mov [IRIS_PROBES_USED], r8
    jmp .done

.composite:
    mov qword [IRIS_RESULT], 0
    mov [IRIS_PROBES_USED], r8

.done:
    pop r9
    pop r8
    pop rax
    pop rsi
    pop rdi
    ret


; ============================================================================
; SERIAL OUTPUT HELPERS (COM1, 115200 8N1)
; ============================================================================

; serial_wait: wait for TX empty
serial_wait:
    push rax
    push rdx
.w:
    mov  dx, 0x3FD
    in   al, dx
    and  al, 0x20
    jz   .w
    pop  rdx
    pop  rax
    ret

; serial_putchar: send AL via COM1
serial_putchar:
    push rdx
    push rax
    mov  ah, al
    call serial_wait
    mov  dx, 0x3F8
    mov  al, ah
    out  dx, al
    pop  rax
    pop  rdx
    ret

serial_putchar_L:
    mov  al, 'L'
    jmp  serial_putchar

serial_putchar_V:
    mov  al, 'V'
    jmp  serial_putchar

; serial_put_hex64: print RAX as 16 hex digits + newline to COM1
serial_put_hex64:
    push rcx
    push rax
    push rbx
    mov  rbx, rax
    mov  rcx, 16
.hex:
    mov  rax, rbx
    shr  rax, 60
    and  eax, 0x0F
    movzx eax, byte [hex_digits + PHYS_ADJ + rax]
    call serial_putchar
    shl  rbx, 4
    loop .hex
    ; newline
    mov  al, 0x0D
    call serial_putchar
    mov  al, 0x0A
    call serial_putchar
    pop  rbx
    pop  rax
    pop  rcx
    ret

; serial_puts: RSI = physical address of null-terminated string
serial_puts:
    push rsi
    push rax
.next:
    lodsb
    test al, al
    jz   .done
    call serial_putchar
    jmp  .next
.done:
    pop  rax
    pop  rsi
    ret

; =============================================================================
; AP TRAMPOLINE (16-bit, copied to 0x8000)
; =============================================================================

BITS 16

ap_trampoline:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; Use embedded GDT (don't rely on boot sector memory at 0x7C00)
    lgdt [cs:ap_gdt_ptr - ap_trampoline]

    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    jmp dword 0x08:AP_PM_PHYS

; Embedded GDT for AP (at known offset from ap_trampoline start)
align 8
ap_gdt_base:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF  ; 0x08: 32-bit code
    dq 0x00CF92000000FFFF  ; 0x10: data
    dq 0x00AF9A000000FFFF  ; 0x18: 64-bit code
ap_gdt_end:
ap_gdt_ptr:
    dw ap_gdt_end - ap_gdt_base - 1
    dd AP_TRAMP_PHYS + (ap_gdt_base - ap_trampoline)

; AP: 32-bit pmode
BITS 32

ap_pm_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x00078000     ; temporary stack for AP

    ; PAE
    mov eax, cr4
    or  eax, (1 << 5)
    mov cr4, eax

    ; EFER.LME
    mov ecx, 0xC0000080
    rdmsr
    or  eax, (1 << 8)
    wrmsr

    ; Use BSP page tables
    mov eax, PML4_PHYS
    mov cr3, eax

    ; Paging on
    mov eax, cr0
    or  eax, (1 << 31)
    mov cr0, eax

    jmp dword 0x18:AP_LM_PHYS

; AP: 64-bit entry
BITS 64

ap_lm_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; APIC ID -> stack assignment
    mov eax, 1
    cpuid
    shr ebx, 24
    and ebx, 0xFF

    ; Private stack: AP_STACK_BASE + apic_id * AP_STACK_STRIDE
    mov rcx, AP_STACK_BASE
    mov rdx, rbx
    imul rdx, AP_STACK_STRIDE
    add  rcx, rdx
    mov  rsp, rcx

    ; Dispatch by APIC ID
    cmp ebx, 1
    je  .water
    cmp ebx, 2
    je  .earth
    cmp ebx, 3
    je  .wind
    jmp .dead

.water: call role_water
        jmp .dead
.earth: call role_earth
        jmp .dead
.wind:  call role_wind

.dead:
    cli
.halt:
    hlt
    jmp .halt

align 2
ap_trampoline_end:

; =============================================================================
; VGA INITIALIZATION
; =============================================================================

BITS 64

vga_init:
    ; Clear screen (2000 cells, attribute 0x07 = white on black)
    mov  rdi, VGA_BASE
    mov  ax,  0x0720
    mov  rcx, 2000
    rep  stosw

    ; Row 0: title
    mov  rdi, VGA_BASE + VGA_ROW * 0
    mov  rsi, str_title + PHYS_ADJ
    mov  bl,  0x0F          ; bright white
    call vga_puts_color

    ; Row 1: topology
    mov  rdi, VGA_BASE + VGA_ROW * 1
    mov  rsi, str_topology + PHYS_ADJ
    mov  bl,  0x0B          ; cyan
    call vga_puts_color

    ; Row 2: STATE header
    mov  rdi, VGA_BASE + VGA_ROW * 2
    mov  rsi, str_state + PHYS_ADJ
    mov  bl,  0x07
    call vga_puts_color

    ; Row 3: FIRE header
    mov  rdi, VGA_BASE + VGA_ROW * 3
    mov  rsi, str_fire + PHYS_ADJ
    mov  bl,  0x0C          ; bright red
    call vga_puts_color

    ; Row 4: WATER header
    mov  rdi, VGA_BASE + VGA_ROW * 4
    mov  rsi, str_water + PHYS_ADJ
    mov  bl,  0x09          ; bright blue
    call vga_puts_color

    ; Row 5: EARTH header
    mov  rdi, VGA_BASE + VGA_ROW * 5
    mov  rsi, str_earth + PHYS_ADJ
    mov  bl,  0x0A          ; bright green
    call vga_puts_color

    ; Row 6: WIND header
    mov  rdi, VGA_BASE + VGA_ROW * 6
    mov  rsi, str_wind + PHYS_ADJ
    mov  bl,  0x0E          ; yellow
    call vga_puts_color

    ; Row 7: ORACLE header
    mov  rdi, VGA_BASE + VGA_ROW * 7
    mov  rsi, str_oracle + PHYS_ADJ
    mov  bl,  0x0D          ; bright magenta
    call vga_puts_color

    ; Row 8: YIN header
    mov  rdi, VGA_BASE + VGA_ROW * 8
    mov  rsi, str_yin + PHYS_ADJ
    mov  bl,  0x07
    call vga_puts_color

    ; Row 9: PRIME oracle header
    mov  rdi, VGA_BASE + VGA_ROW * 9
    mov  rsi, str_prime + PHYS_ADJ
    mov  bl,  0x0E          ; yellow
    call vga_puts_color

    ret

; =============================================================================
; VGA UPDATE (called every PRINT_EVERY iterations)
; =============================================================================

; Column positions for values (each hex64 = 16 chars + 1 space = 17 cols)
; Labels end around col 10, values start at col 10 (byte offset = col*2)

vga_update:
    ; ── Row 2: STATE K= A= B= ──
    mov rdi, VGA_BASE + VGA_ROW * 2 + 10*2
    mov rax, [STATE_K]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 2 + 28*2
    mov rax, [STATE_A]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 2 + 46*2
    mov rax, [STATE_B]
    call vga_hex64

    ; ── Row 3: FIRE A= B= ──
    mov rdi, VGA_BASE + VGA_ROW * 3 + 10*2
    mov rax, [FIRE_A]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 3 + 28*2
    mov rax, [FIRE_B]
    call vga_hex64

    ; ── Row 4: WATER A= B= ──
    mov rdi, VGA_BASE + VGA_ROW * 4 + 10*2
    mov rax, [WATER_A]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 4 + 28*2
    mov rax, [WATER_B]
    call vga_hex64

    ; ── Row 5: EARTH N= NF= DELTA= ──
    mov rdi, VGA_BASE + VGA_ROW * 5 + 10*2
    mov rax, [EARTH_N]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 5 + 28*2
    mov rax, [EARTH_N_FIRE]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 5 + 46*2
    mov rax, [EARTH_DELTA]
    call vga_hex64

    ; ── Row 6: WIND RA= RB= FIX= ──
    mov rdi, VGA_BASE + VGA_ROW * 6 + 10*2
    mov rax, [WIND_RES_A]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 6 + 28*2
    mov rax, [WIND_RES_B]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 6 + 46*2
    mov rax, [WIND_FIX]
    call vga_hex64

    ; ── Row 7: ORACLE= STRATEGY= ──
    mov rdi, VGA_BASE + VGA_ROW * 7 + 10*2
    mov rax, [ORACLE]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 7 + 28*2
    mov rax, [STRATEGY]
    call vga_hex64
    ; Strategy name
    mov rdi, VGA_BASE + VGA_ROW * 7 + 46*2
    mov rax, [STRATEGY]
    call vga_strategy_name

    ; ── Row 8: YIN PH DEPTH ──
    mov rdi, VGA_BASE + VGA_ROW * 8 + 10*2
    mov rax, [YIN]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 8 + 28*2
    mov rax, [PHASE]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 8 + 46*2
    mov rax, [DEPTH]
    call vga_hex64

    ; ── Row 9: PRIME candidate / found-count / last-found ──
    mov rdi, VGA_BASE + VGA_ROW * 9 + 10*2
    mov rax, [PRIME_CANDIDATE]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 9 + 28*2
    mov rax, [PRIME_FOUND_COUNT]
    call vga_hex64
    mov rdi, VGA_BASE + VGA_ROW * 9 + 46*2
    mov rax, [PRIME_LAST_FOUND]
    call vga_hex64

    ; ── COM1 serial: send terse status line ──
    ; Format: "D=xxxx O=xx S=x\r\n"
    call serial_putchar_V   ; 'V' = VGA update marker
    mov  rsi, str_serial_depth + PHYS_ADJ
    call serial_puts
    mov  rax, [DEPTH]
    call serial_put_hex64
    mov  rsi, str_serial_oracle + PHYS_ADJ
    call serial_puts
    mov  rax, [ORACLE]
    call serial_put_hex64

    ret

; ============================================================================
; vga_strategy_name: print strategy name at RDI
; Input: rax = STRATEGY index
; ============================================================================

vga_strategy_name:
    cmp rax, STRATEGY_FLOWING
    je  .flowing
    cmp rax, STRATEGY_NONACTION
    je  .nonaction
    cmp rax, STRATEGY_REDIRECT
    je  .redirect
    cmp rax, STRATEGY_CONVERGE
    je  .converge
    cmp rax, STRATEGY_CRITICAL
    je  .critical
    mov rsi, str_strat_unknown + PHYS_ADJ
    jmp .print
.flowing:
    mov rsi, str_strat_flowing + PHYS_ADJ
    jmp .print
.nonaction:
    mov rsi, str_strat_nonaction + PHYS_ADJ
    jmp .print
.redirect:
    mov rsi, str_strat_redirect + PHYS_ADJ
    jmp .print
.converge:
    mov rsi, str_strat_converge + PHYS_ADJ
    jmp .print
.critical:
    mov rsi, str_strat_critical + PHYS_ADJ
.print:
    mov bl, 0x0D
    jmp vga_puts_color     ; tail call

; =============================================================================
; VGA HELPERS
; =============================================================================

; vga_puts_color: RDI=dest, RSI=string, BL=attribute
vga_puts_color:
.next:
    lodsb
    test al, al
    jz   .done
    mov  [rdi], al
    mov  [rdi + 1], bl
    add  rdi, 2
    jmp  .next
.done:
    ret

; vga_hex64: RDI=dest, RAX=value, writes 16 hex digits
vga_hex64:
    push rbx
    push rcx
    push rdx
    push rdi
    push rax
    mov  rcx, 16
    mov  rbx, rdi

.hloop:
    mov  rdx, rax
    shr  rdx, 60
    and  edx, 0x0F
    movzx edx, byte [hex_digits + PHYS_ADJ + rdx]
    mov  [rbx], dl
    mov  byte [rbx + 1], 0x07
    add  rbx, 2
    shl  rax, 4
    loop .hloop

    pop  rax
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; =============================================================================
; STRINGS
; =============================================================================

str_title:
    db "HDGL Z[phi] WU-WEI SUBSTRATE  FIRE/WATER/EARTH/WIND",0
str_topology:
    db "CPU0=FIRE  CPU1=WATER  CPU2=EARTH  CPU3=WIND",0
str_state:
    db "STATE  K=                  A=                  B=",0
str_fire:
    db "FIRE   A=                  B=",0
str_water:
    db "WATER  A=                  B=",0
str_earth:
    db "EARTH  N=                  NF=                 DELTA=",0
str_wind:
    db "WIND   RA=                 RB=                 FIX=",0
str_oracle:
    db "ORACLE=                    STRATEGY=",0
str_yin:
    db "YIN    S=                  PH=                 DEPTH=",0

str_prime:
    db "PRIME  P=                  FOUND=              LAST=",0

str_strat_flowing:  db "FLOWING RIVER",0
str_strat_nonaction: db "NON-ACTION   ",0
str_strat_redirect: db "REDIRECT     ",0
str_strat_converge: db "CONVERGENCE  ",0
str_strat_critical: db "!! CRITICAL !!",0
str_strat_unknown:  db "UNKNOWN      ",0

hex_digits:
    db "0123456789ABCDEF"

str_serial_depth:  db "DEPTH=",0
str_serial_oracle: db "ORACLE=",0

; =============================================================================
; PHYSICAL ADDRESS CONSTANTS
; =============================================================================
;
; All labels are relative to ORG 0x7C00.
; Physical address of a label L in payload = 0x10000 + (L - boot_start) - 512
; because:
;   - payload loads at physical 0x10000
;   - boot_start = 0x7C00
;   - sector 1 (boot sector) = 512 bytes, payload starts at file offset 512
;   - So physical(L) = 0x10000 + (L - 0x7C00) - 512
;                    = 0x10000 + L - 0x7E00
;                    = L + (0x10000 - 0x7E00)
;                    = L + 0x8200
;
; Verify: protected_entry label value = 0x7C00 + 512 = 0x7E00
;         physical = 0x7E00 + 0x8200 = 0x10200. Correct!
;
; For AP trampoline (copied to 0x8000):
;   ap_trampoline label = 0x7C00 + (its file offset)
;   AP_PM_PHYS = 0x8000 + (ap_pm_entry - ap_trampoline)
;   AP_LM_PHYS = 0x8000 + (ap_lm_entry - ap_trampoline)

PROTECTED_ENTRY_PHYS equ protected_entry
LONG_MODE_ENTRY_PHYS equ long_mode_entry
AP_PM_PHYS           equ AP_TRAMP_PHYS   + (ap_pm_entry  - ap_trampoline)
AP_LM_PHYS           equ AP_TRAMP_PHYS   + (ap_lm_entry  - ap_trampoline)

; =============================================================================
; IMAGE PADDING TO EXACTLY 64 SECTORS
; =============================================================================

times (IMAGE_SECTORS * 512) - ($ - $$) db 0
