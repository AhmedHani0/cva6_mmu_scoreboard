# CVA6 MMU Verification with a Real PTW and Interface-Level Scoreboard

## 1. Objective

The purpose of this verification stage is to formally verify the externally visible behavior of the CVA6 **Memory Management Unit (MMU)** using a lightweight scoreboard while keeping the complete translation path concrete.

The verified design contains the real:

- Instruction Translation Lookaside Buffer (**ITLB**),
- Data Translation Lookaside Buffer (**DTLB**),
- shared Translation Lookaside Buffer (**shared TLB**),
- Page Table Walker (**PTW**),
- MMU control logic,
- page-table traversal,
- TLB refill path,
- superpage handling,
- address-construction logic.

Unlike an earlier experimental approach, the PTW is **not black-boxed**. The complete MMU translation path is therefore explored by OneSpin.

The scoreboard is intentionally kept simple. It does not attempt to reproduce the complete MMU or page-table algorithm. Instead, it checks consistency between information visible at the MMU boundary.

The principal data-integrity target is the historical bug in:

```systemverilog
lsu_dtlb_ppn_o
```

where the effective Physical Page Number (**PPN**) reported in the DTLB-hit cycle can differ from the PPN actually used in the final physical address one cycle later.

---

## 2. Verification Philosophy

The verification follows a simple rule:

> Track only what is necessary to connect an externally visible request with its externally visible result.

The scoreboard therefore avoids constructing a complete software-like reference MMU.

For the Load/Store Unit (**LSU**), the MMU already exposes an early PPN:

```systemverilog
lsu_dtlb_ppn_o
```

so the scoreboard can compare this directly with the PPN contained in the final:

```systemverilog
lsu_paddr_o
```

For instruction fetch, the external interface does not expose an equivalent early ITLB PPN. Therefore a small amount of read-only ITLB observation is allowed only for fetch data integrity.

The scoreboard does not use PTW or TLB internal state to determine LSU data integrity. The real RTL remains responsible for all translation and refill behavior.

---

## 3. Verification Architecture

The verification setup consists of:

```text
Formal environment
        |
        v
cva6_mmu_formal_top
        |
        v
      CVA6 MMU
+---------------------+
| ITLB                |
| DTLB                |
| Shared TLB          |
| Real PTW            |
| Address generation  |
+---------------------+
        |
        v
Interface-level scoreboard
```

The scoreboard is bound directly to the MMU using:

```systemverilog
bind cva6_mmu cva6_mmu_scoreboard_bind ...
```

The scoreboard therefore observes the same MMU instance that contains the real TLB and PTW implementations.

---

## 4. Formal Configuration

The formal environment preserves the target RV64 MMU architecture.

The important configuration is:

```text
XLEN                  = 64
VLEN                  = 64
PLEN                  = 56
PPNW                  = 44

RVH                   = 1
Page-table levels     = 3
Sv39 / Sv39x4
ASID width            = 16
VMID width            = 14

MMU                   = enabled
Shared TLB            = enabled
Svnapot               = enabled
```

The Hypervisor extension (**RVH**) is enabled before calling:

```systemverilog
build_config()
```

because several derived MMU dimensions depend on it.

In particular:

```text
VpnLen = 29
```

is required for the RVH/Sv39x4 configuration.

---

## 5. State-Space Reduction

The architectural widths and three-level page-table structure are preserved.

Instead of reducing the address width or changing Sv39 into another architecture, only the storage capacity of the Translation Lookaside Buffers is reduced:

```systemverilog
InstrTlbEntries = 2;
DataTlbEntries  = 2;
SharedTlbDepth  = 2;
```

This reduces the amount of state that OneSpin must explore while retaining:

- the same lookup behavior,
- the same refill behavior,
- the same page sizes,
- the same PTW,
- the same address calculations,
- the same S-stage and G-stage logic.

This reduction therefore improves formal tractability without changing the MMU architecture relevant to the properties.

---

## 6. PMP Handling

Physical Memory Protection (**PMP**) is intentionally outside the scope of this verification stage.

Initially, the PMP configuration signals were tied to zero while the configuration still contained nonzero PMP entries. This unintentionally denied PTW memory accesses performed in Supervisor mode.

The result was:

```text
DTLB/ITLB miss
      |
      v
PTW starts
      |
      v
PMP denies page-table access
      |
      v
PTW access exception
      |
      v
No successful TLB refill
```

Consequently, translated TLB-hit covers became unreachable and the data-integrity properties could pass vacuously.

The formal configuration was corrected by setting:

```systemverilog
NrPMPEntries = 0;
```

both before and after `build_config()`.

This explicitly removes PMP from the current verification scope and allows the real PTW to access page-table memory.

---

## 7. Real PTW Memory Environment

The Page Table Walker remains concrete.

Only the external memory environment is constrained so that memory cannot block the PTW forever.

The scoreboard assumes bounded memory progress.

A PTW request must eventually receive a grant:

```systemverilog
req_port_o.data_req
|->
##[1:3]
req_port_i.data_gnt
```

and a valid request tag must eventually receive memory data:

```systemverilog
req_port_o.tag_valid
|->
##[1:3]
req_port_i.data_rvalid
```

These are fairness assumptions.

Without them, formal verification could legally choose:

```text
PTW requests page-table data
        |
        v
Memory never responds
        |
        v
MMU waits forever
```

which would make MMU liveness impossible to prove.

No specific Page Table Entry (**PTE**) contents are assumed. The PTW therefore still explores legal leaves, non-leaves, faults, page sizes, and translation stages.

---

## 8. Request and Response Timing

The LSU and instruction-fetch interfaces have different timing.

### 8.1 LSU

For a translated DTLB hit:

```text
Cycle N
------------------------
lsu_req_i
lsu_vaddr_i
lsu_dtlb_hit_o
lsu_dtlb_ppn_o

        |
        v clock

Cycle N+1
------------------------
lsu_valid_o
lsu_exception_o
lsu_paddr_o
```

Therefore:

```systemverilog
lsu_dtlb_ppn_o
```

is the early Cycle-0 Physical Page Number, while:

```systemverilog
lsu_paddr_o
```

is the final Cycle-1 physical address.

This relationship is the basis of the LSU data-integrity property.

### 8.2 Instruction Fetch

Instruction translation is more combinational.

A successful ITLB hit can produce:

```systemverilog
fetch_valid
fetch_paddr
```

in the same cycle as the instruction request.

Therefore fetch data integrity is checked in the same cycle as the ITLB hit.

---

## 9. Request-Context Assumptions

The MMU interface does not contain a request ID or a complete ready/accept handshake.

A request that requires a page-table walk must therefore remain associated with the same architectural translation context until the response is produced.

For LSU, the formal environment requires the request and relevant context to remain stable while the transaction is outstanding.

This includes:

- virtual address,
- load/store type,
- S-stage enable,
- G-stage enable,
- virtualization mode,
- privilege level,
- SUM,
- MXR,
- VMXR,
- HLVX,
- SATP root PPN,
- VSATP root PPN,
- HGATP root PPN,
- ASID,
- VS-ASID,
- VMID.

The assumption is forward-looking:

```systemverilog
request && !terminal
|=>
terminal || same_request_and_context
```

The use of:

```systemverilog
|=>
```

is important.

It means:

> If the request has not completed in this cycle, then in the next cycle it must either complete or still represent exactly the same transaction.

Repeated application of the assumption holds the request throughout a long PTW walk.

---

## 10. Flush Handling

The scoreboard defines:

```systemverilog
any_flush =
    flush_i          ||
    flush_tlb_i      ||
    flush_tlb_vvma_i ||
    flush_tlb_gvma_i;
```

Flushes cancel request tracking and disable assertions whose transaction is no longer meaningful.

Properties therefore commonly use:

```systemverilog
disable iff (!rst_ni || any_flush)
```

This prevents a request that has been externally cancelled by a flush from generating a false liveness or data-integrity failure.

---

## 11. LSU Cycle-0 Hit Capture

The LSU data-integrity checker records the PPN only for a genuine translated DTLB hit.

The hit event is approximately:

```systemverilog
lsu_hit_event =
    lsu_req_i &&
    lsu_translation_enabled &&
    !misaligned_ex_i.valid &&
    !lsu_prev_misaligned_q &&
    lsu_dtlb_hit_o &&
    !any_flush;
```

When this event occurs, the scoreboard captures:

```systemverilog
lsu_hit_ppn_q <= lsu_dtlb_ppn_o;
```

It also constructs the physical address that would correspond to the advertised PPN:

```systemverilog
lsu_hit_expected_paddr_q <= {
    lsu_dtlb_ppn_o,
    lsu_vaddr_i[11:0]
};
```

The 12 lower bits are the page offset.

---

## 12. Relationship Between PPN and Physical Address

For a standard page translation:

```text
Physical address
=
{ Physical Page Number, 12-bit page offset }
```

Therefore:

```systemverilog
PPN = physical_address[PLEN-1:12];
```

The scoreboard extracts the PPN actually used by the final MMU result:

```systemverilog
lsu_true_ppn =
    CVA6Cfg.PPNW'(
        lsu_paddr_o[CVA6Cfg.PLEN-1:12]
    );
```

The two values:

```text
lsu_hit_ppn_q
lsu_true_ppn
```

should describe exactly the same translated physical page.

---

## 13. LSU PPN Data-Integrity Property

The main LSU data-integrity assertion is:

```systemverilog
p_lsu_translation_ppn_integrity: assert property (
  @(posedge clk_i)
  disable iff (!rst_ni || any_flush)

  lsu_hit_packet_valid_q &&
  lsu_clean_terminal

  |->
  lsu_hit_ppn_q == lsu_true_ppn
);
```

Its meaning is:

> If the MMU reported a translated DTLB hit in Cycle 0 and the corresponding LSU transaction successfully completes in Cycle 1, then the PPN advertised in Cycle 0 must equal the PPN contained in the final physical address.

The property is intentionally generic.

It does not contain special exceptions for:

- 4 KiB pages,
- 2 MiB pages,
- 1 GiB pages,
- S-stage translation,
- G-stage translation,
- two-stage translation.

A correct effective PPN must be correct for all of them.

---

## 14. Capture-Sanity Property

A second assertion validates the scoreboard itself.

```systemverilog
p_lsu_hit_packet_capture_sanity: assert property (
  @(posedge clk_i)
  disable iff (!rst_ni || any_flush)

  lsu_hit_event

  |=>

  lsu_hit_packet_valid_q &&

  (lsu_hit_ppn_q ==
      $past(lsu_dtlb_ppn_o)) &&

  (lsu_hit_expected_paddr_q ==
      {
        $past(lsu_dtlb_ppn_o),
        $past(lsu_vaddr_i[11:0])
      })
);
```

This property must hold.

It proves that:

1. the scoreboard captured the actual PPN exposed by the MMU in the DTLB-hit cycle;
2. the scoreboard did not accidentally capture the next or previous transaction;
3. the expected physical address was built using that exact PPN and the original page offset.

This creates a strong verification argument:

```text
Capture sanity
      HOLD
       +
PPN integrity
      FAIL
       =
Actual RTL inconsistency
```

rather than a scoreboard timing problem.

---

## 15. Historical LSU Superpage Bug

The old MMU implementation contains the following 1 GiB superpage reconstruction:

```systemverilog
if (dtlb_is_page_q[0]) begin
  lsu_dtlb_ppn_o[PPNWMin:12] =
      lsu_vaddr_n[PPNWMin:12];

  lsu_paddr_o[PPNWMin:12] =
      lsu_vaddr_q[PPNWMin:12];
end
```

The assignment to:

```systemverilog
lsu_paddr_o
```

uses physical-address bit positions and is conceptually correct.

The problem is that:

```systemverilog
lsu_dtlb_ppn_o
```

is not a complete address. It is already a PPN.

For Sv39, a 1 GiB superpage requires:

```text
Virtual-address bits VA[29:12]
        |
        v
Physical-address bits PA[29:12]
```

But in PPN coordinates:

```text
PA[12] -> PPN[0]
PA[29] -> PPN[17]
```

so the required mapping is:

```text
VA[29:12]
        |
        v
PPN[17:0]
```

The old implementation instead effectively performs:

```text
VA[29:12]
        |
        v
PPN[29:12]
```

which shifts the reconstructed PPN field by 12 positions.

A simple example is:

```text
Correct PPN = 0x1

Old RTL:
0x1 << 12 = 0x1000
```

The scoreboard detects exactly this inconsistency by comparing the early PPN with the PPN extracted from the final physical address.

---

## 16. RTL Correction for the PPN Bug

For the Cycle-0 effective PPN, current page-size information and PPN-relative indices must be used.

For a 1 GiB page:

```systemverilog
if (dtlb_is_page_n[0]) begin
  lsu_dtlb_ppn_o[PPNWMin-12:0] =
      lsu_vaddr_n[PPNWMin:12];
end
```

Conceptually for Sv39:

```systemverilog
lsu_dtlb_ppn_o[17:0] =
    lsu_vaddr_n[29:12];
```

The final Cycle-1 physical address continues to use full address positions:

```systemverilog
if (dtlb_is_page_q[0]) begin
  lsu_paddr_o[PPNWMin:12] =
      lsu_vaddr_q[PPNWMin:12];
end
```

The same principle applies to the 2 MiB case:

```text
VA[20:12] -> PA[20:12]

but

VA[20:12] -> PPN[8:0]
```

After correcting these destination indices, the expected verification result is:

```text
Buggy RTL
----------------
Capture sanity    HOLD
PPN integrity     FAIL

Corrected RTL
----------------
Capture sanity    HOLD
PPN integrity     HOLD
```

This provides a direct before/after validation of the fix.

---

## 17. Fetch Data Integrity

The fetch interface does not expose an equivalent early PPN.

Therefore the scoreboard uses a limited read-only observation of:

```text
itlb_lu_hit
itlb_content.ppn
itlb_g_content.ppn
itlb_is_page
```

These signals are used only to reconstruct the physical address selected by the current ITLB lookup.

The checker:

1. selects the S-stage or G-stage PPN;
2. appends the original 12-bit page offset;
3. applies the 2 MiB or 1 GiB superpage substitution;
4. compares the resulting expected address with:

```systemverilog
icache_areq_o.fetch_paddr
```

The assertion is:

```systemverilog
p_fetch_translation_data_integrity
```

This verifies consistency between the selected ITLB translation and the externally visible fetch physical address.

---

## 18. Hit-Response Timing

The scoreboard also verifies expected timing behavior.

For instruction fetch:

```systemverilog
p_fetch_itlb_hit_returns_terminal_same_cycle
```

checks that a translated ITLB hit produces a terminal fetch response in the same cycle.

For LSU passthrough operation:

```systemverilog
p_lsu_no_translation_reports_cycle0_hit
```

checks that when address translation is disabled, the MMU reports an immediate Cycle-0 DTLB hit.

The final LSU response itself is registered and appears in the following cycle.

---

## 19. MMU Liveness

Liveness verifies that the MMU does not leave an accepted request waiting forever.

The LSU bounded property is based directly on the external request interface rather than on the older `lsu_pending_q` tracker.

The current form is:

```systemverilog
p_lsu_mmu_liveness_30: assert property (
  @(posedge clk_i)
  disable iff (!rst_ni || any_flush)

  $rose(lsu_req_i) &&
  !lsu_terminal &&
  !misaligned_ex_i.valid

  |->
  ##[1:PTW_TO_RESPONSE_MAX]
  lsu_terminal
);
```

Despite the historical property name containing `_30`, the current bound is:

```systemverilog
PTW_TO_RESPONSE_MAX =
    PTW_MAX_LATENCY +
    RESPONSE_MARGIN +
    5;
```

With:

```text
PTW_MAX_LATENCY = 54
RESPONSE_MARGIN = 2
```

the resulting bound is:

```text
61 cycles
```

The reason for using a bound larger than 30 cycles is that the real PTW is retained and can perform:

- three-level Sv39 walks,
- G-stage walks,
- two-stage translation,
- multiple memory transactions,
- shared-TLB and private-TLB refill.

A fixed 30-cycle requirement was therefore too aggressive for all legal paths.

---

## 20. Meaning of the Liveness Property

The property states:

> A new aligned LSU request that has not already terminated must produce an LSU terminal response within the selected MMU/PTW bound, unless reset or a flush cancels the transaction.

A terminal LSU response is:

```systemverilog
lsu_terminal = lsu_valid_o;
```

and includes both:

```text
successful translation
or
exception response
```

The liveness property therefore does not require every request to translate successfully.

It requires the MMU to **finish** the request.

---

## 21. Liveness Assumptions

Liveness cannot be proven without assumptions about the surrounding environment.

The important assumptions are:

### Stable Request

While a request is waiting, its address and architectural translation context remain stable.

### Memory Fairness

PTW memory requests eventually receive:

```text
grant
and
response data
```

### Flush Semantics

A flush cancels the corresponding liveness obligation.

These assumptions do not assume that the MMU will return a result. They only prevent the environment from creating impossible situations such as:

```text
request changes halfway through a page walk
```

or:

```text
memory never responds
```

The MMU still has to prove that it progresses from the stable request to a terminal response.

---

## 22. Fetch Liveness

Fetch liveness follows the same end-to-end principle.

A fetch that terminates immediately does not require a liveness obligation.

For a fetch request that must wait, the desired bounded property is:

```systemverilog
$rose(fetch_request) &&
!fetch_terminal

|->
##[1:PTW_TO_RESPONSE_MAX]
fetch_terminal
```

Fetch requires one additional environment consideration.

The shared TLB gives the data-side request priority when ITLB and DTLB traffic compete. Therefore permanent LSU traffic could theoretically starve instruction translation.

A fetch-liveness proof must either:

- verify the actual arbitration fairness separately, or
- assume that unrelated LSU traffic does not permanently starve a waiting fetch request.

This assumption concerns arbitration fairness, not translation correctness.

---

## 23. Liveness Non-Vacuity Covers

Several covers are used so that a green assertion is not interpreted without confirming that the relevant scenario is reachable.

For LSU liveness:

```systemverilog
c_lsu_liveness_start_seen
```

proves that a valid liveness start is reachable.

```systemverilog
c_lsu_liveness_completion_seen
```

proves that at least one such request can complete within the selected bound.

An additional cover can demonstrate that legal requests exist which require more than 30 cycles.

This distinction is important:

```text
cover passes
=
there exists at least one valid execution

assertion holds
=
all valid executions satisfy the requirement
```

Therefore a passing completion cover does not by itself prove bounded liveness.

---

## 24. Functional Non-Vacuity Covers

The scoreboard also checks reachability of important MMU operating modes.

Fetch coverage includes:

```text
translation-disabled passthrough
S-stage hit
G-stage hit
two-stage hit
2 MiB page
1 GiB page
real PTW path
```

LSU coverage includes:

```text
S-stage hit
G-stage hit
two-stage hit
real PTW path
```

These covers were particularly important after enabling the real PTW.

When PMP was incorrectly configured, many translated-hit covers became unreachable. After setting:

```systemverilog
NrPMPEntries = 0;
```

the covers became reachable again, confirming that successful real PTW refill paths were active.

---

## 25. Why the Real PTW Is Intentionally Retained

Keeping the PTW concrete makes this proof stronger than the earlier black-box experiment.

A successful MMU proof now includes the real sequence:

```text
private TLB miss
      |
      v
shared TLB lookup
      |
      v
shared TLB miss
      |
      v
real PTW
      |
      v
page-table memory accesses
      |
      v
PTE processing
      |
      v
shared TLB refill
      |
      v
private TLB refill
      |
      v
retry / hit
      |
      v
external MMU response
```

The scoreboard does not need to model those stages.

It only checks that the externally visible transaction eventually returns consistent data.

---

## 26. OneSpin Integration

The OneSpin flow loads exact local copies of the main MMU RTL:

```tcl
read_sv $WORK_ROOT/cva6_tlb.sv
read_sv $WORK_ROOT/cva6_shared_tlb.sv
read_sv $WORK_ROOT/cva6_ptw.sv
read_sv $WORK_ROOT/cva6_mmu.sv
```

This avoids accidentally verifying a different repository copy or branch.

The formal package is loaded before the formal top and scoreboard:

```tcl
read_sv $WORK_ROOT/cva6_mmu_formal_pkg.sv
read_sv $WORK_ROOT/cva6_mmu_formal_top.sv
read_sv $WORK_ROOT/cva6_mmu_scoreboard_final.sv
```

The MMU is elaborated as the top-level formal design.

Importantly, there is **no PTW black-box option** in the final flow.

The resulting proof therefore contains the actual:

```text
TLBs + shared TLB + PTW + MMU
```

implementation.

---

## 27. Historical Debugging Lessons

Several important issues were found while developing the scoreboard.

### PTW Black-Boxing

Leaving the PTW black-boxed without a contract allowed unrealistic refill behavior. The final methodology therefore uses the real PTW.

### PMP Zeroing

Tying PMP inputs to zero was not equivalent to disabling PMP when `NrPMPEntries` was nonzero.

This caused successful PTW translations to become unreachable.

The correct solution was:

```systemverilog
NrPMPEntries = 0;
```

### Request Tracking

Early versions used:

```systemverilog
lsu_pending_q
```

as the primary transaction owner.

Counterexamples showed that this could start a liveness obligation after a response had already occurred.

The final liveness trigger was therefore moved toward the actual request interface.

### Combined `$rose()` Expressions

Using:

```systemverilog
$rose(
    request &&
    translation_enabled &&
    !hit
)
```

was incorrect as a request-start detector.

The expression can rise because any component changes even when the request itself does not.

The liveness trigger therefore uses:

```systemverilog
$rose(lsu_req_i)
```

instead.

### S/G Translation-Mode Stability

The RTL uses the current G-stage enable when selecting both early and registered translation information.

Allowing the environment to change this control between Cycle 0 and Cycle 1 created false data-integrity counterexamples.

A local assumption therefore keeps the translation mode stable across the hit/response boundary.

---

## 28. What the Scoreboard Establishes

When the properties hold, except for the deliberately targeted old RTL bug, the verification establishes that:

- translation-disabled fetch behavior is correct;
- translation-disabled LSU behavior reports an immediate DTLB hit;
- translated instruction hits produce the correct externally visible physical address;
- instruction ITLB hits terminate in the expected cycle;
- the scoreboard correctly captures the LSU Cycle-0 PPN;
- the LSU Cycle-0 PPN agrees with the PPN contained in the successful Cycle-1 physical address;
- real PTW paths are reachable;
- S-stage, G-stage, and two-stage translation modes are reachable;
- 2 MiB and 1 GiB superpage behavior is reachable;
- the historical LSU PPN-position bug is exposed on the old RTL;
- the RTL correction can be validated by rerunning the same property;
- under bounded memory and stable-request assumptions, LSU requests are required to make bounded progress.

---

## 29. What the Scoreboard Does Not Establish

This scoreboard is not a complete independent specification of virtual memory.

It does not independently prove that:

- every page-table entry contains the architecturally correct mapping;
- PTW PTE parsing is equivalent to an external software page-table model;
- PMP behavior is correct;
- TLB replacement policy is optimal or fair;
- every possible external requester protocol is legal;
- arbitrary back-to-back requests are uniquely identifiable without a request ID;
- instruction-vs-data arbitration is fair without additional assumptions.

These functions can be verified by separate property groups if required.

The scoreboard instead verifies **interface-level consistency, response timing, propagation integrity, and progress** while allowing the real MMU implementation to perform the translation.

---

## 30. Final Verification Argument

The overall methodology can be summarized as:

```text
Real request
    |
    v
Stable architectural context
    |
    v
Real ITLB / DTLB
    |
    v
Real shared TLB
    |
    v
Real PTW
    |
    v
Real refill path
    |
    v
Real MMU response
    |
    v
Scoreboard checks externally visible consistency
```

For the historical LSU bug specifically:

```text
Cycle 0
DTLB hit
lsu_dtlb_ppn_o
        |
        v
Scoreboard captures PPN
        |
        v
Capture sanity property HOLDS

Cycle 1
lsu_paddr_o
        |
        v
Extract final PPN
        |
        v
Captured PPN != final PPN
        |
        v
Data-integrity property FAILS
```

Inspection of the old RTL then explains the failure:

```text
VA[29:12]
was written into
PPN[29:12]

instead of
PPN[17:0]
```

which shifts the effective superpage PPN field by twelve positions.

The same scoreboard can then be rerun on the corrected RTL.

The expected final result is:

```text
Old RTL:
Capture sanity       HOLD
PPN integrity        FAIL

Fixed RTL:
Capture sanity       HOLD
PPN integrity        HOLD
```

This provides a direct formal demonstration both of the historical defect and of the correctness of its repair.
