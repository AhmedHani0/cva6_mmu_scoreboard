// cva6_mmu_scoreboard_interface_real_ptw.sv
// -----------------------------------------------------------------------------
// Simple transaction-oriented CVA6 MMU scoreboard.
//
// Methodology
//   * Keep the real PTW, shared TLB, ITLB, and DTLB concrete.
//   * Track requests only at the MMU interface.
//   * Do not observe PTW/shared-TLB/update/replacement state.
//   * Hold each request and its architectural context until completion.
//   * LSU data integrity is checked from the visible cycle-0 DTLB PPN to the
//     visible cycle-1 physical address.
//   * Fetch data integrity uses one limited read-only ITLB lookup observation,
//     because the public fetch interface does not expose an early PPN.
//
// The only internal observations are:
//   itlb_lu_hit, itlb_content.ppn, itlb_g_content.ppn, itlb_is_page
//
// The checker does not prove that a TLB mapping equals the page-table contents.
// It proves that the selected translation is propagated consistently to the
// final MMU output. This is sufficient to expose the historical LSU superpage
// PPN-position bug.
// -----------------------------------------------------------------------------

module cva6_mmu_scoreboard_bind
  import ariane_pkg::*;
  import cva6_mmu_formal_pkg::*;
#(
  // Maximum latency of one real PTW walk for a three-level configuration.
  parameter int unsigned PTW_MAX_LATENCY = 54,

  // A private-TLB refill and the final MMU response need a small number of
  // cycles after the PTW has completed.
  parameter int unsigned RESPONSE_MARGIN = 2
) (
  input logic clk_i,
  input logic rst_ni,

  input logic flush_i,
  input logic flush_tlb_i,
  input logic flush_tlb_vvma_i,
  input logic flush_tlb_gvma_i,

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

  // Public miss/performance outputs. They mark that this request has actually
  // reached the real PTW, so arbitration time before PTW selection is excluded
  // from the bounded PTW-latency property.
  input logic itlb_miss_o,
  input logic dtlb_miss_o,

  // External PTW memory interface. These are MMU ports.
  input dcache_req_o_t req_port_i,
  input dcache_req_i_t req_port_o,

  // ---------------------------------------------------------------------------
  // Limited read-only ITLB observation for fetch data integrity only.
  // ---------------------------------------------------------------------------
  input logic itlb_lu_hit_i,
  input logic [CVA6Cfg.PPNW-1:0] itlb_content_ppn_i,
  input logic [CVA6Cfg.PPNW-1:0] itlb_g_content_ppn_i,
  input logic [CVA6Cfg.PtLevels-2:0] itlb_is_page_i
);

  typedef logic [CVA6Cfg.PPNW-1:0] ppn_t;

  localparam int unsigned VPN_LEVEL_BITS =
      CVA6Cfg.VpnLen / CVA6Cfg.PtLevels;

  localparam int unsigned PTW_TO_RESPONSE_MAX =
      PTW_MAX_LATENCY + RESPONSE_MARGIN + 5;

  wire any_flush;
  wire fetch_translation_enabled;
  wire lsu_translation_enabled;

  assign any_flush =
      flush_i || flush_tlb_i || flush_tlb_vvma_i || flush_tlb_gvma_i;

  assign fetch_translation_enabled =
      enable_translation_i || enable_g_translation_i;

  assign lsu_translation_enabled =
      en_ld_st_translation_i || en_ld_st_g_translation_i;

  wire fetch_request;
  wire fetch_clean_terminal;
  wire fetch_error_terminal;
  wire fetch_terminal;

  assign fetch_request = icache_areq_i.fetch_req;
  assign fetch_clean_terminal =
      icache_areq_o.fetch_valid && !icache_areq_o.fetch_exception.valid;
  assign fetch_error_terminal = icache_areq_o.fetch_exception.valid;
  assign fetch_terminal = fetch_clean_terminal || fetch_error_terminal;

  wire lsu_clean_terminal;
  wire lsu_error_terminal;
  wire lsu_terminal;

  assign lsu_clean_terminal = lsu_valid_o && !lsu_exception_o.valid;
  assign lsu_error_terminal = lsu_valid_o && lsu_exception_o.valid;
  assign lsu_terminal = lsu_valid_o;

  function automatic logic [CVA6Cfg.PLEN-1:0] passthrough_paddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    passthrough_paddr = CVA6Cfg.PLEN'(vaddr);
  endfunction

  // ---------------------------------------------------------------------------
  // Expected instruction physical address from the selected ITLB lookup.
  //
  // S-stage only:
  //   itlb_content_ppn_i is already patched for 64 KiB NAPOT. The checker
  //   independently inserts VA bits for 2 MiB and 1 GiB superpages.
  //
  // G-stage or two-stage:
  //   itlb_g_content_ppn_i is the ITLB lookup's effective final G-stage PPN.
  //   It already contains GPA-derived superpage substitutions.
  // ---------------------------------------------------------------------------
    function automatic logic [CVA6Cfg.PLEN-1:0] expected_fetch_paddr(
        input logic [CVA6Cfg.VLEN-1:0] vaddr,
        input logic g_stage_enabled,
        input ppn_t s_stage_ppn,
        input ppn_t g_stage_ppn,
        input logic [CVA6Cfg.PtLevels-2:0] is_page
    );
    logic [CVA6Cfg.PLEN-1:0] result;
    ppn_t selected_ppn;

    localparam int PPNWMin =
        (CVA6Cfg.PPNW - 1 > 29) ? 29 : CVA6Cfg.PPNW - 1;

    begin
        selected_ppn =
            (g_stage_enabled && CVA6Cfg.RVH)
                ? g_stage_ppn
                : s_stage_ppn;

        result = {selected_ppn, vaddr[11:0]};

        // 2 MiB superpage substitution.
        // This applies after either S-stage or G-stage PPN selection.
        if ((CVA6Cfg.PtLevels == 3) &&
            is_page[CVA6Cfg.PtLevels-2]) begin

        result[
            PPNWMin-(CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)
            :
            9+CVA6Cfg.PtLevels
        ] =
        vaddr[
            PPNWMin-(CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)
            :
            9+CVA6Cfg.PtLevels
        ];
        end

        // 1 GiB superpage substitution.
        if (is_page[0]) begin
        result[PPNWMin:12] = vaddr[PPNWMin:12];
        end

        expected_fetch_paddr = result;
    end
    endfunction

  wire [CVA6Cfg.PLEN-1:0] fetch_expected_paddr;
  assign fetch_expected_paddr = expected_fetch_paddr(
      icache_areq_i.fetch_vaddr,
      enable_g_translation_i,
      itlb_content_ppn_i,
      itlb_g_content_ppn_i,
      itlb_is_page_i
  );

  // ---------------------------------------------------------------------------
  // Request tracking.
  //
  // A direct instruction hit may terminate in the request cycle and therefore
  // never enters the pending state. An LSU response is registered, so every LSU
  // request enters pending state until its cycle-1 terminal response.
  // ---------------------------------------------------------------------------
  logic fetch_pending_q;
  logic lsu_pending_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pending_q <= 1'b0;
      lsu_pending_q   <= 1'b0;
    end else if (any_flush) begin
      fetch_pending_q <= 1'b0;
      lsu_pending_q   <= 1'b0;
    end else begin
      if (fetch_pending_q) begin
        if (fetch_terminal) fetch_pending_q <= 1'b0;
      end else if (fetch_request && !fetch_terminal) begin
        fetch_pending_q <= 1'b1;
      end

      if (lsu_pending_q) begin
        if (lsu_terminal) lsu_pending_q <= 1'b0;
      end else if (lsu_req_i) begin
        lsu_pending_q <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LSU cycle-0 hit packet.
  // lsu_dtlb_ppn_o is defined as an effective PPN. Therefore appending the
  // original 4 KiB offset creates the exact address promised by the cycle-0
  // MMU interface, independent of page size and translation mode.
  // ---------------------------------------------------------------------------
logic lsu_prev_misaligned_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    lsu_prev_misaligned_q <= 1'b0;
  end else begin
    lsu_prev_misaligned_q <=
        misaligned_ex_i.valid && lsu_req_i;
  end
end

  wire lsu_hit_event;
  wire [CVA6Cfg.PPNW-1:0] lsu_true_ppn;
  logic lsu_hit_packet_valid_q;
  logic [CVA6Cfg.PPNW-1:0]  lsu_hit_ppn_q;
  logic [CVA6Cfg.PLEN-1:0] lsu_hit_expected_paddr_q;

  assign lsu_hit_event =
      lsu_req_i &&
      lsu_translation_enabled &&
      !misaligned_ex_i.valid &&
      !lsu_prev_misaligned_q &&
      lsu_dtlb_hit_o &&
      !any_flush;
  
  assign lsu_true_ppn =
    CVA6Cfg.PPNW'(
      lsu_paddr_o[CVA6Cfg.PLEN-1:12]
    );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_hit_packet_valid_q   <= 1'b0;
      lsu_hit_expected_paddr_q <= '0;
      lsu_hit_ppn_q          <= '0;

    end else if (any_flush) begin
      lsu_hit_packet_valid_q   <= 1'b0;
      lsu_hit_expected_paddr_q <= '0;
      lsu_hit_ppn_q          <= '0;

    end else begin
      lsu_hit_packet_valid_q <= lsu_hit_event;
      if (lsu_hit_event) begin
        // here we take the cycle N ppn output to create the physical address
        lsu_hit_expected_paddr_q <= {
          lsu_dtlb_ppn_o,
          lsu_vaddr_i[11:0]
        };
        lsu_hit_ppn_q <= lsu_dtlb_ppn_o;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Environment assumptions.
  // ---------------------------------------------------------------------------

  // Instruction requests are level-held because fetch_valid is generated in
  // the same cycle as the eventual ITLB hit.
a_fetch_request_context_held_until_response: assume property (
  @(posedge clk_i) disable iff (!rst_ni || any_flush)
  fetch_request &&
  !fetch_terminal
  |=>
  // Keep the translation context associated with the same request.
  $stable(icache_areq_i.fetch_vaddr) &&
  $stable(enable_translation_i) &&
  $stable(enable_g_translation_i) &&
  $stable(priv_lvl_i) &&
  $stable(v_i) &&
  $stable(mxr_i) &&
  $stable(vmxr_i) &&
  $stable(mbe_i) &&
  $stable(satp_ppn_i) &&
  $stable(vsatp_ppn_i) &&
  $stable(hgatp_ppn_i) &&
  $stable(asid_i) &&
  $stable(vs_asid_i) &&
  $stable(vmid_i) &&
  // Until there is a response, the request must remain presented.
  (fetch_terminal || fetch_request)
);

  // Before the registered LSU response, the request and its context are held.
  a_lsu_request_context_held_until_response: assume property (
  @(posedge clk_i) disable iff (!rst_ni || any_flush)
  lsu_req_i &&
  !misaligned_ex_i.valid &&
  !lsu_terminal
  |=>
  lsu_terminal ||
  (
    lsu_req_i &&
    !misaligned_ex_i.valid &&
    $stable(lsu_vaddr_i) &&
    $stable(lsu_tinst_i) &&
    $stable(lsu_is_store_i) &&
    $stable(hs_ld_st_inst_i) &&
    $stable(en_ld_st_translation_i) &&
    $stable(en_ld_st_g_translation_i) &&
    $stable(ld_st_priv_lvl_i) &&
    $stable(ld_st_v_i) &&
    $stable(sum_i) &&
    $stable(vs_sum_i) &&
    $stable(mxr_i) &&
    $stable(vmxr_i) &&
    $stable(mbe_i) &&
    $stable(hlvx_inst_i) &&
    $stable(satp_ppn_i) &&
    $stable(vsatp_ppn_i) &&
    $stable(hgatp_ppn_i) &&
    $stable(asid_i) &&
    $stable(vs_asid_i) &&
    $stable(vmid_i)
  )
);

a_lsu_translation_mode_stable_after_hit: assume property (
  @(posedge clk_i)disable iff (!rst_ni || any_flush)
  lsu_hit_event
  |=>
  (en_ld_st_translation_i == $past(en_ld_st_translation_i)) &&
  (en_ld_st_g_translation_i == $past(en_ld_st_g_translation_i))
);

a_fetch_not_starved_by_lsu: assume property (
  @(posedge clk_i)disable iff (!rst_ni || any_flush)
  fetch_request &&
  !fetch_terminal
  |->
  !(lsu_req_i && !misaligned_ex_i.valid)
);
  // External memory fairness for the real PTW. No constraint is placed on the
  // returned PTE data; it may describe any legal/illegal page-table path.
  a_ptw_request_is_granted: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req
    |->
    ##[1:3] req_port_i.data_gnt
  );

  a_ptw_tag_gets_response_next_cycle: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.tag_valid
    |->
    ##[1:3] req_port_i.data_rvalid
  );

  a_no_spurious_ptw_memory_response: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_rvalid
    |->
    $past(req_port_o.tag_valid)
  );

  // ---------------------------------------------------------------------------
  // Basic interface properties.
  // ---------------------------------------------------------------------------

  p_fetch_passthrough_integrity: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && !fetch_translation_enabled
    |->
    fetch_clean_terminal &&
    (icache_areq_o.fetch_paddr ==
     passthrough_paddr(icache_areq_i.fetch_vaddr))
  );

  p_lsu_no_translation_reports_cycle0_hit: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_req_i && !misaligned_ex_i.valid && !lsu_translation_enabled
    |->
    lsu_dtlb_hit_o
  );

  // ---------------------------------------------------------------------------
  // Data-integrity properties.
  // ---------------------------------------------------------------------------

  // Fetch is a same-cycle interface on an ITLB hit. The property checks that
  // the clean MMU output is constructed from the translation selected by the
  // ITLB lookup for the same request.
  p_fetch_translation_data_integrity: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request &&
    fetch_translation_enabled &&
    itlb_lu_hit_i &&
    fetch_clean_terminal &&
    !any_flush
    |->
    (icache_areq_o.fetch_paddr == fetch_expected_paddr)
  );

  p_fetch_itlb_hit_returns_terminal_same_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && fetch_translation_enabled && itlb_lu_hit_i && !any_flush
    |->
    fetch_terminal
  );

  // Data_Integrity property. It is generic: no page-size or
  // stage-specific case is bypassed. A correct effective cycle-0 PPN plus the
  // original 12-bit offset must equal the clean cycle-1 physical address.
p_lsu_translation_ppn_integrity: assert property (
  @(posedge clk_i) disable iff (!rst_ni || any_flush)

  lsu_hit_packet_valid_q &&
  lsu_clean_terminal

  |->
  lsu_hit_ppn_q == lsu_true_ppn
);

  p_lsu_hit_packet_capture_sanity: assert property (
  @(posedge clk_i) disable iff (!rst_ni || any_flush)
  lsu_hit_event
  |=>
  lsu_hit_packet_valid_q &&
  // Scoreboard really stored the PPN that the MMU exposed in the hit cycle.
  (lsu_hit_ppn_q == $past(lsu_dtlb_ppn_o)) &&
  // And the expected PA really consists of that same PPN plus
  // the original request's 12-bit page offset.
  (lsu_hit_expected_paddr_q ==
    {
      $past(lsu_dtlb_ppn_o),
      $past(lsu_vaddr_i[11:0])
    })
  );
  // ---------------------------------------------------------------------------
  // Liveness
  // ---------------------------------------------------------------------------

  p_lsu_mmu_liveness: assert property (
    @(posedge clk_i) disable iff (!rst_ni || any_flush)
    $rose(lsu_req_i) &&
    !lsu_terminal &&
    !misaligned_ex_i.valid
    |->
    ##[1:$] lsu_terminal
  );

  p_fetch_mmu_liveness: assert property (
    @(posedge clk_i) disable iff (!rst_ni || any_flush)
    $rose(fetch_request) &&
    !fetch_terminal
    |->
    ##[1:$]fetch_terminal
  );
  
  // ---------------------------------------------------------------------------
  // Coverage: modes, direct hits, real PTW paths, and page sizes.
  // --------------------------------------------------------------------------
  c_fetch_passthrough_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && !fetch_translation_enabled && fetch_clean_terminal
  );

  c_fetch_s_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && enable_translation_i && !enable_g_translation_i &&
    itlb_lu_hit_i && fetch_clean_terminal
  );

  c_fetch_g_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && !enable_translation_i && enable_g_translation_i &&
    itlb_lu_hit_i && fetch_clean_terminal
  );

  c_fetch_two_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && enable_translation_i && enable_g_translation_i &&
    itlb_lu_hit_i && fetch_clean_terminal
  );

  c_fetch_2m_page_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && itlb_lu_hit_i &&
    itlb_is_page_i[CVA6Cfg.PtLevels-2] && fetch_clean_terminal
  );

  c_fetch_1g_page_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_request && itlb_lu_hit_i &&
    itlb_is_page_i[0] && fetch_clean_terminal
  );

  c_lsu_s_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event && en_ld_st_translation_i && !en_ld_st_g_translation_i
    ##1
    lsu_clean_terminal
  );

  c_lsu_g_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event && !en_ld_st_translation_i && en_ld_st_g_translation_i
    ##1
    lsu_clean_terminal
  );

  c_lsu_two_stage_hit_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_hit_event && en_ld_st_translation_i && en_ld_st_g_translation_i
    ##1
    lsu_clean_terminal
  );

  c_fetch_real_ptw_path_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    fetch_pending_q && itlb_miss_o
    ##[1:PTW_TO_RESPONSE_MAX]
    fetch_terminal
  );

  c_lsu_real_ptw_path_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    lsu_pending_q && dtlb_miss_o
    ##[1:PTW_TO_RESPONSE_MAX]
    lsu_terminal
  );

  c_lsu_liveness_start_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni || any_flush)
    $rose(lsu_req_i) &&
    !lsu_terminal &&
    !misaligned_ex_i.valid
  );

  c_lsu_liveness_completion_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni || any_flush)
    ($rose(lsu_req_i) &&
    !lsu_terminal &&
    !misaligned_ex_i.valid)
    ##[1:30]
    lsu_terminal
  );

  c_lsu_completion_after_30_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni || any_flush)
    ($rose(lsu_req_i) &&
    !lsu_terminal &&
    !misaligned_ex_i.valid)
    ##30
    !lsu_terminal
    ##[1:31]
    lsu_terminal
  );

endmodule

// Explicit bind: all connections are public MMU ports except the four clearly
// identified read-only ITLB lookup observations used by the fetch checker.
bind cva6_mmu cva6_mmu_scoreboard_bind #(
  .PTW_MAX_LATENCY(54),
  .RESPONSE_MARGIN(2)
) i_cva6_mmu_scoreboard_bind (
  .clk_i                      (clk_i),
  .rst_ni                     (rst_ni),

  .flush_i                    (flush_i),
  .flush_tlb_i                (flush_tlb_i),
  .flush_tlb_vvma_i           (flush_tlb_vvma_i),
  .flush_tlb_gvma_i           (flush_tlb_gvma_i),

  .enable_translation_i       (enable_translation_i),
  .enable_g_translation_i     (enable_g_translation_i),
  .en_ld_st_translation_i     (en_ld_st_translation_i),
  .en_ld_st_g_translation_i   (en_ld_st_g_translation_i),

  .icache_areq_i              (icache_areq_i),
  .icache_areq_o              (icache_areq_o),

  .misaligned_ex_i            (misaligned_ex_i),
  .lsu_req_i                  (lsu_req_i),
  .lsu_vaddr_i                (lsu_vaddr_i),
  .lsu_tinst_i                (lsu_tinst_i),
  .lsu_is_store_i             (lsu_is_store_i),
  .hs_ld_st_inst_i            (hs_ld_st_inst_i),

  .lsu_dtlb_hit_o             (lsu_dtlb_hit_o),
  .lsu_dtlb_ppn_o             (lsu_dtlb_ppn_o),
  .lsu_valid_o                (lsu_valid_o),
  .lsu_paddr_o                (lsu_paddr_o),
  .lsu_exception_o            (lsu_exception_o),

  .priv_lvl_i                 (priv_lvl_i),
  .ld_st_priv_lvl_i           (ld_st_priv_lvl_i),
  .v_i                        (v_i),
  .ld_st_v_i                  (ld_st_v_i),
  .sum_i                      (sum_i),
  .vs_sum_i                   (vs_sum_i),
  .mxr_i                      (mxr_i),
  .vmxr_i                     (vmxr_i),
  .mbe_i                      (mbe_i),
  .hlvx_inst_i                (hlvx_inst_i),

  .satp_ppn_i                 (satp_ppn_i),
  .vsatp_ppn_i                (vsatp_ppn_i),
  .hgatp_ppn_i                (hgatp_ppn_i),
  .asid_i                     (asid_i),
  .vs_asid_i                  (vs_asid_i),
  .vmid_i                     (vmid_i),

  .itlb_miss_o                (itlb_miss_o),
  .dtlb_miss_o                (dtlb_miss_o),

  .req_port_i                 (req_port_i),
  .req_port_o                 (req_port_o),

  .itlb_lu_hit_i              (itlb_lu_hit),
  .itlb_content_ppn_i         (itlb_content.ppn),
  .itlb_g_content_ppn_i       (itlb_g_content.ppn),
  .itlb_is_page_i             (itlb_is_page)
);
