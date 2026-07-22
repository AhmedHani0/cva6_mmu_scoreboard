# run_onespin_mmu.tcl
# -----------------------------------------------------------------------------
# OneSpin run script for standalone CVA6 MMU scoreboard verification.
#
# This script targets the old MMU source in WORK_ROOT/cva6_mmu.sv.
# It reads:
#   1. CVA6 packages/configuration.
#   2. Common support modules used by PTW/shared-TLB/TLB.
#   3. Formal package.
#   4. RTL dependencies: cva6_tlb, cva6_shared_tlb, cva6_ptw, cva6_mmu.
#   5. Formal top and black-box scoreboard bind.
# -----------------------------------------------------------------------------

# Adjust these two paths on the lab machine if needed.
if {![info exists CVA6_REPO_ROOT]} {
    set CVA6_REPO_ROOT "/import/lab/users/hassan/Downloads/MasterProjekt/cva6"
}
if {![info exists WORK_ROOT]} {
    set WORK_ROOT "/import/lab/users/hassan/Downloads/MasterProjekt/cva6_mmu_scoreboard"
}

set CVA6_RTL_ROOT "$CVA6_REPO_ROOT/core"
set SRAM_WRAPPER    $CVA6_REPO_ROOT/common/local/util/tc_sram_fpga_wrapper.sv
set SyncSpRamBenx64 $CVA6_REPO_ROOT/vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx64.sv
proc read_sv {path} {
    puts "Reading: $path"
    read_verilog -sv $path
}

proc read_sv_if_exists {path} {
    if {[file exists $path]} {
        read_sv $path
    } else {
        puts "Skipping missing optional file: $path"
    }
}

proc read_first_existing {name paths} {
    foreach p $paths {
        if {[file exists $p]} {
            puts "Reading $name from: $p"
            read_verilog -sv $p
            return $p
        }
    }
    puts "ERROR: Could not find required file for $name. Tried:"
    foreach p $paths { puts "  $p" }
    error "Missing required file: $name"
}

# -----------------------------------------------------------------------------
# 1) CVA6 packages. Prefer the 64-bit Sv39 config because the historical bug is
#    about Sv39 superpage PPN substitution.
# -----------------------------------------------------------------------------
read_sv $CVA6_RTL_ROOT/include/config_pkg.sv

read_first_existing "CVA6 64-bit config package" [list \
    $CVA6_RTL_ROOT/include/cv64a60ax_config_pkg.sv \
    $CVA6_RTL_ROOT/include/cv64a6_imafdc_sv39_config_pkg.sv \
    $CVA6_RTL_ROOT/include/cv64a6_imafdc_config_pkg.sv \
    $WORK_ROOT/cv64a60ax_config_pkg.sv \
    $WORK_ROOT/cv64a6_imafdc_sv39_config_pkg.sv \
]

read_sv $CVA6_RTL_ROOT/include/build_config_pkg.sv
read_sv $CVA6_RTL_ROOT/include/riscv_pkg.sv
read_sv $CVA6_RTL_ROOT/include/ariane_pkg.sv

# -----------------------------------------------------------------------------
# 2) Common support modules.
# -----------------------------------------------------------------------------
read_sv_if_exists $CVA6_REPO_ROOT/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv
read_sv_if_exists $CVA6_REPO_ROOT/vendor/pulp-platform/common_cells/src/lzc.sv
read_sv_if_exists $CVA6_REPO_ROOT/vendor/pulp-platform/common_cells/src/lfsr.sv
read_sv $CVA6_REPO_ROOT/common/local/util/sram.sv
read_sv $SRAM_WRAPPER
read_sv $SyncSpRamBenx64

# PMP dependencies used by cva6_ptw.
foreach f [list \
    $CVA6_RTL_ROOT/pmp/src/pmp_entry.sv \
    $CVA6_RTL_ROOT/pmp/src/pmp_data_if.sv \
    $CVA6_RTL_ROOT/pmp/src/pmp.sv \
] {
    read_sv_if_exists $f
} 

# -----------------------------------------------------------------------------
# 3) Formal package.
# -----------------------------------------------------------------------------
read_sv $WORK_ROOT/cva6_mmu_formal_pkg.sv

# -----------------------------------------------------------------------------
# 4) RTL dependencies and DUT.
#    cva6_tlb is usually taken from the CVA6 repository. The old MMU, PTW, and
#    shared TLB can be local copies in WORK_ROOT so we verify exactly the target
#    source version.
# -----------------------------------------------------------------------------
read_first_existing "cva6_tlb" [list \
    $CVA6_RTL_ROOT/mmu_sv39/cva6_tlb.sv \
    $CVA6_RTL_ROOT/mmu_sv32/cva6_tlb.sv \
    $CVA6_RTL_ROOT/mmu/cva6_tlb.sv \
    $CVA6_RTL_ROOT/cva6_tlb.sv \
    $WORK_ROOT/cva6_tlb.sv \
]

read_sv $WORK_ROOT/cva6_shared_tlb.sv
read_sv $WORK_ROOT/cva6_ptw.sv
read_sv $WORK_ROOT/cva6_mmu.sv

# -----------------------------------------------------------------------------
# 5) Formal top and scoreboard bind.
# -----------------------------------------------------------------------------
read_sv $WORK_ROOT/cva6_mmu_formal_top.sv
read_sv $WORK_ROOT/cva6_mmu_scoreboard_final.sv

set_elaborate_option -golden -call_threshold 100 -loop_iter_threshold 300 -nobreaking_unbounded_loops -x_optimism -verilog_parameter {} -verilog_library_search_order {} -no_verilog_library_resolution_ieee_compliance -no_verilog_config_support -vhdl_generic {} -vhdl_assertion_report_prefix {onespin} -black_box {{work.cva6_ptw}} -black_box_empty_modules -no_black_box_missing_modules -black_box_library {} -black_box_component {} -top {Verilog!work.cva6_mmu_formal_top}

elaborate -golden

# Set MV mode.
set_mode mv

# 7) Print available checks.
set all_checks [get_checks]
puts "Available checks:"
foreach c $all_checks {
    puts "  $c"
}

# 8) Run all checks one by one.
foreach c $all_checks {
    if {[string match "*i_cva6_mmu_scoreboard_bind/*" $c]} {
    puts "============================================================"
    puts "Running check: $c"
    puts "============================================================"
    check -verbose $c
    }

}
