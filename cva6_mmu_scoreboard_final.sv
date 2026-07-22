// cva6_mmu_scoreboard_global_interface_v1.sv
// -----------------------------------------------------------------------------
// Global MMU interface scoreboard.
//
// Verification scope:
//   - Verify what enters and leaves cva6_mmu.
//   - Do not distinguish whether a translation came from the private TLBs,
//     shared TLB, or PTW.
//   - Track one observed successful translation per interface, as in the TLB and
//     shared-TLB scoreboards.
//   - Check generic address consistency, timing, passthrough, and repeated
//     translation integrity.
//   - The PTW implementation may be black-boxed in OneSpin. The small abstract
//     PTW contract below exists only to make legal refill behavior reachable.
//
// Current stabilized environment:
//   - normal S-stage translation only;
//   - PMP excluded by the formal configuration;
//   - no G-stage/two-stage traffic yet;
//   - no flush race while a request is pending.
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
  input logic lsu_is_store_i,

  input logic lsu_dtlb_hit_o,
  input logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,
  input logic lsu_valid_o,
  input logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,
  input cva6_mmu_formal_pkg::exception_t lsu_exception_o,

  input riscv::priv_lvl_t priv_lvl_i,
  input riscv::priv_lvl_t ld_st_priv_lvl_i,
  input logic v_i,
  input logic ld_st_v_i,
  input logic mbe_i,
  input logic hlvx_inst_i,

  input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
  input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
  input logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
  input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,

  input logic flush_tlb_i,
  input logic flush_tlb_vvma_i,
  input logic flush_tlb_gvma_i,

  // Internal PTW/shared-TLB boundary signals used to constrain the
  // OneSpin-black-boxed PTW.
  input logic ptw_active,
  input logic walking_instr,
  input logic ptw_error,
  input logic ptw_error_at_g_st,
  input logic ptw_err_at_g_int_st,
  input logic ptw_access_exception,

  input logic shared_tlb_access,
  input logic shared_tlb_hit,
  input logic [CVA6Cfg.VLEN-1:0] shared_tlb_vaddr,

  input tlb_update_cva6_t update_shared_tlb,
  input logic [CVA6Cfg.VLEN-1:0] update_vaddr,

  // Observation only: updates sent to the private TLBs.
  input tlb_update_cva6_t update_itlb,
  input tlb_update_cva6_t update_dtlb
);

  typedef logic [CVA6Cfg.PPNW-1:0]       ppn_t;
  typedef logic [CVA6Cfg.VLEN-1:12]      vpn_t;
  typedef logic [CVA6Cfg.ASID_WIDTH-1:0] asid_t;
  typedef logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_t;

  wire any_flush;
  wire instr_translation_enabled;
  wire lsu_translation_enabled;

  assign any_flush =
      flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;
  assign instr_translation_enabled =
      enable_translation_i || enable_g_translation_i;
  assign lsu_translation_enabled =
      en_ld_st_translation_i || en_ld_st_g_translation_i;

  wire asid_t fetch_effective_asid;
  wire asid_t lsu_effective_asid;

  assign fetch_effective_asid = v_i       ? vs_asid_i : asid_i;
  assign lsu_effective_asid   = ld_st_v_i ? vs_asid_i : asid_i;

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

  function automatic vpn_t vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[CVA6Cfg.VLEN-1:12];
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
  // Request events
  // ---------------------------------------------------------------------------

  wire fetch_request;
  wire fetch_success;
  wire lsu_request;
  wire lsu_hit_event;
  wire fetch_miss_event;
  wire lsu_miss_event;

 assign fetch_miss_event =
      fetch_request &&
      !icache_areq_o.fetch_valid &&
      !icache_areq_o.fetch_exception.valid;

  assign lsu_miss_event =
      lsu_request &&
      !lsu_dtlb_hit_o;
  assign fetch_request =
      instr_translation_enabled &&
      icache_areq_i.fetch_req;

  assign fetch_success =
      fetch_request &&
      icache_areq_o.fetch_valid &&
      !icache_areq_o.fetch_exception.valid &&
      !any_flush;

  assign lsu_request =
      lsu_translation_enabled &&
      lsu_req_i &&
      !misaligned_ex_i.valid;

  assign lsu_hit_event =
      lsu_request &&
      lsu_dtlb_hit_o &&
      !any_flush;

  // ---------------------------------------------------------------------------
  // Request HOLD model (for MMU requests are held, untill a response comes)
  // ---------------------------------------------------------------------------

  logic lsu_pending_q;
  logic [CVA6Cfg.VLEN-1:0] held_lsu_vaddr_q;
  logic held_lsu_store_q;
  asid_t held_lsu_asid_q;
  vmid_t held_lsu_vmid_q;
  riscv::priv_lvl_t held_lsu_priv_q;
  logic [CVA6Cfg.PPNW-1:0] held_lsu_satp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_pending_q    <= 1'b0;
      held_lsu_vaddr_q <= '0;
      held_lsu_store_q <= 1'b0;
      held_lsu_asid_q  <= '0;
      held_lsu_vmid_q  <= '0;
      held_lsu_priv_q  <= riscv::PRIV_LVL_S;
      held_lsu_satp_q  <= '0;
    end else if (any_flush) begin
      lsu_pending_q <= 1'b0;
    end else begin
      if (!lsu_pending_q && lsu_request && !lsu_dtlb_hit_o) begin
        lsu_pending_q    <= 1'b1;
        held_lsu_vaddr_q <= lsu_vaddr_i;
        held_lsu_store_q <= lsu_is_store_i;
        held_lsu_asid_q  <= lsu_effective_asid;
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

  logic fetch_pending_q;
  logic [CVA6Cfg.VLEN-1:0] held_fetch_vaddr_q;
  asid_t held_fetch_asid_q;
  vmid_t held_fetch_vmid_q;
  riscv::priv_lvl_t held_fetch_priv_q;
  logic [CVA6Cfg.PPNW-1:0] held_fetch_satp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pending_q    <= 1'b0;
      held_fetch_vaddr_q <= '0;
      held_fetch_asid_q  <= '0;
      held_fetch_vmid_q  <= '0;
      held_fetch_priv_q  <= riscv::PRIV_LVL_S;
      held_fetch_satp_q  <= '0;
    end else if (any_flush) begin
      fetch_pending_q <= 1'b0;
    end else begin
      if (!fetch_pending_q &&
          fetch_request &&
          !icache_areq_o.fetch_valid &&
          !icache_areq_o.fetch_exception.valid) begin
        fetch_pending_q    <= 1'b1;
        held_fetch_vaddr_q <= icache_areq_i.fetch_vaddr;
        held_fetch_asid_q  <= fetch_effective_asid;
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
  // LSU Cycle-0 hit register storage (Replicating RTL behavior for scoreboarding)
  // ---------------------------------------------------------------------------

  logic lsu_hit_packet_valid_q;
  logic [CVA6Cfg.VLEN-1:0] lsu_hit_vaddr_q;
  ppn_t lsu_hit_ppn_q;
  asid_t lsu_hit_asid_q;
  vmid_t lsu_hit_vmid_q;
  logic  lsu_hit_s_stage_q;
  logic  lsu_hit_g_stage_q;
  logic  lsu_hit_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_hit_packet_valid_q <= 1'b0;
      lsu_hit_vaddr_q        <= '0;
      lsu_hit_ppn_q          <= '0;
    end else begin
        lsu_hit_packet_valid_q <= lsu_hit_event;
    if (lsu_hit_event) begin
        lsu_hit_vaddr_q   <= lsu_vaddr_i;
        lsu_hit_ppn_q     <= lsu_dtlb_ppn_o;
        lsu_hit_asid_q    <= lsu_effective_asid;
        lsu_hit_vmid_q    <= vmid_i;
        lsu_hit_s_stage_q <= en_ld_st_translation_i;
        lsu_hit_g_stage_q <= en_ld_st_g_translation_i;
        lsu_hit_v_q       <= ld_st_v_i;
    end
    end
  end

  // ---------------------------------------------------------------------------
  //Tracked entry observed-translation scoreboard
  // ---------------------------------------------------------------------------


  // ---------------------------------------------------------------------------
  //Instruction Fetch Tracking (Instruction Fetch)
  // ---------------------------------------------------------------------------
  logic tracked_fetch_valid_q;
  vpn_t tracked_fetch_vpn_q;
  ppn_t tracked_fetch_ppn_q;
  asid_t tracked_fetch_asid_q;
  vmid_t tracked_fetch_vmid_q;
  logic tracked_fetch_s_stage_q;
  logic tracked_fetch_g_stage_q;
  logic tracked_fetch_v_q;
  logic [CVA6Cfg.PPNW-1:0] tracked_fetch_satp_q;
  
  wire fetch_translation_state_unstable;
  assign fetch_translation_state_unstable =
    any_flush                         ||
    fetch_miss_event                  ||
    fetch_pending_q                   ||
    abstract_ptw_pending_q            ||
    (ptw_active && walking_instr)     ||
    update_shared_tlb.valid           ||
    update_itlb.valid;
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tracked_fetch_valid_q   <= 1'b0;
      tracked_fetch_vpn_q     <= '0;
      tracked_fetch_ppn_q     <= '0;
      tracked_fetch_asid_q    <= '0;
      tracked_fetch_vmid_q    <= '0;
      tracked_fetch_s_stage_q <= 1'b0;
      tracked_fetch_g_stage_q <= 1'b0;
      tracked_fetch_v_q       <= 1'b0;
      tracked_fetch_satp_q <= '0;
    end else if (fetch_translation_state_unstable) begin
    tracked_fetch_valid_q <= 1'b0;
    end else if (fetch_success) begin
      tracked_fetch_valid_q   <= 1'b1;
      tracked_fetch_vpn_q     <= vpn_from_vaddr(icache_areq_i.fetch_vaddr);
      tracked_fetch_ppn_q     <= ppn_from_paddr(icache_areq_o.fetch_paddr);
      tracked_fetch_asid_q    <= fetch_effective_asid;
      tracked_fetch_vmid_q    <= vmid_i;
      tracked_fetch_s_stage_q <= enable_translation_i;
      tracked_fetch_g_stage_q <= enable_g_translation_i;
      tracked_fetch_v_q       <= v_i;
      tracked_fetch_satp_q    <= satp_ppn_i;
    end
  end

  wire fetch_matches_tracked;
  assign fetch_matches_tracked =
      tracked_fetch_valid_q &&
      !fetch_translation_state_unstable &&
      fetch_success &&
      (vpn_from_vaddr(icache_areq_i.fetch_vaddr) == tracked_fetch_vpn_q) &&
      (fetch_effective_asid == tracked_fetch_asid_q) &&
      (vmid_i == tracked_fetch_vmid_q) &&
      (satp_ppn_i == tracked_fetch_satp_q) &&
      (enable_translation_i == tracked_fetch_s_stage_q) &&
      (enable_g_translation_i == tracked_fetch_g_stage_q) &&
      (v_i == tracked_fetch_v_q);

  // ---------------------------------------------------------------------------
  // Load Store Tracking (Data)
  // ---------------------------------------------------------------------------
  logic tracked_lsu_valid_q;
  vpn_t tracked_lsu_vpn_q;
  ppn_t tracked_lsu_ppn_q;
  asid_t tracked_lsu_asid_q;
  vmid_t tracked_lsu_vmid_q;
  logic tracked_lsu_s_stage_q;
  logic tracked_lsu_g_stage_q;
  logic tracked_lsu_v_q;
  logic [CVA6Cfg.PPNW-1:0] tracked_lsu_satp_q;

  wire lsu_translation_state_unstable;
  assign lsu_translation_state_unstable =
    any_flush                         ||
    lsu_miss_event                    ||
    lsu_pending_q                     ||
    abstract_ptw_pending_q            ||
    (ptw_active && !walking_instr)    ||
    update_shared_tlb.valid           ||
    update_dtlb.valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tracked_lsu_valid_q   <= 1'b0;
      tracked_lsu_vpn_q     <= '0;
      tracked_lsu_ppn_q     <= '0;
      tracked_lsu_asid_q    <= '0;
      tracked_lsu_vmid_q    <= '0;
      tracked_lsu_s_stage_q <= 1'b0;
      tracked_lsu_g_stage_q <= 1'b0;
      tracked_lsu_v_q       <= 1'b0;
      tracked_lsu_satp_q    <= '0;
    end else if (lsu_translation_state_unstable) begin
      tracked_lsu_valid_q <= 1'b0;
    end else if (lsu_hit_packet_valid_q &&
                 lsu_valid_o &&
                 !lsu_exception_o.valid) begin
      tracked_lsu_valid_q   <= 1'b1;
      tracked_lsu_vpn_q     <= vpn_from_vaddr(lsu_hit_vaddr_q);
      tracked_lsu_ppn_q     <= ppn_from_paddr(lsu_paddr_o);
      tracked_lsu_asid_q    <= lsu_hit_asid_q;
      tracked_lsu_vmid_q    <= lsu_hit_vmid_q;
      tracked_lsu_s_stage_q <= lsu_hit_s_stage_q;
      tracked_lsu_g_stage_q <= lsu_hit_g_stage_q;
      tracked_lsu_v_q       <= lsu_hit_v_q;
      tracked_lsu_satp_q <= satp_ppn_i;
    end
  end

  wire lsu_matches_tracked;
  assign lsu_matches_tracked =
      tracked_lsu_valid_q &&
      !lsu_translation_state_unstable &&
      lsu_hit_event &&
      (vpn_from_vaddr(lsu_vaddr_i) == tracked_lsu_vpn_q) &&
      (lsu_effective_asid == tracked_lsu_asid_q) &&
      (vmid_i == tracked_lsu_vmid_q) &&
      (satp_ppn_i == tracked_lsu_satp_q) &&
      (en_ld_st_translation_i == tracked_lsu_s_stage_q) &&
      (en_ld_st_g_translation_i == tracked_lsu_g_stage_q) &&
      (ld_st_v_i == tracked_lsu_v_q);

  // ---------------------------------------------------------------------------
  // environment assumptions
  // ---------------------------------------------------------------------------

  // Current milestone: normal S-stage translation. The scoreboard data-integrity
  // properties themselves are mode-neutral; G-stage/two-stage will be enabled in
  // the next environment expansion.
  a_current_s_stage_only: assume property (
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

  a_only_one_requester_active: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !(icache_areq_i.fetch_req && lsu_req_i)
  );

  a_no_flush_while_pending: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    (lsu_pending_q || fetch_pending_q) |-> !any_flush
  );

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
    (lsu_effective_asid == held_lsu_asid_q) &&
    (vmid_i == held_lsu_vmid_q) &&
    (ld_st_priv_lvl_i == held_lsu_priv_q) &&
    (satp_ppn_i == held_lsu_satp_q)
  );

  a_fetch_holds_request_until_terminal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_pending_q
    |->
    enable_translation_i &&
    !enable_g_translation_i &&
    icache_areq_i.fetch_req &&
    (icache_areq_i.fetch_vaddr == held_fetch_vaddr_q) &&
    (fetch_effective_asid == held_fetch_asid_q) &&
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
  // Abstract contract for the OneSpin-black-boxed PTW
  // ---------------------------------------------------------------------------
  localparam int unsigned ABSTRACT_PTW_MAX_LATENCY = 8;

  logic abstract_ptw_pending_q;
  logic abstract_ptw_is_instr_q;
  logic [CVA6Cfg.VLEN-1:0] abstract_ptw_vaddr_q;
  asid_t abstract_ptw_asid_q;
  vmid_t abstract_ptw_vmid_q;
  

  wire abstract_ptw_start;
  wire abstract_ptw_terminal;

  assign abstract_ptw_start =
      shared_tlb_access &&
      !shared_tlb_hit &&
      !abstract_ptw_pending_q &&
      !any_flush;

  assign abstract_ptw_terminal =
      update_shared_tlb.valid ||
      ptw_error ||
      ptw_access_exception;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      abstract_ptw_pending_q  <= 1'b0;
      abstract_ptw_is_instr_q <= 1'b0;
      abstract_ptw_vaddr_q    <= '0;
      abstract_ptw_asid_q     <= '0;
      abstract_ptw_vmid_q     <= '0;
    end else if (any_flush) begin
      abstract_ptw_pending_q <= 1'b0;
    end else begin
      if (abstract_ptw_start) begin
        abstract_ptw_pending_q  <= 1'b1;
        abstract_ptw_is_instr_q <= fetch_pending_q;
        abstract_ptw_vaddr_q    <= shared_tlb_vaddr;
        abstract_ptw_asid_q     <= asid_i;
        abstract_ptw_vmid_q     <= vmid_i;
      end
      if (abstract_ptw_pending_q && abstract_ptw_terminal) begin
        abstract_ptw_pending_q <= 1'b0;
      end
    end
  end

  a_ptw_start_has_one_pending_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start |-> (lsu_pending_q ^ fetch_pending_q)
  );

  a_ptw_success_only: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    !ptw_error &&
    !ptw_error_at_g_st &&
    !ptw_err_at_g_int_st &&
    !ptw_access_exception
  );

  a_ptw_eventually_returns_update: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start
    |->
    ##[1:ABSTRACT_PTW_MAX_LATENCY] update_shared_tlb.valid
  );

  a_ptw_active_while_pending: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q |-> ptw_active
  );

  a_ptw_walking_side_matches_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    (walking_instr == abstract_ptw_is_instr_q)
  );

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

  a_ptw_update_is_legal_success: assume property (
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

  // Permit all ordinary page sizes.
  a_ptw_update_page_size_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid
    |->
    $onehot0(update_shared_tlb.is_page)
  );

  // A superpage must have the PTE PPN low fields aligned. The selected
  // page size is symbolic.
  a_ptw_update_superpage_alignment: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    update_shared_tlb.is_page[0][0]
    |->
    (update_shared_tlb.content.ppn[
      (CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)-1:0] == '0)
  );

  a_ptw_update_root_superpage_alignment: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    update_shared_tlb.is_page[CVA6Cfg.PtLevels-2][0]
    |->
    (update_shared_tlb.content.ppn[
      (2*(CVA6Cfg.VpnLen/CVA6Cfg.PtLevels))-1:0] == '0)
  );

  a_ptw_update_is_single_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid |=> !update_shared_tlb.valid
  );

  // ---------------------------------------------------------------------------
  // Generic external MMU properties
  // ---------------------------------------------------------------------------

  p_fetch_passthrough_translation_disabled: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    !instr_translation_enabled
    |->
    (icache_areq_o.fetch_valid == icache_areq_i.fetch_req) &&
    !icache_areq_o.fetch_exception.valid &&
    (icache_areq_o.fetch_paddr ==
      passthrough_paddr(icache_areq_i.fetch_vaddr))
  );

  p_lsu_hit_produces_response_next_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event |=> lsu_valid_o
  );

  p_lsu_success_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_packet_valid_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    lsu_paddr_o[11:0] == lsu_hit_vaddr_q[11:0]
  );

  p_lsu_early_translation_matches_final_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_packet_valid_q &&
    lsu_valid_o &&
    !lsu_exception_o.valid
    |->
    ppn_from_paddr(lsu_paddr_o) == lsu_hit_ppn_q
  );

  p_fetch_success_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
    |->
    icache_areq_o.fetch_paddr[11:0] ==
    icache_areq_i.fetch_vaddr[11:0]
  );

  // ---------------------------------------------------------------------------
  // Neutral coverage: request type, page-size reachability, and repetition
  // ---------------------------------------------------------------------------

  c_fetch_success_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
  );

  c_lsu_load_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event && !lsu_is_store_i
    ##1 lsu_valid_o && !lsu_exception_o.valid
  );

  c_lsu_store_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event && lsu_is_store_i
    ##1 lsu_valid_o && !lsu_exception_o.valid
  );

  c_fetch_repeated_translation_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_matches_tracked
  );

  c_lsu_repeated_translation_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_matches_tracked
  );

  c_ptw_4k_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    (update_shared_tlb.is_page == '0)
  );

  c_ptw_nonroot_superpage_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    update_shared_tlb.is_page[0][0]
  );

  c_ptw_root_superpage_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    update_shared_tlb.is_page[CVA6Cfg.PtLevels-2][0]
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

bind cva6_mmu cva6_mmu_scoreboard_bind
  i_cva6_mmu_scoreboard_bind (.*);
