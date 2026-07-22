// cva6_mmu_scoreboard_bind_hold_v1.sv
// -----------------------------------------------------------------------------
// First MMU scoreboard using a concrete external requester model.
//
// Methodology:
//   - Keep the DUT mostly black-box: use only cva6_mmu interface ports.
//   - Do not use internal ITLB/DTLB/shared-TLB/PTW signals.
//   - Do not verify PMP behavior in this first milestone. PMP is tied benignly
//     in the formal top; this checker also avoids PMP-specific conclusions.
//   - Model the LSU requester concretely as HOLDING a pending translation
//     request stable after a DTLB miss until hit, exception, flush, or reset.
//   - Provide a simple legal page-table memory environment through the PTW
//     memory interface so that a miss can be refilled.
//
// Key black-box assertion:
//   If cycle N exposes a successful DTLB hit PPN, then the successful cycle N+1
//   physical address must use the same PPN.
// -----------------------------------------------------------------------------

module cva6_mmu_scoreboard_bind
  import ariane_pkg::*;
  import cva6_mmu_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic enable_translation_i,
    input logic enable_g_translation_i,
    input logic en_ld_st_translation_i,
    input logic en_ld_st_g_translation_i,

    input icache_arsp_t icache_areq_i,
    input icache_areq_t icache_areq_o,

    input cva6_mmu_formal_pkg::exception_t misaligned_ex_i,
    input logic lsu_req_i,
    input logic [CVA6Cfg.VLEN-1:0] lsu_vaddr_i,
    input logic [31:0] lsu_tinst_i,
    input logic lsu_is_store_i,
    input logic csr_hs_ld_st_inst_o,

    input logic lsu_dtlb_hit_o,
    input logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,
    input logic lsu_valid_o,
    input logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,
    input cva6_mmu_formal_pkg::exception_t lsu_exception_o,

    input riscv::priv_lvl_t priv_lvl_i,
    input logic v_i,
    input riscv::priv_lvl_t ld_st_priv_lvl_i,
    input logic ld_st_v_i,
    input logic sum_i,
    input logic vs_sum_i,
    input logic mxr_i,
    input logic vmxr_i,
    input logic mbe_i,
    input logic hlvx_inst_i,
    input logic hs_ld_st_inst_i,

    input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i,

    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    input logic [CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i,

    input logic flush_tlb_i,
    input logic flush_tlb_vvma_i,
    input logic flush_tlb_gvma_i,

    input logic itlb_miss_o,
    input logic dtlb_miss_o,

    input dcache_req_o_t req_port_i,
    input dcache_req_i_t req_port_o
);

  // ---------------------------------------------------------------------------
  // Types and helper wires.
  // ---------------------------------------------------------------------------

  typedef logic [CVA6Cfg.VLEN-1:12]      vpn_t;
  typedef logic [CVA6Cfg.PPNW-1:0]       ppn_t;
  typedef logic [CVA6Cfg.ASID_WIDTH-1:0] asid_t;
  typedef logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_t;

  wire instr_translation_enabled;
  wire lsu_translation_enabled;
  wire any_flush;

  assign instr_translation_enabled = enable_translation_i || enable_g_translation_i;
  assign lsu_translation_enabled   = en_ld_st_translation_i || en_ld_st_g_translation_i;
  assign any_flush = flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;

  // Phase-1 focus: normal S-stage LSU translation only. RVH/HYP_EXT can still
  // be compiled in; this checker simply constrains traffic away from G-stage.
  wire phase1_lsu_req;
  assign phase1_lsu_req =
      en_ld_st_translation_i &&
      !en_ld_st_g_translation_i &&
      lsu_req_i &&
      !misaligned_ex_i.valid;

  logic past_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) past_valid_q <= 1'b0;
    else         past_valid_q <= 1'b1;
  end

  function automatic logic [CVA6Cfg.PLEN-1:0] truncate_vaddr_to_paddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    truncate_vaddr_to_paddr =
        CVA6Cfg.PLEN'(vaddr[((CVA6Cfg.PLEN > CVA6Cfg.VLEN) ?
                              CVA6Cfg.VLEN - 1 : CVA6Cfg.PLEN - 1):0]);
  endfunction

  function automatic ppn_t ppn_from_vaddr_passthrough(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    ppn_from_vaddr_passthrough =
        ppn_t'(vaddr[((CVA6Cfg.PLEN > CVA6Cfg.VLEN) ?
                       CVA6Cfg.VLEN - 1 : CVA6Cfg.PLEN - 1):12]);
  endfunction

  function automatic ppn_t ppn_from_paddr(
      input logic [CVA6Cfg.PLEN-1:0] paddr
  );
    ppn_from_paddr = ppn_t'(paddr[CVA6Cfg.PLEN-1:12]);
  endfunction

  function automatic vpn_t vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[CVA6Cfg.VLEN-1:12];
  endfunction

  function automatic logic is_sv39_canonical(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    is_sv39_canonical =
      ((&vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.SV-1]) == 1'b1) ||
      ((|vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.SV-1]) == 1'b0);
  endfunction

  // Legal leaf PTE returned by the black-box PTW memory environment.
  // This intentionally creates a legal root-level leaf for Sv39, i.e. a 1 GiB
  // superpage, with PPN lower bits aligned to zero. This is useful for exposing
  // the old same-cycle lsu_dtlb_ppn_o superpage shift bug.
  function automatic logic [CVA6Cfg.XLEN-1:0] make_legal_leaf_pte();
    pte_cva6_t pte;
    begin
      pte = '0;
      pte.v = 1'b1;  // valid
      pte.r = 1'b1;  // readable
      pte.w = 1'b1;  // writable
      pte.x = 1'b1;  // executable
      pte.a = 1'b1;  // accessed
      pte.d = 1'b1;  // dirty
      pte.u = 1'b0;  // supervisor page
      pte.g = 1'b0;
      pte.n = 1'b0;  // no NAPOT in phase 1
      pte.ppn = '0;  // aligned superpage-safe PPN
      make_legal_leaf_pte = CVA6Cfg.XLEN'(pte);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // LSU requester HOLD model.
  // ---------------------------------------------------------------------------
  // Meaning:
  //   Once an LSU translated request misses the DTLB, the external requester
  //   keeps the same request active and stable until one event occurs:
  //     - a DTLB hit becomes visible,
  //     - a translation exception becomes visible,
  //     - a flush/reset cancels the request.

  logic  lsu_waiting_for_translation_q;
  logic [CVA6Cfg.VLEN-1:0] held_lsu_vaddr_q;
  logic  held_lsu_is_store_q;
  asid_t held_asid_q;
  vmid_t held_vmid_q;
  riscv::priv_lvl_t held_ld_st_priv_lvl_q;
  logic [CVA6Cfg.PPNW-1:0] held_satp_ppn_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_waiting_for_translation_q <= 1'b0;
      held_lsu_vaddr_q              <= '0;
      held_lsu_is_store_q           <= 1'b0;
      held_asid_q                   <= '0;
      held_vmid_q                   <= '0;
      held_ld_st_priv_lvl_q         <= riscv::PRIV_LVL_M;
      held_satp_ppn_q               <= '0;
    end else begin
      if (any_flush) begin
        lsu_waiting_for_translation_q <= 1'b0;
      end else if (phase1_lsu_req && !lsu_dtlb_hit_o && !lsu_waiting_for_translation_q) begin
        lsu_waiting_for_translation_q <= 1'b1;
        held_lsu_vaddr_q              <= lsu_vaddr_i;
        held_lsu_is_store_q           <= lsu_is_store_i;
        held_asid_q                   <= asid_i;
        held_vmid_q                   <= vmid_i;
        held_ld_st_priv_lvl_q         <= ld_st_priv_lvl_i;
        held_satp_ppn_q               <= satp_ppn_i;
      end else if (phase1_lsu_req && lsu_dtlb_hit_o) begin
        lsu_waiting_for_translation_q <= 1'b0;
      end else if (lsu_valid_o && lsu_exception_o.valid) begin
        lsu_waiting_for_translation_q <= 1'b0;
      end
    end
  end

  // Track one-cycle LSU hit packet for response properties.
  logic lsu_hit_event_q;
  logic [CVA6Cfg.VLEN-1:0] hit_lsu_vaddr_q;
  ppn_t hit_lsu_ppn_q;

  wire lsu_hit_event;
  assign lsu_hit_event =
      phase1_lsu_req &&
      lsu_dtlb_hit_o &&
      !any_flush;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_hit_event_q <= 1'b0;
      hit_lsu_vaddr_q <= '0;
      hit_lsu_ppn_q   <= '0;
    end else begin
      if (any_flush) begin
        lsu_hit_event_q <= 1'b0;
      end else begin
        lsu_hit_event_q <= lsu_hit_event;
        if (lsu_hit_event) begin
          hit_lsu_vaddr_q <= lsu_vaddr_i;
          hit_lsu_ppn_q   <= lsu_dtlb_ppn_o;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // A. Environment constraints for first milestone.
  // ---------------------------------------------------------------------------

  // Keep the first proof focused on LSU, not IF/shared arbitration.
  a_phase1_no_fetch_traffic: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !icache_areq_i.fetch_req
  );

  // Normal S-stage only. Hypervisor hardware remains compiled in, but traffic is
  // not G-stage or virtualized for this first milestone.
  a_phase1_normal_s_stage_only: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !enable_g_translation_i &&
    !en_ld_st_g_translation_i &&
    !v_i &&
    !ld_st_v_i &&
    !flush_tlb_vvma_i &&
    !flush_tlb_gvma_i
  );

  // No flush during this first translation-integrity scenario.
  a_phase1_no_flush: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !flush_i && !flush_tlb_i
  );

  // Keep optional/special behavior disabled.
  a_phase1_simple_controls: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !mbe_i &&           // little-endian PTE interpretation
    !hlvx_inst_i &&
    !hs_ld_st_inst_i
  );

  // Use supervisor mode with the supervisor leaf PTE returned below.
  a_phase1_supervisor_privilege: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    priv_lvl_i == riscv::PRIV_LVL_S &&
    ld_st_priv_lvl_i == riscv::PRIV_LVL_S
  );

  // Avoid canonical-address page faults for translated requests.
  a_phase1_lsu_vaddr_canonical: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    phase1_lsu_req
    |->
    is_sv39_canonical(lsu_vaddr_i)
  );

  // For the superpage-bug experiment, make sure the VA has nonzero bits in the
  // 1 GiB superpage substitution range. This avoids a trivial all-zero case that
  // could hide the old shift bug.
  a_phase1_nontrivial_superpage_offset: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    phase1_lsu_req
    |->
    (lsu_vaddr_i[29:12] != '0)
  );

  // Concrete HOLD assumption.
  a_lsu_holds_request_after_miss_until_terminal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_waiting_for_translation_q
    |->
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    (lsu_vaddr_i       == held_lsu_vaddr_q) &&
    (lsu_is_store_i    == held_lsu_is_store_q) &&
    (asid_i            == held_asid_q) &&
    (vmid_i            == held_vmid_q) &&
    (ld_st_priv_lvl_i  == held_ld_st_priv_lvl_q) &&
    (satp_ppn_i        == held_satp_ppn_q)
  );

  // PTW memory/cache environment. Use tag_valid to model the PTW request/return
  // phase more accurately than data_req alone.
  a_ptw_request_gets_grant: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req
    |->
    req_port_i.data_gnt
  );

  a_ptw_tag_valid_gets_rvalid_next_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.tag_valid
    |=>
    req_port_i.data_rvalid
  );

  a_ptw_rvalid_only_after_tag_valid: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_rvalid
    |->
    $past(req_port_o.tag_valid)
  );

  a_ptw_returns_legal_leaf_pte: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_rvalid
    |->
    req_port_i.data_rdata == make_legal_leaf_pte()
  );

  // ---------------------------------------------------------------------------
  // B. Basic pass-through and availability properties.
  // ---------------------------------------------------------------------------

  p_fetch_passthrough_when_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !instr_translation_enabled
    |->
    (icache_areq_o.fetch_valid == icache_areq_i.fetch_req) &&
    (icache_areq_o.fetch_paddr == truncate_vaddr_to_paddr(icache_areq_i.fetch_vaddr)) &&
    !icache_areq_o.fetch_exception.valid
  );

  p_lsu_dtlb_hit_high_when_lsu_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !lsu_translation_enabled
    |->
    lsu_dtlb_hit_o
  );

  p_lsu_dtlb_ppn_passthrough_when_lsu_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !lsu_translation_enabled && lsu_dtlb_hit_o
    |->
    lsu_dtlb_ppn_o == ppn_from_vaddr_passthrough(lsu_vaddr_i)
  );

  p_lsu_passthrough_response_when_lsu_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(!lsu_translation_enabled && lsu_req_i && !misaligned_ex_i.valid) &&
    !lsu_translation_enabled
    |->
    lsu_valid_o &&
    !lsu_exception_o.valid &&
    (lsu_paddr_o == truncate_vaddr_to_paddr($past(lsu_vaddr_i)))
  );

  p_misaligned_lsu_request_returns_exception_next_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q && lsu_req_i && misaligned_ex_i.valid
    |=>
    lsu_valid_o &&
    lsu_exception_o.valid &&
    (lsu_exception_o.cause == $past(misaligned_ex_i.cause))
  );

  p_lsu_dtlb_hit_gives_next_cycle_response: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q && lsu_hit_event
    |=>
    lsu_valid_o
  );

  // ---------------------------------------------------------------------------
  // C. Visible LSU translation consistency properties.
  // ---------------------------------------------------------------------------

  p_lsu_success_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    lsu_hit_event_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    lsu_paddr_o[11:0] == hit_lsu_vaddr_q[11:0]
  );

  // Main historical-bug assertion.
  // If cycle N reports a DTLB hit with lsu_dtlb_ppn_o, then a successful cycle
  // N+1 response must use exactly that same physical page number.
  p_lsu_dtlb_ppn_matches_next_paddr_on_success: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    lsu_hit_event_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    ppn_from_paddr(lsu_paddr_o) == hit_lsu_ppn_q
  );

  // ---------------------------------------------------------------------------
  // D. Covers for reachability and bug exposure.
  // ---------------------------------------------------------------------------

  c_reset_released_seen: cover property (
    @(posedge clk_i)
    rst_ni && past_valid_q
  );

  c_lsu_translated_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    phase1_lsu_req
  );

  c_lsu_translated_dtlb_miss_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    phase1_lsu_req && !lsu_dtlb_hit_o
  );

  c_ptw_real_memory_transaction_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req && req_port_i.data_gnt
    ##[1:20]
    req_port_o.tag_valid
    ##1
    req_port_i.data_rvalid &&
    (req_port_i.data_rdata == make_legal_leaf_pte())
  );

c_lsu_miss_refill_hold_hit_seen: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q &&
  phase1_lsu_req &&
  !lsu_dtlb_hit_o
  ##[1:80]
  req_port_o.data_req &&
  req_port_i.data_gnt
  ##[1:20]
  req_port_o.tag_valid
  ##1
  req_port_i.data_rvalid &&
  (req_port_i.data_rdata == make_legal_leaf_pte())
  ##[1:250]
  phase1_lsu_req &&
  lsu_dtlb_hit_o
  ##1
  lsu_valid_o &&
  !lsu_exception_o.valid
);

c_lsu_dtlb_hit_seen: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q &&
  phase1_lsu_req &&
  lsu_dtlb_hit_o
  ##1
  lsu_valid_o
);

  // Visible symptom of the old superpage PPN-shift bug. With the main assertion
  // active, the design should fail the assertion before this cover is needed;
  // this cover is useful when debugging or running covers separately.
  c_old_superpage_ppn_shift_bug_exposed: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    lsu_hit_event_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid &&
    (ppn_from_paddr(lsu_paddr_o) != hit_lsu_ppn_q)
  );

endmodule

bind cva6_mmu cva6_mmu_scoreboard_bind i_cva6_mmu_scoreboard_bind (.*);
