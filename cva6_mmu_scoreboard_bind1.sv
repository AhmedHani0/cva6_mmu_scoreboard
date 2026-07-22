// cva6_mmu_scoreboard_bind.sv
// -----------------------------------------------------------------------------
// First-step black-box scoreboard for standalone CVA6 MMU verification.
//
// Scope of this checker:
//   - Uses only cva6_mmu interface ports.
//   - Does not use private ITLB/DTLB, shared-TLB, or PTW internal signals.
//   - Does not care whether a successful translation came from private TLB,
//     shared TLB, or PTW refill.
//   - Does not verify PMP behavior in this first step.
//
// Main idea:
//   If the MMU globally exposes a successful translation response, the visible
//   address information must be self-consistent and stable for repeated accesses
//   to the same virtual page in the same context.
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
  // Local types and basic helper wires.
  // ---------------------------------------------------------------------------

  typedef logic [CVA6Cfg.VLEN-1:12]       vpn_t;
  typedef logic [CVA6Cfg.PPNW-1:0]        ppn_t;
  typedef logic [CVA6Cfg.ASID_WIDTH-1:0]  asid_t;
  typedef logic [CVA6Cfg.VMID_WIDTH-1:0]  vmid_t;

  wire instr_translation_enabled;
  wire lsu_translation_enabled;
  wire any_flush;

  assign instr_translation_enabled = enable_translation_i || enable_g_translation_i;
  assign lsu_translation_enabled   = en_ld_st_translation_i || en_ld_st_g_translation_i;
  assign any_flush = flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;

  wire asid_t if_effective_asid;
  wire asid_t lsu_effective_asid;

  assign if_effective_asid  = v_i       ? vs_asid_i : asid_i;
  assign lsu_effective_asid = ld_st_v_i ? vs_asid_i : asid_i;

  logic past_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      past_valid_q <= 1'b0;
    end else begin
      past_valid_q <= 1'b1;
    end
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

  function automatic logic [CVA6Cfg.XLEN-1:0] make_legal_leaf_pte();
    pte_cva6_t pte;
    begin
      pte = '0;

      // Legal leaf PTE:
      // V = valid
      // R/W/X = readable/writable/executable
      // A = accessed
      // D = dirty
      pte.v = 1'b1;
      pte.r = 1'b1;
      pte.w = 1'b1;
      pte.x = 1'b1;
      pte.a = 1'b1;
      pte.d = 1'b1;

      // Supervisor page, so supervisor accesses are allowed.
      pte.u = 1'b0;

      // No global, no NAPOT for this first phase.
      pte.g = 1'b0;
      pte.n = 1'b0;

      // Keep PPN aligned. This is important for root-level superpage legality.
      pte.ppn = '0;

      make_legal_leaf_pte = CVA6Cfg.XLEN'(pte);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Reachability helper for first successful DTLB hit. 
  //
  // This is not the final proof model. It is a cover-driving environment helper:
  // after a translated LSU miss, keep retrying the same request/context so that
  // a PTW/shared-TLB refill can become visible as a later private DTLB hit.
  // ---------------------------------------------------------------------------

  logic cover_wait_hit_q;
  logic [CVA6Cfg.VLEN-1:0] cover_lsu_vaddr_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] cover_asid_q;
  logic [CVA6Cfg.VMID_WIDTH-1:0] cover_vmid_q;
  logic cover_lsu_is_store_q;

  wire phase1_lsu_req;
  assign phase1_lsu_req =
      en_ld_st_translation_i &&
      !en_ld_st_g_translation_i &&
      lsu_req_i &&
      !misaligned_ex_i.valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cover_wait_hit_q     <= 1'b0;
      cover_lsu_vaddr_q    <= '0;
      cover_asid_q         <= '0;
      cover_vmid_q         <= '0;
      cover_lsu_is_store_q <= 1'b0;
    end else begin
      if (flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i) begin
        cover_wait_hit_q <= 1'b0;
      end else if (phase1_lsu_req && !lsu_dtlb_hit_o && !cover_wait_hit_q) begin
        cover_wait_hit_q     <= 1'b1;
        cover_lsu_vaddr_q    <= lsu_vaddr_i;
        cover_asid_q         <= asid_i;
        cover_vmid_q         <= vmid_i;
        cover_lsu_is_store_q <= lsu_is_store_i;
      end else if (phase1_lsu_req && lsu_dtlb_hit_o) begin
        cover_wait_hit_q <= 1'b0;
      end
    end
  end

  // A successful visible instruction translation. There is no top-level ITLB hit
  // signal, so we track only successful fetch responses exposed at the interface.
  wire fetch_success;
  assign fetch_success =
      !any_flush &&
      instr_translation_enabled &&
      icache_areq_i.fetch_req &&
      icache_areq_o.fetch_valid &&
      !icache_areq_o.fetch_exception.valid;

  // A Cycle-0 LSU DTLB-hit event exposed at the MMU interface.
  wire lsu_hit_event;
  assign lsu_hit_event =
      !any_flush &&
      lsu_translation_enabled &&
      lsu_req_i &&
      !misaligned_ex_i.valid &&
      lsu_dtlb_hit_o;

  
  // ---------------------------------------------------------------------------
  // B. Black-box tracking: instruction-side observed translations.
  // ---------------------------------------------------------------------------

  logic  tracked_if_valid_q;
  vpn_t  tracked_if_vpn_q;
  ppn_t  tracked_if_ppn_q;
  asid_t tracked_if_asid_q;
  vmid_t tracked_if_vmid_q;
  logic  tracked_if_s_stage_q;
  logic  tracked_if_g_stage_q;
  logic  tracked_if_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tracked_if_valid_q <= 1'b0;
      tracked_if_vpn_q   <= '0;
      tracked_if_ppn_q   <= '0;
      tracked_if_asid_q  <= '0;
      tracked_if_vmid_q  <= '0;
      tracked_if_s_stage_q <= 1'b0;
      tracked_if_g_stage_q <= 1'b0;
      tracked_if_v_q       <= 1'b0;
    end else begin
      if (any_flush) begin
        tracked_if_valid_q <= 1'b0;
      end else if (fetch_success) begin
        tracked_if_valid_q <= 1'b1;
        tracked_if_vpn_q   <= vpn_from_vaddr(icache_areq_i.fetch_vaddr);
        tracked_if_ppn_q   <= ppn_from_paddr(icache_areq_o.fetch_paddr);
        tracked_if_asid_q  <= if_effective_asid;
        tracked_if_vmid_q  <= vmid_i;
        tracked_if_s_stage_q <= enable_translation_i;
        tracked_if_g_stage_q <= enable_g_translation_i;
        tracked_if_v_q       <= v_i;
      end
    end
  end

  wire fetch_matches_tracked;
  assign fetch_matches_tracked =
      tracked_if_valid_q &&
      fetch_success &&
      (vpn_from_vaddr(icache_areq_i.fetch_vaddr) == tracked_if_vpn_q) &&
      (if_effective_asid == tracked_if_asid_q) &&
      (vmid_i == tracked_if_vmid_q) &&
      (enable_translation_i == tracked_if_s_stage_q) &&
      (enable_g_translation_i == tracked_if_g_stage_q) &&
      (v_i == tracked_if_v_q);

  // ---------------------------------------------------------------------------
  // C. Black-box tracking: LSU-side observed successful DTLB translations.
  // ---------------------------------------------------------------------------
  // We can only know whether a hit was successful after the Cycle-1 response.
  // Therefore, first remember the Cycle-0 hit packet, then promote it to the
  // tracked scoreboard entry only if Cycle-1 returns no exception.

  logic  lsu_hit_event_q;
  vpn_t  lsu_hit_vpn_q;
  ppn_t  lsu_hit_ppn_q;
  asid_t lsu_hit_asid_q;
  vmid_t lsu_hit_vmid_q;
  logic  lsu_hit_s_stage_q;
  logic  lsu_hit_g_stage_q;
  logic  lsu_hit_v_q;

  logic  tracked_lsu_valid_q;
  vpn_t  tracked_lsu_vpn_q;
  ppn_t  tracked_lsu_ppn_q;
  asid_t tracked_lsu_asid_q;
  vmid_t tracked_lsu_vmid_q;
  logic  tracked_lsu_s_stage_q;
  logic  tracked_lsu_g_stage_q;
  logic  tracked_lsu_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_hit_event_q <= 1'b0;
      lsu_hit_vpn_q   <= '0;
      lsu_hit_ppn_q   <= '0;
      lsu_hit_asid_q  <= '0;
      lsu_hit_vmid_q  <= '0;
      lsu_hit_s_stage_q <= 1'b0;
      lsu_hit_g_stage_q <= 1'b0;
      lsu_hit_v_q       <= 1'b0;

      tracked_lsu_valid_q <= 1'b0;
      tracked_lsu_vpn_q   <= '0;
      tracked_lsu_ppn_q   <= '0;
      tracked_lsu_asid_q  <= '0;
      tracked_lsu_vmid_q  <= '0;
      tracked_lsu_s_stage_q <= 1'b0;
      tracked_lsu_g_stage_q <= 1'b0;
      tracked_lsu_v_q       <= 1'b0;
    end else begin
      if (any_flush) begin
        lsu_hit_event_q <= 1'b0;
        tracked_lsu_valid_q <= 1'b0;
      end else begin
        // Promote previous Cycle-0 hit packet to a tracked translation only if
        // the Cycle-1 response is successful.
        if (lsu_hit_event_q && lsu_valid_o && !lsu_exception_o.valid) begin
          tracked_lsu_valid_q <= 1'b1;
          tracked_lsu_vpn_q   <= lsu_hit_vpn_q;
          tracked_lsu_ppn_q   <= lsu_hit_ppn_q;
          tracked_lsu_asid_q  <= lsu_hit_asid_q;
          tracked_lsu_vmid_q  <= lsu_hit_vmid_q;
          tracked_lsu_s_stage_q <= lsu_hit_s_stage_q;
          tracked_lsu_g_stage_q <= lsu_hit_g_stage_q;
          tracked_lsu_v_q       <= lsu_hit_v_q;
        end

        // Capture current Cycle-0 hit packet for next-cycle promotion.
        lsu_hit_event_q <= lsu_hit_event;
        if (lsu_hit_event) begin
          lsu_hit_vpn_q   <= vpn_from_vaddr(lsu_vaddr_i);
          lsu_hit_ppn_q   <= lsu_dtlb_ppn_o;
          lsu_hit_asid_q  <= lsu_effective_asid;
          lsu_hit_vmid_q  <= vmid_i;
          lsu_hit_s_stage_q <= en_ld_st_translation_i;
          lsu_hit_g_stage_q <= en_ld_st_g_translation_i;
          lsu_hit_v_q       <= ld_st_v_i;
        end
      end
    end
  end

  wire lsu_matches_tracked;
  assign lsu_matches_tracked =
      tracked_lsu_valid_q &&
      lsu_hit_event &&
      (vpn_from_vaddr(lsu_vaddr_i) == tracked_lsu_vpn_q) &&
      (lsu_effective_asid == tracked_lsu_asid_q) &&
      (vmid_i == tracked_lsu_vmid_q) &&
      (en_ld_st_translation_i == tracked_lsu_s_stage_q) &&
      (en_ld_st_g_translation_i == tracked_lsu_g_stage_q) &&
      (ld_st_v_i == tracked_lsu_v_q);


  // If the PTW requests memory, the black-box memory/cache grants it.
  a_ptw_request_gets_grant: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req
    |->
    req_port_i.data_gnt
  );
 
  // A granted PTW request gets a response next cycle.
  a_ptw_grant_gets_response_next_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req && req_port_i.data_gnt
    |=>
    req_port_i.data_rvalid
  );

  // The response data is a legal leaf PTE.
  a_ptw_returns_legal_leaf_pte: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_rvalid
    |->
    req_port_i.data_rdata == make_legal_leaf_pte()
  );

  a_phase1_normal_translation_only: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !enable_g_translation_i &&
    !en_ld_st_g_translation_i &&
    !v_i &&
    !ld_st_v_i &&
    !flush_tlb_vvma_i &&
    !flush_tlb_gvma_i
  );

  a_phase1_no_flush: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !flush_i &&
    !flush_tlb_i
  );

    a_lsu_context_stable_for_fill_experiment: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    en_ld_st_translation_i &&
    lsu_req_i
    |=>
    $stable(lsu_vaddr_i) &&
    $stable(asid_i) &&
    $stable(vmid_i) &&
    $stable(en_ld_st_translation_i)
  );

  // ---------------------------------------------------------------------------
  // A. Control/environment constraints for the first black-box phase.
  // ---------------------------------------------------------------------------
  // The LSU response is one cycle after the request. These controls must not
  // change between request and response, otherwise the environment is mixing two
  // different translation contexts for one LSU transaction.

  a_lsu_control_stable_during_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q && lsu_req_i
    |=>
    $stable(en_ld_st_translation_i) &&
    $stable(en_ld_st_g_translation_i) &&
    $stable(ld_st_v_i) &&
    $stable(ld_st_priv_lvl_i) &&
    $stable(sum_i) &&
    $stable(vs_sum_i)
  );

  // Keep the first step away from concurrent flush races. Flush behavior will be
  // verified separately. Here, a flush is allowed, but not in the exact request
  // to response window that we use for data-integrity comparison.
  a_no_flush_between_lsu_request_and_response: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q && lsu_req_i
    |=> !any_flush
  );

  // Keep phase 1 in normal S-stage translation.
  a_phase1_normal_s_stage_only: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !enable_g_translation_i &&
    !en_ld_st_g_translation_i &&
    !v_i &&
    !ld_st_v_i &&
    !flush_tlb_vvma_i &&
    !flush_tlb_gvma_i
  );

  // No flushes while trying to demonstrate refill/hit reachability.
  a_phase1_no_flush_for_hit_reachability: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !flush_i &&
    !flush_tlb_i
  );

  // Very important: avoid byte-swapping the PTE response.
  a_phase1_little_endian_pte: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !mbe_i
  );

  // Avoid HLVX special permission behavior in the first milestone.
  a_phase1_no_hlvx: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !hlvx_inst_i
  );

  // Use supervisor mode with a supervisor page.
  a_phase1_supervisor_privilege: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    priv_lvl_i == riscv::PRIV_LVL_S &&
    ld_st_priv_lvl_i == riscv::PRIV_LVL_S
  );

  // Once we have seen a translated miss, retry the same virtual address/context
  // until a hit becomes visible.
  a_retry_same_lsu_request_after_miss: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    cover_wait_hit_q
    |->
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    (lsu_vaddr_i == cover_lsu_vaddr_q) &&
    (asid_i == cover_asid_q) &&
    (vmid_i == cover_vmid_q) &&
    (lsu_is_store_i == cover_lsu_is_store_q)
  );

  // ---------------------------------------------------------------------------
  // D. Availability and pass-through properties.
  // ---------------------------------------------------------------------------

  p_fetch_passthrough_when_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !instr_translation_enabled
    |->
    (icache_areq_o.fetch_valid == icache_areq_i.fetch_req) &&
    (icache_areq_o.fetch_paddr == truncate_vaddr_to_paddr(icache_areq_i.fetch_vaddr)) &&
    (!icache_areq_o.fetch_exception.valid)
  );

  p_lsu_dtlb_hit_high_when_lsu_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !lsu_translation_enabled
    |->
    lsu_dtlb_hit_o
  );

  p_lsu_dtlb_ppn_passthrough_when_lsu_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !lsu_translation_enabled
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
  // E. Visible address correctness and data-integrity properties.
  // ---------------------------------------------------------------------------

  // Instruction success: the page offset must always pass through unchanged.
  p_fetch_success_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
    |->
    icache_areq_o.fetch_paddr[11:0] == icache_areq_i.fetch_vaddr[11:0]
  );

  // LSU success: the final physical address offset must match the previous LSU
  // virtual address offset because the LSU response is one cycle delayed.
  p_lsu_success_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(lsu_hit_event) &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    lsu_paddr_o[11:0] == $past(lsu_vaddr_i[11:0])
  );

  // Historical-bug target:
  // If the MMU exposes a DTLB hit in Cycle 0 and returns a successful final LSU
  // response in Cycle 1, both visible interfaces must agree on the physical page.
  // This catches old superpage bugs where lsu_dtlb_ppn_o was shifted by 12 bits.
  p_lsu_dtlb_ppn_matches_next_paddr_on_success: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(lsu_hit_event) &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    ppn_from_paddr(lsu_paddr_o) == $past(lsu_dtlb_ppn_o)
  );

  // Repeated instruction successes for the same virtual page and context must
  // return the same observed physical page, unless a flush cleared the tracker.
  p_fetch_repeated_success_same_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_matches_tracked
    |->
    ppn_from_paddr(icache_areq_o.fetch_paddr) == tracked_if_ppn_q
  );

  // Repeated LSU DTLB hits for the same virtual page and context must expose the
  // same Cycle-0 PPN.
  p_lsu_repeated_hit_same_cycle_ppn: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_matches_tracked
    |->
    lsu_dtlb_ppn_o == tracked_lsu_ppn_q
  );

  // The next-cycle successful LSU physical address must also agree with the
  // tracked PPN for repeated hits.
  p_lsu_repeated_hit_next_paddr_same_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(lsu_matches_tracked) &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    ppn_from_paddr(lsu_paddr_o) == $past(tracked_lsu_ppn_q)
  );

  // ---------------------------------------------------------------------------
  // Basic smoke covers: if these are unreachable, the problem is reset/top/TCL,
  // not the MMU translation logic.
  // ---------------------------------------------------------------------------

  c_reset_released_seen: cover property (
    @(posedge clk_i)
    rst_ni && past_valid_q
  );

  c_fetch_input_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    icache_areq_i.fetch_req
  );

  c_lsu_input_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_req_i
  );

  c_fetch_passthrough_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    !instr_translation_enabled &&
    icache_areq_i.fetch_req &&
    icache_areq_o.fetch_valid
  );

  c_lsu_passthrough_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    !lsu_translation_enabled &&
    lsu_req_i &&
    !misaligned_ex_i.valid
    ##1
    lsu_valid_o &&
    !lsu_exception_o.valid
  );

  c_lsu_translation_enabled_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i
  );

  c_lsu_translated_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid
  );

    // ---------------------------------------------------------------------------
  // Translation path diagnostic covers.
  // These tell us how far a translated LSU request gets.
  // ---------------------------------------------------------------------------

  c_lsu_translated_dtlb_miss_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    !lsu_dtlb_hit_o
  );

  c_dtlb_miss_counter_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    dtlb_miss_o
  );

  c_ptw_memory_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req
  );

  c_ptw_memory_grant_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req &&
    req_port_i.data_gnt
  );

  c_ptw_memory_response_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_rvalid
  );

  // ---------------------------------------------------------------------------
  // F. Useful covers.
  // ---------------------------------------------------------------------------

  c_ptw_real_memory_transaction_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req &&
    req_port_i.data_gnt
    ##1
    req_port_i.data_rvalid &&
    (req_port_i.data_rdata == make_legal_leaf_pte())
  );

  c_lsu_miss_ptw_fill_later_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    // First translated LSU request misses.
    phase1_lsu_req &&
    !lsu_dtlb_hit_o

    // PTW gets a useful memory transaction.
    ##[1:40]
    req_port_o.data_req &&
    req_port_i.data_gnt

    ##1
    req_port_i.data_rvalid &&
    (req_port_i.data_rdata == make_legal_leaf_pte())

    // Later, same request/context becomes a DTLB hit.
    ##[1:120]
    phase1_lsu_req &&
    lsu_dtlb_hit_o

    ##1
    lsu_valid_o &&
    !lsu_exception_o.valid
  );
  

  c_fetch_success_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
  );

  c_fetch_repeated_success_same_translation_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_matches_tracked
  );

  c_lsu_dtlb_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event ##1 lsu_valid_o
  );

  c_lsu_successful_hit_tracked_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    tracked_lsu_valid_q
  );

  c_lsu_repeated_hit_same_translation_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_matches_tracked ##1 lsu_valid_o && !lsu_exception_o.valid
  );

  // This cover is expected to become reachable on the old buggy MMU once a
  // translated superpage DTLB hit is reachable. It is the visible symptom of the
  // same-cycle PPN shift bug.
  c_old_superpage_ppn_shift_bug_exposed: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(phase1_lsu_req && lsu_dtlb_hit_o) &&
    lsu_valid_o &&
    !lsu_exception_o.valid &&
    (ppn_from_paddr(lsu_paddr_o) != $past(lsu_dtlb_ppn_o))
  );

endmodule

bind cva6_mmu cva6_mmu_scoreboard_bind i_cva6_mmu_scoreboard_bind (.*);
