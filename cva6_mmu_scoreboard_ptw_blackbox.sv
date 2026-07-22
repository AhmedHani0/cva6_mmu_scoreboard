// cva6_mmu_scoreboard_ptw_blackbox_single_module.sv
// -----------------------------------------------------------------------------
// Single-module compositional MMU scoreboard for a OneSpin-black-boxed PTW.
//
// OneSpin action:
//   - Black-box only the PTW instance/module.
//   - Keep cva6_mmu, cva6_shared_tlb, ITLB, and DTLB concrete.
//
// This checker contains:
//   A. requester HOLD assumptions,
//   B. the behavioral contract for symbolic PTW outputs,
//   C. externally visible MMU assertions and covers.
//
// The PTW contract is intentionally inside this scoreboard. No separate
// cva6_ptw_blackbox_contract module or PTW bind is required.
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
  input dcache_req_i_t req_port_o,

  // Internal cva6_mmu signals at the PTW/shared-TLB boundary.
  // These remain visible at the MMU level when i_ptw is black-boxed in OneSpin.
  input logic ptw_active,
  input logic walking_instr,
  input logic ptw_error,
  input logic ptw_error_at_g_st,
  input logic ptw_err_at_g_int_st,
  input logic ptw_access_exception,

  input logic shared_tlb_access,
  input logic shared_tlb_hit,
  input logic shared_tlb_miss,
  input logic [CVA6Cfg.VLEN-1:0] shared_tlb_vaddr,
  input logic itlb_req,

  input tlb_update_cva6_t update_shared_tlb,
  input logic [CVA6Cfg.VLEN-1:0] update_vaddr,

  // Diagnostic observation signals from the real shared TLB.
  input tlb_update_cva6_t update_itlb,
  input tlb_update_cva6_t update_dtlb
);

  typedef logic [CVA6Cfg.PPNW-1:0] ppn_t;
  typedef logic [CVA6Cfg.ASID_WIDTH-1:0] asid_t;
  typedef logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_t;

  wire any_flush;
  wire instr_translation_enabled;
  wire lsu_translation_enabled;
  assign any_flush = flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;
  assign instr_translation_enabled = enable_translation_i || enable_g_translation_i;
  assign lsu_translation_enabled = en_ld_st_translation_i || en_ld_st_g_translation_i;

  logic past_valid_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) past_valid_q <= 1'b0;
    else         past_valid_q <= 1'b1;
  end

  function automatic ppn_t ppn_from_paddr(
    input logic [CVA6Cfg.PLEN-1:0] paddr
  );
    ppn_from_paddr = ppn_t'(paddr[CVA6Cfg.PLEN-1:12]);
  endfunction

  function automatic logic [CVA6Cfg.PLEN-1:0] passthrough_paddr(
    input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    passthrough_paddr = CVA6Cfg.PLEN'(vaddr);
  endfunction

  function automatic logic is_canonical_sv39(
    input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    is_canonical_sv39 =
      (&vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.SV-1]) ||
      !(|vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.SV-1]);
  endfunction

  // ---------------------------------------------------------------------------
  // Requester HOLD models in case of LSU interface
  // ---------------------------------------------------------------------------
  logic lsu_pending_q;
  logic [CVA6Cfg.VLEN-1:0] held_lsu_vaddr_q;
  logic held_lsu_store_q;
  asid_t held_lsu_asid_q;
  vmid_t held_lsu_vmid_q;
  riscv::priv_lvl_t held_lsu_priv_q;
  logic [CVA6Cfg.PPNW-1:0] held_lsu_satp_q;

  wire lsu_request;
  assign lsu_request =
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_pending_q      <= 1'b0;
      held_lsu_vaddr_q   <= '0;
      held_lsu_store_q   <= 1'b0;
      held_lsu_asid_q    <= '0;
      held_lsu_vmid_q    <= '0;
      held_lsu_priv_q    <= riscv::PRIV_LVL_S;
      held_lsu_satp_q    <= '0;
    end else begin
      if (any_flush) begin
        lsu_pending_q <= 1'b0;
      end else if (!lsu_pending_q && lsu_request && !lsu_dtlb_hit_o) begin
        lsu_pending_q    <= 1'b1;
        held_lsu_vaddr_q <= lsu_vaddr_i;
        held_lsu_store_q <= lsu_is_store_i;
        held_lsu_asid_q  <= asid_i;
        held_lsu_vmid_q  <= vmid_i;
        held_lsu_priv_q  <= ld_st_priv_lvl_i;
        held_lsu_satp_q  <= satp_ppn_i;
      end else if (lsu_pending_q &&
                   ((lsu_request && lsu_dtlb_hit_o) ||
                    (lsu_valid_o && lsu_exception_o.valid))) begin
        lsu_pending_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Replicating RTL One cycle delay response in case of LSU DTLB hit.
  // ---------------------------------------------------------------------------

  logic lsu_hit_packet_valid_q;
  logic [CVA6Cfg.VLEN-1:0] lsu_hit_vaddr_q;
  ppn_t lsu_hit_ppn_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_hit_packet_valid_q <= 1'b0;
      lsu_hit_vaddr_q        <= '0;
      lsu_hit_ppn_q          <= '0;
    end else begin
      lsu_hit_packet_valid_q <= lsu_request && lsu_dtlb_hit_o;

      if (lsu_request && lsu_dtlb_hit_o) begin
        lsu_hit_vaddr_q <= lsu_vaddr_i;
        lsu_hit_ppn_q   <= lsu_dtlb_ppn_o;
      end
    end
end

  // ---------------------------------------------------------------------------
  // Requester HOLD models in case of Instruction Fetch interface
  // ---------------------------------------------------------------------------
  logic fetch_pending_q;
  logic [CVA6Cfg.VLEN-1:0] held_fetch_vaddr_q;
  asid_t held_fetch_asid_q;
  vmid_t held_fetch_vmid_q;
  riscv::priv_lvl_t held_fetch_priv_q;
  logic [CVA6Cfg.PPNW-1:0] held_fetch_satp_q;

  wire fetch_request;
  assign fetch_request =
    enable_translation_i &&
    !enable_g_translation_i &&
    icache_areq_i.fetch_req;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pending_q    <= 1'b0;
      held_fetch_vaddr_q <= '0;
      held_fetch_asid_q  <= '0;
      held_fetch_vmid_q  <= '0;
      held_fetch_priv_q  <= riscv::PRIV_LVL_S;
      held_fetch_satp_q  <= '0;
    end else begin
      if (any_flush) begin
        fetch_pending_q <= 1'b0;
      end else if (!fetch_pending_q && fetch_request &&
                   !icache_areq_o.fetch_valid &&
                   !icache_areq_o.fetch_exception.valid) begin
        fetch_pending_q    <= 1'b1;
        held_fetch_vaddr_q <= icache_areq_i.fetch_vaddr;
        held_fetch_asid_q  <= asid_i;
        held_fetch_vmid_q  <= vmid_i;
        held_fetch_priv_q  <= priv_lvl_i;
        held_fetch_satp_q  <= satp_ppn_i;
      end else if (fetch_pending_q &&
                   (icache_areq_o.fetch_valid ||
                    icache_areq_o.fetch_exception.valid)) begin
        fetch_pending_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Environment assumptions
  // ---------------------------------------------------------------------------

  // First milestone: normal non-virtualized S-stage translation only.
  a_phase1_context: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !enable_g_translation_i &&
    !en_ld_st_g_translation_i &&
    !v_i &&
    !ld_st_v_i &&
    !flush_tlb_vvma_i &&
    !flush_tlb_gvma_i &&
    !mbe_i &&
    !hlvx_inst_i
  );

  // PMP is intentionally excluded by the formal configuration/top. The checker
  // makes no PMP-specific assertion.

  // Avoid arbitration ambiguity in this first compositional proof.
  a_only_one_requester_active: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !(icache_areq_i.fetch_req && lsu_req_i)
  );

  // No flush is injected while a request is held pending.
  a_no_flush_while_request_pending: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_pending_q || fetch_pending_q |-> !any_flush
  );

  // Concrete LSU protocol: HOLD the same request every cycle after a miss.
  a_lsu_holds_request_until_terminal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_pending_q
    |->
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i &&
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    (lsu_vaddr_i == held_lsu_vaddr_q) &&
    (lsu_is_store_i == held_lsu_store_q) &&
    (asid_i == held_lsu_asid_q) &&
    (vmid_i == held_lsu_vmid_q) &&
    (ld_st_priv_lvl_i == held_lsu_priv_q) &&
    (satp_ppn_i == held_lsu_satp_q)
  );

  // Concrete frontend protocol: HOLD the same fetch until valid/exception.
  a_fetch_holds_request_until_terminal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_pending_q
    |->
    enable_translation_i &&
    !enable_g_translation_i &&
    icache_areq_i.fetch_req &&
    (icache_areq_i.fetch_vaddr == held_fetch_vaddr_q) &&
    (asid_i == held_fetch_asid_q) &&
    (vmid_i == held_fetch_vmid_q) &&
    (priv_lvl_i == held_fetch_priv_q) &&
    (satp_ppn_i == held_fetch_satp_q)
  );

  a_lsu_address_canonical: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_request |-> is_canonical_sv39(lsu_vaddr_i)
  );

  a_fetch_address_canonical: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request |-> is_canonical_sv39(icache_areq_i.fetch_vaddr)
  );

  a_supervisor_context: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    priv_lvl_i == riscv::PRIV_LVL_S &&
    ld_st_priv_lvl_i == riscv::PRIV_LVL_S
  );


  // ---------------------------------------------------------------------------
  // Abstract PTW contract for the OneSpin-black-boxed PTW
  // ---------------------------------------------------------------------------
  //
  // OneSpin black-boxing removes the PTW implementation. Therefore the PTW
  // outputs seen here become symbolic unless constrained. These assumptions
  // describe the legal phase-1 behavior of that abstract PTW.
  //
  // The real shared TLB and private ITLB/DTLB remain concrete.

  localparam int unsigned ABSTRACT_PTW_MAX_LATENCY = 8;

  logic abstract_ptw_pending_q;
  logic abstract_ptw_is_instr_q;
  logic [CVA6Cfg.VLEN-1:0] abstract_ptw_vaddr_q;
  asid_t abstract_ptw_asid_q;
  vmid_t abstract_ptw_vmid_q;

  wire abstract_ptw_start;
  wire abstract_ptw_success;
  wire abstract_ptw_failure;

  assign abstract_ptw_start =
      shared_tlb_access &&
      !shared_tlb_hit &&
      !abstract_ptw_pending_q &&
      !any_flush;

  assign abstract_ptw_success = update_shared_tlb.valid;
  assign abstract_ptw_failure = ptw_error || ptw_access_exception;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      abstract_ptw_pending_q  <= 1'b0;
      abstract_ptw_is_instr_q <= 1'b0;
      abstract_ptw_vaddr_q    <= '0;
      abstract_ptw_asid_q     <= '0;
      abstract_ptw_vmid_q     <= '0;
    end else begin
      if (any_flush) begin
        abstract_ptw_pending_q <= 1'b0;
      end else begin
        if (abstract_ptw_start) begin
          abstract_ptw_pending_q  <= 1'b1;
          abstract_ptw_is_instr_q <= fetch_pending_q;
          abstract_ptw_vaddr_q    <= shared_tlb_vaddr;
          abstract_ptw_asid_q     <= asid_i;
          abstract_ptw_vmid_q     <= vmid_i;
        end

        if (abstract_ptw_pending_q &&
            (abstract_ptw_success || abstract_ptw_failure)) begin
          abstract_ptw_pending_q <= 1'b0;
        end
      end
    end
  end


  a_ptw_start_has_one_pending_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start
    |->
    (lsu_pending_q ^ fetch_pending_q)
  );

  // The abstract PTW may not emit an update or exception without an outstanding
  // shared-TLB miss transaction.
  a_ptw_no_spurious_terminal_response: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_success || abstract_ptw_failure
    |->
    abstract_ptw_pending_q
  );

  // Phase 1 verifies successful translations. PTW error generation is covered
  // separately by the dedicated PTW proof.
  a_ptw_success_only: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    !ptw_error &&
    !ptw_error_at_g_st &&
    !ptw_err_at_g_int_st &&
    !ptw_access_exception
  );

  // The black-boxed PTW completes within a short abstract latency.
  a_ptw_eventually_returns_update: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start
    |->
    ##[1:ABSTRACT_PTW_MAX_LATENCY] update_shared_tlb.valid
  );

  // While a walk is outstanding, the symbolic PTW status must remain coherent.
  a_ptw_active_while_pending: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    ptw_active
  );

  a_ptw_walking_side_matches_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    (walking_instr == abstract_ptw_is_instr_q)
  );

  // The update must correspond to the miss remembered at the PTW boundary.
  a_ptw_update_matches_pending_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid
    |->
    (update_vaddr == abstract_ptw_vaddr_q) &&
    (update_shared_tlb.vpn ==
      abstract_ptw_vaddr_q[12+CVA6Cfg.VpnLen-1:12]) &&
    (update_shared_tlb.asid == abstract_ptw_asid_q) &&
    (update_shared_tlb.vmid == abstract_ptw_vmid_q)
  );

  // Return a legal permission-complete supervisor leaf translation.
  a_ptw_update_is_legal_leaf: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid
    |->
    update_shared_tlb.content.v &&
    update_shared_tlb.content.r &&
    update_shared_tlb.content.w &&
    update_shared_tlb.content.x &&
    update_shared_tlb.content.a &&
    update_shared_tlb.content.d &&
    !update_shared_tlb.content.u &&
    !update_shared_tlb.content.n &&
    (update_shared_tlb.g_content == '0)
  );

  // Use a root-level Sv39 superpage. The lower PPN fields are aligned, while
  // upper PPN bits remain symbolic and non-zero. This keeps the historical
  // lsu_dtlb_ppn_o superpage-substitution bug observable.
  a_ptw_update_is_aligned_root_superpage: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid
    |->
    update_shared_tlb.is_page[CVA6Cfg.PtLevels-2][0] &&
    (update_shared_tlb.content.ppn[
      (2*(CVA6Cfg.VpnLen/CVA6Cfg.PtLevels))-1:0] == '0) &&
    (update_shared_tlb.content.ppn[
      CVA6Cfg.PPNW-1:2*(CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)] != '0)
  );

  // A single-cycle update pulse avoids multiple abstract completions for one walk.
  a_ptw_update_is_single_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid
    |=>
    !update_shared_tlb.valid
  );

  // ---------------------------------------------------------------------------
  // External MMU assertions
  // ---------------------------------------------------------------------------

  p_fetch_passthrough_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !instr_translation_enabled
    |->
    (icache_areq_o.fetch_valid == icache_areq_i.fetch_req) &&
    !icache_areq_o.fetch_exception.valid &&
    (icache_areq_o.fetch_paddr == passthrough_paddr(icache_areq_i.fetch_vaddr))
  );

  p_lsu_hit_produces_response_next_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q && lsu_request && lsu_dtlb_hit_o
    |=> lsu_valid_o
  );

  p_lsu_success_preserves_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_packet_valid_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    lsu_paddr_o[11:0] == lsu_hit_vaddr_q[11:0]
  );

  // successful physical address translation must match the PPN from the DTLB hit
  p_lsu_same_cycle_ppn_matches_next_paddr: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_packet_valid_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    ppn_from_paddr(lsu_paddr_o) == lsu_hit_ppn_q
  );

  p_fetch_success_preserves_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request &&
    icache_areq_o.fetch_valid &&
    !icache_areq_o.fetch_exception.valid
    |->
    (icache_areq_o.fetch_paddr[11:0] == icache_areq_i.fetch_vaddr[11:0])
  );

  // ---------------------------------------------------------------------------
  // Covers proving non-vacuity and the complete abstracted refill flow
  // ---------------------------------------------------------------------------

  c_abstract_ptw_walk_and_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q
    ##1 abstract_ptw_start
    ##[1:ABSTRACT_PTW_MAX_LATENCY] update_shared_tlb.valid
  );

  c_lsu_miss_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q ##1 lsu_request && !lsu_dtlb_hit_o
  );

  c_superpage_ppn_bug_exposed: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    past_valid_q &&
    $past(lsu_request && lsu_dtlb_hit_o) &&
    lsu_valid_o &&
    !lsu_exception_o.valid &&
    (ppn_from_paddr(lsu_paddr_o) != $past(lsu_dtlb_ppn_o))
  );

  c_lsu_pending_reaches_shared_access: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1 lsu_request && !lsu_dtlb_hit_o
  ##1 lsu_pending_q
  ##[0:10] shared_tlb_access
);

c_lsu_pending_reaches_abstract_ptw_start: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1 lsu_request && !lsu_dtlb_hit_o
  ##1 lsu_pending_q
  ##[0:20] abstract_ptw_start
);

c_private_itlb_update_seen: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1
  update_itlb.valid
);

c_private_dtlb_update_seen: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1
  update_dtlb.valid
);

c_ptw_update_reaches_private_dtlb: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1
  update_shared_tlb.valid
  ##[0:20]
  update_dtlb.valid
);

c_ptw_update_reaches_private_itlb: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1
  update_shared_tlb.valid
  ##[0:20]
  update_itlb.valid
);

c_lsu_pending_then_private_dtlb_update: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1
  lsu_pending_q
  ##[1:25]
  update_dtlb.valid
);

c_lsu_ptw_update_seen: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  ##1 lsu_pending_q
  ##[1:20] abstract_ptw_start && !itlb_req
  ##[1:ABSTRACT_PTW_MAX_LATENCY]
      update_shared_tlb.valid
);

c_private_dtlb_update_then_lsu_hit: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  update_dtlb.valid
  ##[1:20]
  lsu_request &&
  lsu_dtlb_hit_o
);

c_lsu_pending_eventually_terminates: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q

  // A translated LSU request misses the private DTLB.
  ##1
  lsu_request &&
  !lsu_dtlb_hit_o
  // The scoreboard enters the pending/hold state.
  ##1
  lsu_pending_q
  // The miss reaches the shared TLB.
  ##[0:10]
  shared_tlb_access &&
  !shared_tlb_hit
  // The abstract black-box PTW starts.
  ##[0:5]
  abstract_ptw_start
  // The abstract PTW returns a legal update.
  ##[1:ABSTRACT_PTW_MAX_LATENCY]
  update_shared_tlb.valid
  // The real shared TLB forwards the translation to the private DTLB.
  ##[0:5]
  update_dtlb.valid
  // The held request now hits the private DTLB.
  ##[1:5]
  lsu_request &&
  lsu_dtlb_hit_o
  // One cycle later the MMU returns a successful LSU response.
  ##1
  lsu_valid_o &&
  !lsu_exception_o.valid
);

c_fetch_pending_eventually_terminates: cover property (
  @(posedge clk_i) disable iff (!rst_ni)
  past_valid_q
  // A translated instruction request is not immediately successful.
  ##1
  fetch_request &&
  !icache_areq_o.fetch_valid &&
  !icache_areq_o.fetch_exception.valid
  // The frontend holds the request.
  ##1
  fetch_pending_q
  // The miss reaches the shared TLB.
  ##[0:5]
  shared_tlb_access &&
  !shared_tlb_hit
  // The abstract PTW starts.
  ##[0:5]
  abstract_ptw_start
  // The PTW returns a legal translation.
  ##[1:ABSTRACT_PTW_MAX_LATENCY]
  update_shared_tlb.valid
  // The real shared TLB forwards it to the private ITLB.
  ##[0:5]
  update_itlb.valid
  // The held fetch request now succeeds.
  ##[1:5]
  icache_areq_o.fetch_valid &&
  !icache_areq_o.fetch_exception.valid
);

endmodule

bind cva6_mmu cva6_mmu_scoreboard_bind i_cva6_mmu_scoreboard_bind (.*);
