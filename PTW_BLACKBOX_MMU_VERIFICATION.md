# CVA6 MMU Verification with a Black-Box PTW

## 1. Objective

The purpose of this verification stage is to prove the externally visible behavior of the CVA6 Memory Management Unit (MMU) without repeatedly exploring the full implementation of the Page-Table Walker (PTW).

The verified design still contains the real:

- instruction Translation Lookaside Buffer (ITLB),
- data Translation Lookaside Buffer (DTLB),
- shared Translation Lookaside Buffer (shared TLB),
- MMU control and address-construction logic.

Only the PTW implementation is black-boxed. Its behavior is replaced by a constrained formal contract.

The principal bug target is the historical superpage bug in `lsu_dtlb_ppn_o`. In the old implementation, virtual-address bits were written into the Page-Page Number (PPN) output using full physical-address bit positions. The result could be wrong in the DTLB-hit cycle even when the final physical address was corrected one cycle later.

## 2. Why the PTW is black-boxed

The real PTW contains substantial state and control complexity:

- page-table-level traversal,
- memory request, grant, tag, and response sequencing,
- Page-Table Entry (PTE) parsing,
- permission checks,
- Accessed and Dirty bit checks,
- superpage-alignment checks,
- hypervisor stage transitions,
- Physical Memory Protection (PMP) access checks,
- error and kill paths.

When the complete PTW is included in every MMU proof, the formal engine must repeatedly solve all of this behavior before reaching a private-TLB refill and a visible MMU response.
This produces deep traces and a large state space even though the current properties are intended to verify MMU integration rather than PTW internals.

The PTW has already been treated as a separate verification target. Therefore, compositional verification is appropriate:

1. The real PTW is verified independently against its own contract.
2. The MMU proof assumes that contract at the PTW boundary.
3. The MMU proof verifies that a legal PTW result is correctly propagated through the real shared TLB, the real private TLBs, and the external MMU interfaces.

This is an assume-guarantee decomposition. It is not equivalent to leaving the PTW outputs unconstrained.

## 3. Why an unconstrained black box is unsafe

A plain black box has symbolic outputs. Without assumptions, it could legally produce impossible behavior, for example:

- an update without a preceding miss,
- an update for a different virtual address,
- an arbitrary ASID or VMID,
- invalid or contradictory PTE permission bits,
- repeated updates every cycle,
- an update and an error at the same time,
- no response forever.

Such behavior could create false counterexamples or false reachability. The black-box contract therefore restricts the symbolic PTW outputs to behaviors that represent a legal successful walk.

## 4. Verification architecture

The new SystemVerilog file contains two checkers.

### 4.1 PTW black-box contract

`cva6_ptw_blackbox_contract` is bound directly to the `cva6_ptw` module boundary.

It observes the miss request entering the PTW and constrains the black-box outputs. For each accepted shared-TLB miss, it records:

- whether the request came from the instruction side or LSU side,
- the virtual address,
- the ASID,
- the VMID,
- the LSU load/store information.

The contract then requires:

- only one outstanding walk,
- no spontaneous update or error,
- an update within a bounded abstract latency,
- `ptw_active_o` while a walk is pending,
- `walking_instr_o` to match the remembered requester,
- update virtual page, ASID, and VMID to match the remembered miss,
- a legal readable, writable, executable, accessed, and dirty supervisor PTE,
- an aligned root-level superpage,
- a one-cycle update pulse.

The PPN upper bits remain symbolic and are constrained to be nonzero. The lower PPN bits are aligned to zero for a legal root-level Sv39 superpage. This is intentional: an all-zero PPN could hide the historical PPN-substitution bug.

### 4.2 External MMU scoreboard

`cva6_mmu_scoreboard_bind` is bound to the `cva6_mmu` interface.

It does not use private-TLB contents or update packets. It verifies what the requester can observe:

- fetch validity and physical address,
- LSU DTLB hit and same-cycle PPN,
- next-cycle LSU valid and physical address,
- exceptions,
- translation-disabled passthrough behavior.

The real shared TLB and private TLB implementations remain part of the proof. Consequently, the proof still checks that the abstract legal PTW update is correctly consumed by the actual refill path.

## 5. Concrete requester behavior: HOLD

The requester behavior is modeled as **hold**, not as separate retry pulses.

### 5.1 LSU

After a translated LSU request misses the DTLB, the requester keeps the following signals stable and asserted every cycle:

- `lsu_req_i = 1`,
- `lsu_vaddr_i`,
- `lsu_is_store_i`,
- `asid_i`,
- `vmid_i`,
- `ld_st_priv_lvl_i`,
- `satp_ppn_i`,
- translation-enable state.

The hold ends only when one of the following occurs:

- `lsu_dtlb_hit_o` becomes high,
- a translation exception is returned,
- a flush occurs,
- reset occurs.

This model is necessary because the MMU LSU interface has no separate ready/accept handshake that would allow the MMU to retain an arbitrary request independently of the requester.

### 5.2 Instruction fetch

After a translated instruction fetch has neither `fetch_valid` nor an immediate exception, the frontend holds:

- `fetch_req = 1`,
- `fetch_vaddr`,
- `asid_i`,
- `vmid_i`,
- `priv_lvl_i`,
- `satp_ppn_i`,
- translation-enable state.

The hold ends when a valid fetch response or fetch exception appears, or on flush/reset.

## 6. Abstract latency

The PTW contract uses a bounded abstract latency, for example one to eight cycles. This is not a statement about the physical PTW latency. It is a formal abstraction that represents eventual successful completion while removing the page-walk implementation depth.

Architectural timing after the private-TLB hit is not abstracted:

- instruction success remains a same-cycle ITLB response,
- `lsu_dtlb_hit_o` and `lsu_dtlb_ppn_o` remain Cycle-0 outputs,
- `lsu_valid_o` and `lsu_paddr_o` remain Cycle-1 outputs.

## 7. Scope restrictions

The first milestone intentionally constrains:

- normal S-stage translation only,
- no G-stage or virtualized translation traffic,
- supervisor privilege,
- little-endian PTE interpretation,
- no HLVX special access,
- no simultaneous instruction and LSU request,
- no flush while a request is pending,
- successful PTW completion only,
- PMP behavior outside the proof scope.

These restrictions isolate the core translation/refill/address-integrity behavior. They should be relaxed incrementally in later verification stages.

## 8. Main properties

### 8.1 LSU hit response timing

A translated LSU request that hits the DTLB must produce `lsu_valid_o` in the next cycle.

### 8.2 Page-offset integrity

For a successful translation, physical-address bits `[11:0]` must equal the original virtual-address offset.

### 8.3 Historical PPN bug property

The main property compares the Cycle-0 LSU PPN with the PPN extracted from the successful Cycle-1 physical address:

```systemverilog
ppn_from_paddr(lsu_paddr_o) == $past(lsu_dtlb_ppn_o)
```

For a correct MMU, both outputs describe the same translated physical page. The old superpage implementation can violate this because `lsu_dtlb_ppn_o` substitutes virtual-address bits at positions shifted by twelve, while the final physical address uses the correct positions.

### 8.4 Instruction offset integrity

A successful translated fetch must preserve the page offset from the fetch virtual address.

### 8.5 Progress

A held request must eventually terminate in either a hit/success response or an exception within the selected proof bound.

## 9. Non-vacuity covers

The following covers should be checked before interpreting assertion results:

- abstract PTW miss and update observed,
- LSU miss observed,
- LSU miss, hold, refill, DTLB hit, and successful response observed,
- instruction miss, hold, refill, and successful response observed,
- historical PPN mismatch observed on the old buggy implementation.

If the basic refill covers remain unreachable, the PTW black-box command, contract bind, or phase assumptions must be inspected before relying on passing assertions.

## 10. OneSpin integration

The intended OneSpin flow is:

1. Analyze the formal package, MMU RTL, TLB RTL, shared-TLB RTL, and this scoreboard.
2. Elaborate the MMU formal top.
3. Mark only the PTW implementation as a black box.
4. Keep the PTW module ports visible so the bound contract can constrain them.
5. Keep the private TLB and shared TLB concrete.
6. Run the contract cover first.
7. Run the MMU refill covers.
8. Run the external MMU assertions.

The exact OneSpin black-box command depends on the installed OneSpin version and TCL command set. The selected object must be the PTW instance or module implementation, not the complete MMU hierarchy.

## 11. What this proof establishes

A successful result establishes that, under the separately verified PTW contract:

- the MMU accepts a legal PTW translation result,
- the real shared TLB/private TLB refill path makes it available,
- held instruction and LSU requests eventually complete,
- visible physical addresses preserve the page offset,
- the LSU same-cycle PPN agrees with the next-cycle physical address,
- the historical superpage PPN-construction bug is exposed by the old RTL.

## 12. What this proof does not establish

This run does not re-prove:

- real PTW state transitions,
- page-table memory protocol,
- PTE parsing correctness,
- multi-level traversal correctness,
- PTW PMP checks,
- PTW error classification,
- G-stage/VS-stage translation,
- simultaneous ITLB/DTLB arbitration,
- flush semantics.

Those functions require separate proof groups or later extensions of the contract and scoreboard.
