// cva6_mmu_formal_top.sv
// -----------------------------------------------------------------------------
// Standalone formal top wrapper for CVA6 MMU verification.
// -----------------------------------------------------------------------------
module cva6_mmu_formal_top
  import ariane_pkg::*;
  import cva6_mmu_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Instruction-side translation enables.
    input logic enable_translation_i,
    input logic enable_g_translation_i,

    // Load/store-side translation enables.
    input logic en_ld_st_translation_i,
    input logic en_ld_st_g_translation_i,

    // IF = Instruction Fetch interface.
    input  icache_arsp_t icache_areq_i,
    output icache_areq_t icache_areq_o,

    // LSU = Load Store Unit interface.
    input cva6_mmu_formal_pkg::exception_t misaligned_ex_i,
    input logic lsu_req_i,
    input logic [CVA6Cfg.VLEN-1:0] lsu_vaddr_i,
    input logic [31:0] lsu_tinst_i,
    input logic lsu_is_store_i,
    output logic csr_hs_ld_st_inst_o,

    // Cycle-0 DTLB response contract.
    output logic lsu_dtlb_hit_o,
    output logic [CVA6Cfg.PPNW-1:0] lsu_dtlb_ppn_o,

    // Cycle-1 LSU response contract.
    output logic lsu_valid_o,
    output logic [CVA6Cfg.PLEN-1:0] lsu_paddr_o,
    output cva6_mmu_formal_pkg::exception_t lsu_exception_o,

    // Privilege and virtualization context.
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

    // Page-table root pointers.
    input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i,

    // ASID/VMID and targeted flush controls.
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

    // Performance-counter style miss outputs.
    output logic itlb_miss_o,
    output logic dtlb_miss_o,

    // PTW memory/cache interface.
    input dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);

  // PMP = Physical Memory Protection.
  // PMP functional correctness is not the first MMU proof target. Tie PMP to
  // zero here, as in the PTW standalone proof environment.
  riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_zero;
  logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_zero;

  assign pmpcfg_zero  = '0;
  assign pmpaddr_zero = '0;

  cva6_mmu #(
      .CVA6Cfg          (CVA6Cfg),
      .icache_areq_t    (icache_areq_t),
      .icache_arsp_t    (icache_arsp_t),
      .icache_dreq_t    (icache_dreq_t),
      .icache_drsp_t    (icache_drsp_t),
      .dcache_req_i_t   (dcache_req_i_t),
      .dcache_req_o_t   (dcache_req_o_t),
      .exception_t      (cva6_mmu_formal_pkg::exception_t),
      .HYP_EXT          (HYP_EXT)
  ) i_cva6_mmu (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .flush_i                  (flush_i),
      .enable_translation_i     (enable_translation_i),
      .enable_g_translation_i   (enable_g_translation_i),
      .en_ld_st_translation_i   (en_ld_st_translation_i),
      .en_ld_st_g_translation_i (en_ld_st_g_translation_i),
      .icache_areq_i            (icache_areq_i),
      .icache_areq_o            (icache_areq_o),
      .misaligned_ex_i          (misaligned_ex_i),
      .lsu_req_i                (lsu_req_i),
      .lsu_vaddr_i              (lsu_vaddr_i),
      .lsu_tinst_i              (lsu_tinst_i),
      .lsu_is_store_i           (lsu_is_store_i),
      .csr_hs_ld_st_inst_o      (csr_hs_ld_st_inst_o),
      .lsu_dtlb_hit_o           (lsu_dtlb_hit_o),
      .lsu_dtlb_ppn_o           (lsu_dtlb_ppn_o),
      .lsu_valid_o              (lsu_valid_o),
      .lsu_paddr_o              (lsu_paddr_o),
      .lsu_exception_o          (lsu_exception_o),
      .priv_lvl_i               (priv_lvl_i),
      .v_i                      (v_i),
      .ld_st_priv_lvl_i         (ld_st_priv_lvl_i),
      .ld_st_v_i                (ld_st_v_i),
      .sum_i                    (sum_i),
      .vs_sum_i                 (vs_sum_i),
      .mxr_i                    (mxr_i),
      .vmxr_i                   (vmxr_i),
      .mbe_i                    (mbe_i),
      .hlvx_inst_i              (hlvx_inst_i),
      .hs_ld_st_inst_i          (hs_ld_st_inst_i),
      .satp_ppn_i               (satp_ppn_i),
      .vsatp_ppn_i              (vsatp_ppn_i),
      .hgatp_ppn_i              (hgatp_ppn_i),
      .asid_i                   (asid_i),
      .vs_asid_i                (vs_asid_i),
      .asid_to_be_flushed_i     (asid_to_be_flushed_i),
      .vmid_i                   (vmid_i),
      .vmid_to_be_flushed_i     (vmid_to_be_flushed_i),
      .vaddr_to_be_flushed_i    (vaddr_to_be_flushed_i),
      .gpaddr_to_be_flushed_i   (gpaddr_to_be_flushed_i),
      .flush_tlb_i              (flush_tlb_i),
      .flush_tlb_vvma_i         (flush_tlb_vvma_i),
      .flush_tlb_gvma_i         (flush_tlb_gvma_i),
      .itlb_miss_o              (itlb_miss_o),
      .dtlb_miss_o              (dtlb_miss_o),
      .req_port_i               (req_port_i),
      .req_port_o               (req_port_o),
      .pmpcfg_i                 (pmpcfg_zero),
      .pmpaddr_i                (pmpaddr_zero)
  );

endmodule
