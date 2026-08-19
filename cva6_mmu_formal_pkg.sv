// cva6_mmu_formal_pkg.sv
// -----------------------------------------------------------------------------
// Formal package for standalone CVA6 MMU verification.
//
// Important:
//
// For RVH/HYP_EXT = 1, RVH must be set in the USER configuration before
// build_config() is called.
//
// Otherwise, build_config() derives the non-RVH Sv39 value:
//
//   VpnLen = 27
//
// instead of the RVH/Sv39x4 value:
//
//   VpnLen = 29
//
// -----------------------------------------------------------------------------

package cva6_mmu_formal_pkg;

  // ---------------------------------------------------------------------------
  // Force the USER configuration before build_config().
  // ---------------------------------------------------------------------------

  function automatic config_pkg::cva6_user_cfg_t force_mmu_user_cfg(
      input config_pkg::cva6_user_cfg_t cfg
  );
    force_mmu_user_cfg = cfg;
    // RV64 configuration.
    force_mmu_user_cfg.XLEN =
        unsigned'(64);
    force_mmu_user_cfg.VLEN =
        unsigned'(64);
    // Hypervisor extension.
    //
    // This must be set before build_config(), because build_config() derives
    // VpnLen from XLEN and RVH.
    force_mmu_user_cfg.RVH =
        bit'(1);
    // MMU/TLB-related features.
    force_mmu_user_cfg.MmuPresent =
        bit'(1);
    force_mmu_user_cfg.RVS =
        bit'(1);
    force_mmu_user_cfg.RVU =
        bit'(1);
    force_mmu_user_cfg.UseSharedTlb =
        bit'(1);
    // Enable Svnapot so that 64 KiB NAPOT translations can be reached and
    // verified in addition to 4 KiB and superpage translations.
    force_mmu_user_cfg.SvnapotEn =
        bit'(1);
    force_mmu_user_cfg.InstrTlbEntries = int'(2);
    force_mmu_user_cfg.DataTlbEntries  = int'(2);
    force_mmu_user_cfg.SharedTlbDepth  = int'(2);
    //disable pmp
    force_mmu_user_cfg.NrPMPEntries = unsigned'(0);
  endfunction

  localparam config_pkg::cva6_user_cfg_t CVA6UserCfg =
      force_mmu_user_cfg(
        cva6_config_pkg::cva6_cfg
      );

  localparam config_pkg::cva6_cfg_t CVA6CfgBuilt =
      build_config_pkg::build_config(
        CVA6UserCfg
      );

  // ---------------------------------------------------------------------------
  // Final sanity forcing after build_config().
  //
  // The most important correction is already applied before build_config():
  // RVH must be enabled before derived MMU widths are calculated.
  //
  // These assignments make the intended formal configuration explicit.
  // ---------------------------------------------------------------------------
  function automatic config_pkg::cva6_cfg_t force_mmu_base_cfg(
      input config_pkg::cva6_cfg_t cfg
  );
    force_mmu_base_cfg = cfg;

    force_mmu_base_cfg.XLEN =
        unsigned'(64);
    force_mmu_base_cfg.VLEN =
        unsigned'(64);
    force_mmu_base_cfg.PLEN =
        unsigned'(56);
    force_mmu_base_cfg.GPLEN =
        unsigned'(41);
    force_mmu_base_cfg.IS_XLEN32 =
        bit'(0);
    force_mmu_base_cfg.IS_XLEN64 =
        bit'(1);
    force_mmu_base_cfg.RVH =
        bit'(1);
    force_mmu_base_cfg.UseSharedTlb =
        bit'(1);
    force_mmu_base_cfg.SvnapotEn =
        bit'(1);
    // RV64 Sv39 / Sv39x4 MMU dimensions.
    force_mmu_base_cfg.PPNW =
        unsigned'(44);
    force_mmu_base_cfg.GPPNW =
        unsigned'(29);
    force_mmu_base_cfg.VpnLen =
        unsigned'(29);
    force_mmu_base_cfg.PtLevels =
        unsigned'(3);
    force_mmu_base_cfg.SV =
        unsigned'(39);
    force_mmu_base_cfg.SVX =
        unsigned'(41);
    force_mmu_base_cfg.ASID_WIDTH =
        unsigned'(16);
    force_mmu_base_cfg.VMID_WIDTH =
        unsigned'(14);
    force_mmu_base_cfg.ASIDW =
        unsigned'(16);
    force_mmu_base_cfg.VMIDW =
        unsigned'(14);
    force_mmu_base_cfg.MODE_SV =
        config_pkg::ModeSv39;
    //for safety make sure after building the config pkg that pmp is disabled
    force_mmu_base_cfg.NrPMPEntries =
        unsigned'(0);
  endfunction

  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      force_mmu_base_cfg(
        CVA6CfgBuilt
      );

  // Extra hypervisor dimension used by the CVA6 MMU and TLB types.
  localparam int unsigned HYP_EXT = 1;

  // ---------------------------------------------------------------------------
  // Local exception type
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic                     valid;
    logic [CVA6Cfg.XLEN-1:0]  cause;
    logic [CVA6Cfg.XLEN-1:0]  tval;
    logic [CVA6Cfg.GPLEN-1:0] tval2;
    logic [CVA6Cfg.XLEN-1:0]  tinst;
    logic                     gva;
  } exception_t;

  // ---------------------------------------------------------------------------
  // PTE: Page Table Entry
  //
  // This follows the field layout used by cva6_mmu.sv.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic n;
    logic [8:0] reserved;
    logic [CVA6Cfg.PPNW-1:0] ppn;
    logic [1:0] rsw;
    logic d;
    logic a;
    logic g;
    logic u;
    logic x;
    logic w;
    logic r;
    logic v;
  } pte_cva6_t;

  // ---------------------------------------------------------------------------
  // TLB update packet
  //
  // Used between:
  //
  //   - PTW;
  //   - shared TLB;
  //   - instruction TLB;
  //   - data TLB.
  //
  // This has the same shape as the local type in cva6_mmu.sv.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic valid;
    logic is_napot_64k;
    logic [CVA6Cfg.PtLevels-2:0][HYP_EXT:0] is_page;
    logic [CVA6Cfg.VpnLen-1:0] vpn;
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid;
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid;
    logic [HYP_EXT*2:0] v_st_enbl;
    pte_cva6_t content;
    pte_cva6_t g_content;
  } tlb_update_cva6_t;

  // ---------------------------------------------------------------------------
  // Instruction-side MMU input
  //
  // Virtual instruction-fetch request.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic fetch_req;
    logic [CVA6Cfg.VLEN-1:0] fetch_vaddr;
  } icache_arsp_t;

  // ---------------------------------------------------------------------------
  // Instruction-side MMU output
  //
  // Translated instruction-fetch result.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic fetch_valid;
    logic [CVA6Cfg.PLEN-1:0] fetch_paddr;
    exception_t fetch_exception;
  } icache_areq_t;

  // These two instruction-cache types are not directly used by cva6_mmu, but
  // the DUT keeps them as type parameters.
  typedef logic icache_dreq_t;
  typedef logic icache_drsp_t;

  // ---------------------------------------------------------------------------
  // Minimal cache request from PTW to the data cache.
  //
  // req_port_o from the MMU/PTW uses this type.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic                                  data_req;
    logic                                  data_we;
    logic [1:0]                            data_size;
    logic [CVA6Cfg.XLEN/8-1:0]             data_be;
    logic [CVA6Cfg.XLEN-1:0]               data_wdata;
    logic [0:0]                            data_id;
    logic [0:0]                            data_wuser;
    logic [1:0]                            cbo_op;
    logic                                  tag_valid;
    logic                                  kill_req;
  } dcache_req_i_t;

  // ---------------------------------------------------------------------------
  // Minimal cache response from the data cache to PTW.
  //
  // req_port_i into the MMU/PTW uses this type.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic                    data_gnt;
    logic                    data_rvalid;
    logic [CVA6Cfg.XLEN-1:0] data_rdata;
  } dcache_req_o_t;

endpackage