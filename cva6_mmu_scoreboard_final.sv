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
  input logic [31:0] lsu_tinst_i,
  input logic lsu_is_store_i,
  input logic hs_ld_st_inst_i,

  input logic lsu_dtlb_hit_o,
  input logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,
  input logic lsu_valid_o,
  input logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,
  input cva6_mmu_formal_pkg::exception_t lsu_exception_o,

  input riscv::priv_lvl_t priv_lvl_i,
  input riscv::priv_lvl_t ld_st_priv_lvl_i,

  input logic v_i,
  input logic ld_st_v_i,

  input logic sum_i,
  input logic vs_sum_i,
  input logic mxr_i,
  input logic vmxr_i,

  input logic mbe_i,
  input logic hlvx_inst_i,

  input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
  input logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
  input logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i,

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

  //   1 = instruction-side request
  //   0 = LSU/data-side request
  input logic itlb_req,

  input tlb_update_cva6_t update_shared_tlb,
  input logic [CVA6Cfg.VLEN-1:0] update_vaddr,

  // Observation only: updates sent to the private TLBs.
  input tlb_update_cva6_t update_itlb,
  input tlb_update_cva6_t update_dtlb
);

  typedef logic [CVA6Cfg.PPNW-1:0]       ppn_t;
  typedef logic [CVA6Cfg.VpnLen-1:0]     vpn_t;
  typedef logic [CVA6Cfg.ASID_WIDTH-1:0] asid_t;
  typedef logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_t;
  typedef logic [HYP_EXT*2:0]            mode_t;

  // Number of VPN bits represented by one ordinary Sv39 page-table level.
  localparam int unsigned VPN_LEVEL_BITS =
      CVA6Cfg.VpnLen / CVA6Cfg.PtLevels;

  // CVA6 translation-mode encoding:
  //
  //   bit 0 = S-stage enabled
  //   bit 1 = G-stage enabled
  //   bit 2 = virtualization state
  typedef logic [HYP_EXT*2:0] mode_t;

  wire any_flush;
  wire instr_translation_enabled;
  wire lsu_translation_enabled;

  assign any_flush =
      flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;
  assign instr_translation_enabled =
      enable_translation_i || enable_g_translation_i;
  assign lsu_translation_enabled =
      en_ld_st_translation_i || en_ld_st_g_translation_i;

  // Translation mode associated with each requester.
  // Encoding:
  //   {virtualization state, G-stage enabled, S-stage enabled}
  wire mode_t fetch_mode;
  wire mode_t lsu_mode;

  assign fetch_mode =
      mode_t'({
        v_i,
        enable_g_translation_i,
        enable_translation_i
      });

  assign lsu_mode =
      mode_t'({
        ld_st_v_i,
        en_ld_st_g_translation_i,
        en_ld_st_translation_i
      });

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

  //VPN     = virtual address bits [40:12]
  function automatic vpn_t vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr =
        vaddr[12+CVA6Cfg.VpnLen-1:12];
  endfunction

  function automatic logic [CVA6Cfg.PLEN-1:0] passthrough_paddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    passthrough_paddr = CVA6Cfg.PLEN'(vaddr);
  endfunction

  // ---------------------------------------------------------------------------
  // Expected physical address represented by a private-TLB update
  //
  // Translation sequence:
  //   S-stage only:
  //       VA -> PA
  //   G-stage only:
  //       input guest physical address -> PA
  //   Two-stage:
  //       VA -> GPA -> PA
  //
  // Page-size handling:
  //   4 KiB:
  //       use the PTE PPN directly
  //   64 KiB Svnapot:
  //       replace S-stage PPN[3:0] with VA[15:12]
  //   2 MiB:
  //       replace PPN[8:0]
  //   1 GiB:
  //       replace PPN[17:0]
  //
  // For a G-stage superpage, the replacement bits come from the computed
  // guest physical address, not directly from the original virtual address.
  // ---------------------------------------------------------------------------

  function automatic logic [CVA6Cfg.PLEN-1:0]
      expected_paddr_from_private_update(
        input tlb_update_cva6_t update,
        input logic [CVA6Cfg.VLEN-1:0] vaddr
      );

    ppn_t s_stage_ppn;
    ppn_t g_stage_ppn;
    ppn_t final_ppn;
    logic [CVA6Cfg.GPLEN-1:0] guest_paddr;

    begin
      s_stage_ppn = update.content.ppn;
      g_stage_ppn = update.g_content.ppn;
      final_ppn  = '0;
      guest_paddr = '0;
      // -----------------------------------------------------------------------
      // S-stage: VA -> GPA
      // -----------------------------------------------------------------------
      if (update.v_st_enbl[0]) begin
        // 64 KiB Svnapot.
        if (CVA6Cfg.SvnapotEn && update.is_napot_64k) begin
          s_stage_ppn[3:0] = vaddr[15:12];
        end
        // 2 MiB S-stage page.
        if (update.is_page[1][0]) begin
          s_stage_ppn[VPN_LEVEL_BITS-1:0] = vaddr[12+VPN_LEVEL_BITS-1:12];
        end
        // 1 GiB S-stage page.
        if (update.is_page[0][0]) begin
          s_stage_ppn[2*VPN_LEVEL_BITS-1:0] = vaddr[12+2*VPN_LEVEL_BITS-1:12];
        end
        guest_paddr = {s_stage_ppn[CVA6Cfg.GPPNW-1:0],vaddr[11:0]};

      end else begin
        // Pure G-stage translation:
        // the incoming address is already a guest physical address.
        guest_paddr = CVA6Cfg.GPLEN'(vaddr);
      end

      // -----------------------------------------------------------------------
      // G-stage: GPA -> PA
      // -----------------------------------------------------------------------
      if (update.v_st_enbl[HYP_EXT]) begin

        // 2 MiB G-stage page.
        if (update.is_page[1][HYP_EXT]) begin
          g_stage_ppn[VPN_LEVEL_BITS-1:0] =guest_paddr[12+VPN_LEVEL_BITS-1:12];
        end
        // 1 GiB G-stage page.
        if (update.is_page[0][HYP_EXT]) begin
          g_stage_ppn[2*VPN_LEVEL_BITS-1:0] =guest_paddr[12+2*VPN_LEVEL_BITS-1:12];
        end

        final_ppn = g_stage_ppn;
      end else begin
        final_ppn = s_stage_ppn;
      end
      expected_paddr_from_private_update = CVA6Cfg.PLEN'({ final_ppn, vaddr[11:0]});
    end
  endfunction
  // ---------------------------------------------------------------------------
  // Request and terminal events
  // ---------------------------------------------------------------------------

  wire fetch_request;
  wire fetch_success;

  wire fetch_clean_terminal;
  wire fetch_error_terminal;
  wire fetch_terminal;

  wire lsu_request;
  wire lsu_hit_event;

  wire lsu_clean_terminal;
  wire lsu_error_terminal;
  wire lsu_terminal;

  // ---------------------------------------------------------------------------
  // Instruction-fetch outcomes
  // A fetch transaction terminates with exactly one of:
  //   1. A clean translated result:
  //        fetch_valid = 1
  //        fetch_exception.valid = 0
  //   2. An exception result:
  //        fetch_exception.valid = 1
  // fetch_valid is not required for every immediate fetch exception, so the
  // exception bit itself is included in fetch_terminal.
  // ---------------------------------------------------------------------------

  assign fetch_clean_terminal =
      icache_areq_o.fetch_valid &&
      !icache_areq_o.fetch_exception.valid;

  assign fetch_error_terminal =
      icache_areq_o.fetch_exception.valid;

  assign fetch_terminal =
      fetch_clean_terminal ||
      fetch_error_terminal;

  // ---------------------------------------------------------------------------
  // LSU outcomes
  //
  // lsu_valid_o marks the final LSU response. The exception bit distinguishes
  // a clean physical address from a failed translation.
  // ---------------------------------------------------------------------------

  assign lsu_clean_terminal =
      lsu_valid_o &&
      !lsu_exception_o.valid;

  assign lsu_error_terminal =
      lsu_valid_o &&
      lsu_exception_o.valid;

  assign lsu_terminal =
      lsu_clean_terminal ||
      lsu_error_terminal;

  // ---------------------------------------------------------------------------
  // Request events
  // ---------------------------------------------------------------------------

  assign fetch_request =
      instr_translation_enabled &&
      icache_areq_i.fetch_req;

  assign fetch_success =
      fetch_request &&
      fetch_clean_terminal &&
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
  // Pending LSU transaction
  //
  // The complete request context is captured on a translated DTLB miss and
  // remains stable until the MMU returns a clean result or an exception.
  // ---------------------------------------------------------------------------

  logic lsu_pending_q;

  logic [CVA6Cfg.VLEN-1:0] held_lsu_vaddr_q;
  logic [31:0] held_lsu_tinst_q;

  logic held_lsu_store_q;
  logic held_lsu_hlvx_q;
  logic held_lsu_hs_inst_q;

  logic held_lsu_s_stage_q;
  logic held_lsu_g_stage_q;
  logic held_lsu_v_q;

  asid_t held_lsu_asid_q;
  vmid_t held_lsu_vmid_q;

  riscv::priv_lvl_t held_lsu_priv_q;

  logic held_lsu_sum_q;
  logic held_lsu_vs_sum_q;
  logic held_lsu_mxr_q;
  logic held_lsu_vmxr_q;
  logic held_lsu_mbe_q;

  logic [CVA6Cfg.PPNW-1:0] held_lsu_satp_q;
  logic [CVA6Cfg.PPNW-1:0] held_lsu_vsatp_q;
  logic [CVA6Cfg.PPNW-1:0] held_lsu_hgatp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_pending_q        <= 1'b0;

      held_lsu_vaddr_q     <= '0;
      held_lsu_tinst_q     <= '0;
      held_lsu_store_q     <= 1'b0;
      held_lsu_hlvx_q      <= 1'b0;
      held_lsu_hs_inst_q   <= 1'b0;
      held_lsu_s_stage_q   <= 1'b0;
      held_lsu_g_stage_q   <= 1'b0;
      held_lsu_v_q         <= 1'b0;
      held_lsu_asid_q      <= '0;
      held_lsu_vmid_q      <= '0;
      held_lsu_priv_q      <= riscv::PRIV_LVL_M;
      held_lsu_sum_q       <= 1'b0;
      held_lsu_vs_sum_q    <= 1'b0;
      held_lsu_mxr_q       <= 1'b0;
      held_lsu_vmxr_q      <= 1'b0;
      held_lsu_mbe_q       <= 1'b0;
      held_lsu_satp_q      <= '0;
      held_lsu_vsatp_q     <= '0;
      held_lsu_hgatp_q     <= '0;

    end else if (any_flush) begin
      lsu_pending_q <= 1'b0;

    end else begin
      if (
        !lsu_pending_q && lsu_request && !lsu_dtlb_hit_o && !lsu_terminal) begin
        lsu_pending_q        <= 1'b1;

        held_lsu_vaddr_q     <= lsu_vaddr_i;
        held_lsu_tinst_q     <= lsu_tinst_i;
        held_lsu_store_q     <= lsu_is_store_i;
        held_lsu_hlvx_q      <= hlvx_inst_i;
        held_lsu_hs_inst_q   <= hs_ld_st_inst_i;
        held_lsu_s_stage_q   <= en_ld_st_translation_i;
        held_lsu_g_stage_q   <= en_ld_st_g_translation_i;
        held_lsu_v_q         <= ld_st_v_i;
        held_lsu_asid_q      <= lsu_effective_asid;
        held_lsu_vmid_q      <= vmid_i;
        held_lsu_priv_q      <= ld_st_priv_lvl_i;
        held_lsu_sum_q       <= sum_i;
        held_lsu_vs_sum_q    <= vs_sum_i;
        held_lsu_mxr_q       <= mxr_i;
        held_lsu_vmxr_q      <= vmxr_i;
        held_lsu_mbe_q       <= mbe_i;
        held_lsu_satp_q      <= satp_ppn_i;
        held_lsu_vsatp_q     <= vsatp_ppn_i;
        held_lsu_hgatp_q     <= hgatp_ppn_i;

      end else if (lsu_pending_q && lsu_terminal) begin
        lsu_pending_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pending instruction-fetch transaction
  //
  // Capture all translation-context controls that can select the page tables
  // or change how the page-table walk is interpreted.
  // ---------------------------------------------------------------------------

  logic fetch_pending_q;

  logic [CVA6Cfg.VLEN-1:0] held_fetch_vaddr_q;

  logic held_fetch_s_stage_q;
  logic held_fetch_g_stage_q;
  logic held_fetch_v_q;

  asid_t held_fetch_asid_q;
  vmid_t held_fetch_vmid_q;

  riscv::priv_lvl_t held_fetch_priv_q;

  logic held_fetch_mbe_q;

  logic [CVA6Cfg.PPNW-1:0] held_fetch_satp_q;
  logic [CVA6Cfg.PPNW-1:0] held_fetch_vsatp_q;
  logic [CVA6Cfg.PPNW-1:0] held_fetch_hgatp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pending_q        <= 1'b0;

      held_fetch_vaddr_q     <= '0;
      held_fetch_s_stage_q   <= 1'b0;
      held_fetch_g_stage_q   <= 1'b0;
      held_fetch_v_q         <= 1'b0;
      held_fetch_asid_q      <= '0;
      held_fetch_vmid_q      <= '0;
      held_fetch_priv_q      <= riscv::PRIV_LVL_M;
      held_fetch_mbe_q       <= 1'b0;
      held_fetch_satp_q      <= '0;
      held_fetch_vsatp_q     <= '0;
      held_fetch_hgatp_q     <= '0;

    end else if (any_flush) begin
      fetch_pending_q <= 1'b0;

    end else begin
      if ( !fetch_pending_q && fetch_request && !fetch_terminal) begin
        fetch_pending_q        <= 1'b1;

        held_fetch_vaddr_q     <= icache_areq_i.fetch_vaddr;
        held_fetch_s_stage_q   <= enable_translation_i;
        held_fetch_g_stage_q   <= enable_g_translation_i;
        held_fetch_v_q         <= v_i;
        held_fetch_asid_q      <= fetch_effective_asid;
        held_fetch_vmid_q      <= vmid_i;
        held_fetch_priv_q      <= priv_lvl_i;
        held_fetch_mbe_q       <= mbe_i;
        held_fetch_satp_q      <= satp_ppn_i;
        held_fetch_vsatp_q     <= vsatp_ppn_i;
        held_fetch_hgatp_q     <= hgatp_ppn_i;

      end else if (fetch_pending_q && fetch_terminal) begin
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
  // Translation modes captured with the pending transactions
  // ---------------------------------------------------------------------------
  wire mode_t held_fetch_mode;
  wire mode_t held_lsu_mode;

  assign held_fetch_mode =
      mode_t'({
        held_fetch_v_q,
        held_fetch_g_stage_q,
        held_fetch_s_stage_q
      });

  assign held_lsu_mode =
      mode_t'({
        held_lsu_v_q,
        held_lsu_g_stage_q,
        held_lsu_s_stage_q
      });
  // ---------------------------------------------------------------------------
  // Match a private-ITLB update to the currently pending fetch transaction
  //
  // The update may have originated from:
  //
  //   - a shared-TLB hit, or
  //   - a completed PTW walk.
  //
  // The scoreboard deliberately does not distinguish those sources.
  // ---------------------------------------------------------------------------
  wire update_itlb_matches_pending_fetch;
  assign update_itlb_matches_pending_fetch =
      fetch_pending_q &&
      update_itlb.valid &&
      (update_itlb.vpn == vpn_from_vaddr(held_fetch_vaddr_q)) &&
      (update_itlb.v_st_enbl ==held_fetch_mode) &&
      (!held_fetch_s_stage_q ||(update_itlb.asid ==held_fetch_asid_q)) &&
      (!held_fetch_g_stage_q ||(update_itlb.vmid ==held_fetch_vmid_q)
      );

    logic fetch_expected_valid_q;

  logic [CVA6Cfg.PLEN-1:0]
      fetch_expected_paddr_q;

  tlb_update_cva6_t
      fetch_expected_update_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_expected_valid_q  <= 1'b0;
      fetch_expected_paddr_q  <= '0;
      fetch_expected_update_q <= '0;

    end else if (any_flush) begin
      fetch_expected_valid_q <= 1'b0;

    end else if (
      !fetch_pending_q &&
      fetch_request &&
      !fetch_terminal
    ) begin
      // A new fetch transaction starts. Forget the expected result belonging
      // to any older transaction.
      fetch_expected_valid_q <= 1'b0;

    end else if (
      fetch_pending_q &&
      fetch_terminal
    ) begin
      // The current transaction has completed.
      fetch_expected_valid_q <= 1'b0;

    end else if (
      update_itlb_matches_pending_fetch
    ) begin
      fetch_expected_valid_q <= 1'b1;

      fetch_expected_paddr_q <=
          expected_paddr_from_private_update(
            update_itlb,
            held_fetch_vaddr_q
          );

      fetch_expected_update_q <=
          update_itlb;
    end
  end

    // ---------------------------------------------------------------------------
  // Match a private-DTLB update to the currently pending LSU transaction
  // ---------------------------------------------------------------------------

  wire update_dtlb_matches_pending_lsu;

  assign update_dtlb_matches_pending_lsu =
      lsu_pending_q &&
      update_dtlb.valid &&

      (
        update_dtlb.vpn ==
        vpn_from_vaddr(held_lsu_vaddr_q)
      ) &&

      (
        update_dtlb.v_st_enbl ==
        held_lsu_mode
      ) &&

      (
        !held_lsu_s_stage_q ||
        (
          update_dtlb.asid ==
          held_lsu_asid_q
        )
      ) &&

      (
        !held_lsu_g_stage_q ||
        (
          update_dtlb.vmid ==
          held_lsu_vmid_q
        )
      );

        logic lsu_expected_valid_q;

  logic [CVA6Cfg.PLEN-1:0]
      lsu_expected_paddr_q;

  tlb_update_cva6_t
      lsu_expected_update_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_expected_valid_q  <= 1'b0;
      lsu_expected_paddr_q  <= '0;
      lsu_expected_update_q <= '0;

    end else if (any_flush) begin
      lsu_expected_valid_q <= 1'b0;

    end else if (
      !lsu_pending_q &&
      lsu_request &&
      !lsu_dtlb_hit_o &&
      !lsu_terminal
    ) begin
      // A new LSU transaction starts.
      lsu_expected_valid_q <= 1'b0;

    end else if (
      lsu_pending_q &&
      lsu_terminal
    ) begin
      // The current transaction has completed.
      lsu_expected_valid_q <= 1'b0;

    end else if (update_dtlb_matches_pending_lsu) begin
      lsu_expected_valid_q <= 1'b1;
      lsu_expected_paddr_q <=expected_paddr_from_private_update(update_dtlb,held_lsu_vaddr_q);
      lsu_expected_update_q <= update_dtlb;
    end
  end
  // ---------------------------------------------------------------------------
  // environment assumptions
  // ---------------------------------------------------------------------------
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
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    (lsu_vaddr_i == held_lsu_vaddr_q) &&
    (lsu_tinst_i == held_lsu_tinst_q) &&
    (lsu_is_store_i == held_lsu_store_q) &&
    (hlvx_inst_i == held_lsu_hlvx_q) &&
    (hs_ld_st_inst_i == held_lsu_hs_inst_q) &&
    (en_ld_st_translation_i == held_lsu_s_stage_q) &&
    (en_ld_st_g_translation_i == held_lsu_g_stage_q) &&
    (ld_st_v_i == held_lsu_v_q) &&
    (lsu_effective_asid == held_lsu_asid_q) &&
    (vmid_i == held_lsu_vmid_q) &&
    (ld_st_priv_lvl_i == held_lsu_priv_q) &&
    (sum_i == held_lsu_sum_q) &&
    (vs_sum_i == held_lsu_vs_sum_q) &&
    (mxr_i == held_lsu_mxr_q) &&
    (vmxr_i == held_lsu_vmxr_q) &&
    (mbe_i == held_lsu_mbe_q) &&
    (satp_ppn_i == held_lsu_satp_q) &&
    (vsatp_ppn_i == held_lsu_vsatp_q) &&
    (hgatp_ppn_i == held_lsu_hgatp_q)
  );

  a_fetch_holds_request_until_terminal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    fetch_pending_q
    |->
    icache_areq_i.fetch_req &&
    (icache_areq_i.fetch_vaddr == held_fetch_vaddr_q) &&
    (enable_translation_i == held_fetch_s_stage_q) &&
    (enable_g_translation_i == held_fetch_g_stage_q) &&
    (v_i == held_fetch_v_q) &&
    (fetch_effective_asid == held_fetch_asid_q) &&
    (vmid_i == held_fetch_vmid_q) &&
    (priv_lvl_i == held_fetch_priv_q) &&
    (mbe_i == held_fetch_mbe_q) &&
    (satp_ppn_i == held_fetch_satp_q) &&
    (vsatp_ppn_i == held_fetch_vsatp_q) &&
    (hgatp_ppn_i == held_fetch_hgatp_q)
  );

  // ---------------------------------------------------------------------------
  // Legal effective privilege levels for translated accesses
  //
  // Instruction translation is architecturally used for User or Supervisor
  // execution. Machine-mode instruction fetch does not use SATP translation.
  //
  // The LSU input is already the effective load/store privilege, including
  // MPRV processing performed upstream, so a translated LSU access is also
  // expected to use User or Supervisor privilege.
  // ---------------------------------------------------------------------------
  a_fetch_translated_privilege_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request
    |->
    (
      priv_lvl_i == riscv::PRIV_LVL_U ||
      priv_lvl_i == riscv::PRIV_LVL_S
    )
  );
  a_lsu_translated_privilege_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_request
    |->
    (
      ld_st_priv_lvl_i == riscv::PRIV_LVL_U ||
      ld_st_priv_lvl_i == riscv::PRIV_LVL_S
    )
  );
  // HLVX is a load-like hypervisor instruction. It uses execute permission
  // while reading data, so it cannot represent a store transaction.
  a_hlvx_is_load_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_req_i && hlvx_inst_i
    |->
    !lsu_is_store_i
  );
  // ---------------------------------------------------------------------------
  // Abstract contract for the OneSpin-black-boxed PTW
  // ---------------------------------------------------------------------------
  localparam int unsigned ABSTRACT_PTW_MAX_LATENCY = 8;

  logic abstract_ptw_pending_q;

  // Request type.
  logic abstract_ptw_is_instr_q;
  logic abstract_ptw_is_store_q;
  logic abstract_ptw_hlvx_q;
  // Address and translation context.
  logic [CVA6Cfg.VLEN-1:0] abstract_ptw_vaddr_q;
  mode_t abstract_ptw_mode_q;
  asid_t abstract_ptw_asid_q;
  vmid_t abstract_ptw_vmid_q;
  

  wire abstract_ptw_start;
  wire abstract_ptw_terminal;

  assign abstract_ptw_start =
      shared_tlb_access &&
      !shared_tlb_hit &&
      !abstract_ptw_pending_q &&
      !any_flush;

  // A black-box PTW transaction will either output:
  //   - a valid translation update, or
  //   - a page-table-walk error.
  // ptw_access_exception is excluded because PMP is outside this proof.
  assign abstract_ptw_terminal =
      update_shared_tlb.valid ||
      ptw_error;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      abstract_ptw_pending_q  <= 1'b0;

      abstract_ptw_is_instr_q <= 1'b0;
      abstract_ptw_is_store_q <= 1'b0;
      abstract_ptw_hlvx_q     <= 1'b0;
      abstract_ptw_vaddr_q    <= '0;
      abstract_ptw_mode_q     <= '0;
      abstract_ptw_asid_q     <= '0;
      abstract_ptw_vmid_q     <= '0;
    end else if (any_flush) begin
      abstract_ptw_pending_q <= 1'b0;
    end else begin
      if (abstract_ptw_start) begin
        abstract_ptw_pending_q <= 1'b1;

        // Use the real shared-TLB requester selector.
        abstract_ptw_is_instr_q <= itlb_req;
        abstract_ptw_is_store_q <= !itlb_req && lsu_is_store_i;
        abstract_ptw_hlvx_q <= !itlb_req && hlvx_inst_i;
        abstract_ptw_vaddr_q <= shared_tlb_vaddr;
        // Select the mode belonging to the actual requester.
        abstract_ptw_mode_q <= itlb_req ? fetch_mode : lsu_mode;
        // Select the ASID belonging to the actual requester.
        abstract_ptw_asid_q <= itlb_req ? fetch_effective_asid : lsu_effective_asid;
        abstract_ptw_vmid_q <= vmid_i;
      end
      if (abstract_ptw_pending_q && abstract_ptw_terminal) begin
        abstract_ptw_pending_q <= 1'b0;
      end
    end
  end

  // PMP is excluded from the current MMU verification scope.
  // Therefore, page-table memory access exceptions cannot be generated by
  // the black-box PTW.
  a_no_ptw_pmp_access_exception: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !ptw_access_exception
  );

  a_ptw_start_has_matching_pending_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start
    |->
    ((itlb_req && fetch_pending_q &&!lsu_pending_q) || (!itlb_req && lsu_pending_q && !fetch_pending_q )
    )
  );

  // The removed PTW implementation must eventually produce one abstract
  // outcome.
  a_ptw_eventually_returns_success_or_failure: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_start
    |->
    ##[1:ABSTRACT_PTW_MAX_LATENCY]
    abstract_ptw_terminal
  );

  // One PTW transaction cannot return a translation update and a page-table
  // error in the same cycle.
  a_ptw_has_only_one_terminal_outcome: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    !(
      update_shared_tlb.valid &&
      ptw_error
    )
  );

  // A black-box PTW result must belong to a currently tracked PTW walk.
  a_ptw_no_spurious_terminal_outcome: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_terminal
    |->
    abstract_ptw_pending_q
  );

  // The stage-specific error flags are classifications of ptw_error. They
  // cannot appear independently.
  a_ptw_stage_error_requires_ptw_error: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    (
      ptw_error_at_g_st ||
      ptw_err_at_g_int_st
    )
    |->
    ptw_error
  );

  a_ptw_active_while_pending: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q |-> ptw_active
  );

  a_ptw_walking_side_matches_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    abstract_ptw_pending_q
    |->
    walking_instr == abstract_ptw_is_instr_q
  );

  a_ptw_update_matches_pending_request: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid
    |->
    (update_vaddr == abstract_ptw_vaddr_q) &&
    (update_shared_tlb.vpn == abstract_ptw_vaddr_q[12+CVA6Cfg.VpnLen-1:12]) &&
    (update_shared_tlb.asid ==abstract_ptw_asid_q) &&
    (update_shared_tlb.vmid ==abstract_ptw_vmid_q)
  );

  a_ptw_update_is_single_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid |=> !update_shared_tlb.valid
  );

  // ---------------------------------------------------------------------------
  // A successful PTW update must represent at least one active translation stage.
  //
  // Mode encoding:
  //   abstract_ptw_mode_q[0]       = S-stage enabled
  //   abstract_ptw_mode_q[HYP_EXT] = G-stage enabled
  // ---------------------------------------------------------------------------
  a_ptw_success_has_enabled_translation_stage: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid
    |->
    (abstract_ptw_mode_q[0] || abstract_ptw_mode_q[HYP_EXT])
  );
  // ---------------------------------------------------------------------------
  // Successful S-stage or VS-stage leaf
  //
  // A successful PTW update may contain many different permission
  // combinations. Therefore, we do not force R, W, and X all high.
  // Structural RISC-V leaf legality:
  //
  //   V = 1
  //   R = 1 or X = 1
  //   W cannot be 1 when R = 0
  //   reserved bits are zero
  //   A = 1 because CVA6 does not emit a successful update with A = 0
  //
  // U, G, D, R, W, and X otherwise remain symbolic.
  // ---------------------------------------------------------------------------
  a_ptw_success_s_stage_leaf_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0]
    |->
    update_shared_tlb.content.v &&
    (update_shared_tlb.content.r || update_shared_tlb.content.x) &&
    !(update_shared_tlb.content.w && !update_shared_tlb.content.r) &&
    (update_shared_tlb.content.reserved =='0) &&
    !(update_shared_tlb.is_page[1][0] && update_shared_tlb.is_page[0][0]) &&
    update_shared_tlb.content.a
  );

  // When S-stage is disabled, the real PTW does not produce an S-stage PTE.
  a_ptw_success_has_no_disabled_s_stage_content: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    !abstract_ptw_mode_q[0]
    |->
    (update_shared_tlb.content =='0)
  );
  // ---------------------------------------------------------------------------
  // Successful G-stage leaf
  //
  // The same structural PTE rules apply to the final G-stage leaf.
  //
  // Svnapot is not modeled for G-stage in this CVA6 implementation.
  // ---------------------------------------------------------------------------
  a_ptw_success_g_stage_leaf_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    abstract_ptw_mode_q[HYP_EXT]
    |->
    update_shared_tlb.g_content.v &&
    (update_shared_tlb.g_content.r || update_shared_tlb.g_content.x) &&
    !(update_shared_tlb.g_content.w && !update_shared_tlb.g_content.r) &&
    (update_shared_tlb.g_content.reserved =='0) &&
    !(update_shared_tlb.is_page[1][HYP_EXT] && update_shared_tlb.is_page[0][HYP_EXT]) &&
    update_shared_tlb.g_content.a &&
    !update_shared_tlb.g_content.n
  );
  // When G-stage is disabled, the real PTW emits no G-stage PTE.
  a_ptw_success_has_no_disabled_g_stage_content: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    !abstract_ptw_mode_q[HYP_EXT]
    |->
    (update_shared_tlb.g_content =='0)
  );

  // ---------------------------------------------------------------------------
  // 64 KiB Svnapot legality
  //
  // CVA6 recognizes one Svnapot encoding:
  //
  //   N = 1
  //   PPN[3:0] = 4'b1000
  //   PTW leaf level corresponds to an ordinary 4 KiB leaf
  //
  // Therefore, a NAPOT page cannot simultaneously be marked as a 2 MiB or
  // 1 GiB S-stage superpage.
  // ---------------------------------------------------------------------------
  a_ptw_success_napot_shape_is_legal: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    update_shared_tlb.is_napot_64k
    |->
    CVA6Cfg.SvnapotEn &&
    abstract_ptw_mode_q[0] &&
    update_shared_tlb.content.n &&
    (update_shared_tlb.content.ppn[3:0] == 4'b1000) &&
    !update_shared_tlb.is_page[1][0] &&
    !update_shared_tlb.is_page[0][0] &&
    update_shared_tlb.content.n == update_shared_tlb.is_napot_64k
  );

  // ---------------------------------------------------------------------------
  // S-stage superpage alignment
  //
  // 2 MiB page:
  //   PPN[8:0] must be zero.
  //
  // 1 GiB page:
  //   PPN[17:0] must be zero.
  // ---------------------------------------------------------------------------
  a_ptw_success_s_stage_superpages_are_aligned: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid
    |->
    (!update_shared_tlb.is_page[1][0] || (update_shared_tlb.content.ppn[VPN_LEVEL_BITS-1:0] == '0)) && (!update_shared_tlb.is_page[0][0] || (update_shared_tlb.content.ppn[2*VPN_LEVEL_BITS-1:0] == '0))
  );

  // ---------------------------------------------------------------------------
  // G-stage superpage alignment
  // ---------------------------------------------------------------------------
  a_ptw_success_g_stage_superpages_are_aligned: assume property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid
    |->
    (!update_shared_tlb.is_page[1][HYP_EXT] || (update_shared_tlb.g_content.ppn[VPN_LEVEL_BITS-1:0] == '0))&&
    (!update_shared_tlb.is_page[0][HYP_EXT] || ( update_shared_tlb.g_content.ppn[2*VPN_LEVEL_BITS-1:0] == '0))
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

  p_lsu_hit_produces_terminal_response_next_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event |=> lsu_terminal
  );

  p_lsu_clean_result_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_hit_packet_valid_q &&
    lsu_clean_terminal
    |->
    lsu_paddr_o[11:0] ==
    lsu_hit_vaddr_q[11:0]
  );

  // ---------------------------------------------------------------------------
  // Refilled fetch translation integrity
  //
  // If the pending request received a matching private-ITLB update and then
  // returned a clean result, the final physical address must equal the
  // translation represented by that update.
  // ---------------------------------------------------------------------------
  p_fetch_refilled_clean_result_matches_expected_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
        fetch_pending_q &&
        fetch_expected_valid_q &&
        fetch_clean_terminal
        |->
        (icache_areq_o.fetch_paddr == fetch_expected_paddr_q)
  );

  // ---------------------------------------------------------------------------
  // Refilled LSU early-PPN integrity
  //
  // When the held LSU request hits after a matching DTLB update, the
  // same-cycle lsu_dtlb_ppn_o must equal the expected translated PPN.
  //
  // This is neutral with respect to page size. A legal 2 MiB or 1 GiB
  // counterexample will therefore expose the historical PPN-indexing bug
  // naturally.
  // ---------------------------------------------------------------------------
  p_lsu_refilled_hit_ppn_matches_expected_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
      lsu_pending_q &&
      lsu_expected_valid_q &&
      lsu_request &&
      lsu_dtlb_hit_o
      |->
      (lsu_dtlb_ppn_o == ppn_from_paddr(lsu_expected_paddr_q))
      );

  // ---------------------------------------------------------------------------
  // Refilled LSU final-result integrity
  //
  // After the DTLB hit has been registered, the next clean LSU response must
  // use the full expected physical address.
  // ---------------------------------------------------------------------------
  p_lsu_refilled_clean_result_matches_expected_translation: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
      lsu_pending_q &&
      lsu_expected_valid_q &&
      lsu_hit_packet_valid_q &&
      lsu_clean_terminal
      |->
      (lsu_paddr_o ==lsu_expected_paddr_q)
    );
  p_lsu_early_translation_matches_final_clean_result: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_packet_valid_q &&
    lsu_clean_terminal
    |->
    ppn_from_paddr(lsu_paddr_o) == lsu_hit_ppn_q
  );

  p_fetch_clean_result_preserves_page_offset: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
    |->
    icache_areq_o.fetch_paddr[11:0] ==
    icache_areq_i.fetch_vaddr[11:0]
  );

  // ---------------------------------------------------------------------------
  // Covers
  // ---------------------------------------------------------------------------

  c_ptw_success_outcome_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    update_shared_tlb.valid
  );

  c_ptw_error_outcome_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    ptw_error
  );

  c_ptw_g_stage_error_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    ptw_error &&
    ptw_error_at_g_st
  );

  c_ptw_g_intermediate_stage_error_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    ptw_error &&
    ptw_err_at_g_int_st
  );

  c_fetch_success_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_success
  );

  c_lsu_load_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event &&
    !lsu_is_store_i
    ##1
    lsu_clean_terminal
  );

  c_lsu_store_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event &&
    lsu_is_store_i
    ##1
    lsu_clean_terminal
  );

  // ---------------------------------------------------------------------------
  // PTW requester and translation-mode coverage
  // ---------------------------------------------------------------------------

  c_ptw_instruction_walk_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_start &&
    itlb_req
  );

  c_ptw_lsu_walk_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_start &&
    !itlb_req
  );

  c_ptw_load_walk_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    !abstract_ptw_is_instr_q &&
    !abstract_ptw_is_store_q &&
    !abstract_ptw_hlvx_q
  );

  c_ptw_store_walk_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    !abstract_ptw_is_instr_q &&
    abstract_ptw_is_store_q
  );

  c_ptw_hlvx_walk_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    abstract_ptw_pending_q &&
    abstract_ptw_hlvx_q
  );

  // ---------------------------------------------------------------------------
  // S-stage page-size coverage
  // ---------------------------------------------------------------------------
  c_ptw_s_stage_4k_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0] &&
    !update_shared_tlb.is_napot_64k &&
    !update_shared_tlb.is_page[1][0] &&
    !update_shared_tlb.is_page[0][0]
  );
  c_ptw_s_stage_2m_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0] &&
    update_shared_tlb.is_page[1][0]
  );
  c_ptw_s_stage_1g_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0] &&
    update_shared_tlb.is_page[0][0]
  );
  c_ptw_s_stage_napot_64k_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    CVA6Cfg.SvnapotEn &&
    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0] &&
    update_shared_tlb.is_napot_64k
  );
  // ---------------------------------------------------------------------------
  // G-stage page-size coverage
  // ---------------------------------------------------------------------------
  c_ptw_g_stage_4k_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    abstract_ptw_mode_q[HYP_EXT] &&
    !update_shared_tlb.is_page[1][HYP_EXT] &&
    !update_shared_tlb.is_page[0][HYP_EXT]
  );
  c_ptw_g_stage_2m_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    abstract_ptw_mode_q[HYP_EXT] &&
    update_shared_tlb.is_page[1][HYP_EXT]
  );
  c_ptw_g_stage_1g_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    abstract_ptw_mode_q[HYP_EXT] &&
    update_shared_tlb.is_page[0][HYP_EXT]
  );

  c_ptw_two_stage_update_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    update_shared_tlb.valid &&
    abstract_ptw_mode_q[0] &&
    abstract_ptw_mode_q[HYP_EXT]
  );

  // ---------------------------------------------------------------------------
  // Instruction translation-mode coverage
  // ---------------------------------------------------------------------------

  c_fetch_s_stage_only_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    icache_areq_i.fetch_req &&
    enable_translation_i &&
    !enable_g_translation_i
  );

  c_fetch_g_stage_only_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    icache_areq_i.fetch_req &&
    !enable_translation_i &&
    enable_g_translation_i
  );

  c_fetch_two_stage_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    icache_areq_i.fetch_req &&
    enable_translation_i &&
    enable_g_translation_i
  );

  // ---------------------------------------------------------------------------
  // LSU translation-mode coverage
  // ---------------------------------------------------------------------------

  c_lsu_s_stage_only_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_req_i &&
    !misaligned_ex_i.valid &&
    en_ld_st_translation_i &&
    !en_ld_st_g_translation_i
  );

  c_lsu_g_stage_only_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_req_i &&
    !misaligned_ex_i.valid &&
    !en_ld_st_translation_i &&
    en_ld_st_g_translation_i
  );

  c_lsu_two_stage_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_req_i &&
    !misaligned_ex_i.valid &&
    en_ld_st_translation_i &&
    en_ld_st_g_translation_i
  );

    // ---------------------------------------------------------------------------
  // Privilege and hypervisor-feature coverage
  // ---------------------------------------------------------------------------

  c_fetch_user_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    fetch_request &&
    priv_lvl_i == riscv::PRIV_LVL_U
  );

  c_fetch_supervisor_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    fetch_request &&
    priv_lvl_i == riscv::PRIV_LVL_S
  );

  c_lsu_user_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    ld_st_priv_lvl_i == riscv::PRIV_LVL_U
  );

  c_lsu_supervisor_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    ld_st_priv_lvl_i == riscv::PRIV_LVL_S
  );

  c_lsu_hlvx_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    hlvx_inst_i &&
    !lsu_is_store_i
  );

  c_lsu_sum_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    sum_i
  );

  c_lsu_vs_sum_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    ld_st_v_i &&
    vs_sum_i
  );

  c_lsu_mxr_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    mxr_i
  );

  c_lsu_vmxr_request_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    lsu_request &&
    ld_st_v_i &&
    vmxr_i
  );

  c_big_endian_ptw_context_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)

    (
      fetch_pending_q ||
      lsu_pending_q
    ) &&
    mbe_i
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
    lsu_clean_terminal
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
    fetch_clean_terminal
  );

endmodule

bind cva6_mmu cva6_mmu_scoreboard_bind
  i_cva6_mmu_scoreboard_bind (.*);
