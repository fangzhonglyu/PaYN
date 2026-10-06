`timescale 1ns/1ps

// Dumb vector player for the independent BP PE-grid harness
// (sweeps/int_mode/bp/verify_grid/).  All scheduling lives in gen_vg_stim.py;
// this bench only applies one stimulus line per clock edge and records what
// the grid does.  It shares nothing with designs/payn/tb/test_pe_grid_bp.sv.
//
// stim.txt: first line N, then one line per edge e = 0..N-1:
//   ctl ring lda ldw a_signs w_signs a_bits w_bits acc_in_west sample   (hex)
//   ctl = {shift_in, mac_en, int_mode, reset}
// Line e is applied at the negedge before posedge e.  Just before applying it
// the bench records the pre-edge state used at edge e (both are registered
// only, so this is exact):
//   "T e <ring_q of every PE, bit r*P_C + c>"     every edge
//   "D e <acc_out_east, all PE rows>"              on sample edges
//
// Bench-side fault forcing (proves the checker sees one-edge ring-wave skew
// errors at a single PE link): +FKIND=1 (late) / 2 (early) +FR= +FC= +FFROM=
// +FTO=: inside edges FFROM..FTO, PE (FR,FC)'s ring_in is the west link
// delayed one edge (late) or PE (FR,FC-1)'s own ring_in (early, FC >= 1).
// +FKIND=3: every PE row's west ring input loses its int_mode gate.
//
// Shape: +define+VG_PR=, VG_PC=, VG_LOW_W=.  RTL needs DesignWare sim models.

// Lap-length port (sweeps/int_mode/bp/sr/verify_grid/): the DUT grid is chosen by
// +define+VG_DUT_SR (InnerPESignedSegmentedCsaBpSrGrid, LAP_G from +define+PAYN_LAP_G),
// +define+VG_DUT_IPD (InnerPESignedSegmentedCsaBpIpdGrid) or neither (the BP grid, as
// the original sweeps/int_mode/bp/verify_grid/tb_vg_player.sv).
`ifdef VG_DUT_SR
`include "payn/variants/signed_segmented_csa_bp_sr/inner_pe_grid_signed_segmented_csa_bp_sr.sv"
`define VG_GRID_MODULE InnerPESignedSegmentedCsaBpSrGrid
`elsif VG_DUT_IPD
`include "payn/variants/signed_segmented_csa_bp_ipd/inner_pe_grid_signed_segmented_csa_bp_ipd.sv"
`define VG_GRID_MODULE InnerPESignedSegmentedCsaBpIpdGrid
`else
`include "payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv"
`define VG_GRID_MODULE InnerPESignedSegmentedCsaBpGrid
`endif

`ifndef VG_PR
`define VG_PR 2
`endif
`ifndef VG_PC
`define VG_PC 2
`endif
`ifndef VG_LOW_W
`define VG_LOW_W 9
`endif

module tb_vg_player;
    localparam int P_R = `VG_PR;
    localparam int P_C = `VG_PC;
    localparam int K = 8, M = 16, N_H = 8, N_W = 8, OWIDTH = 24;
    localparam int LOW_W = `VG_LOW_W;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;

    logic clk = 1'b1;
    always #1.25 clk = ~clk;

    logic reset = 1'b1, mac_en = 1'b0, shift_in = 1'b0, int_mode = 1'b0;
    logic [P_R-1:0] ring_in = '0;
    logic [P_R*AB-1:0] a_bits_in = '0;
    logic [P_R*AS-1:0] a_signs_in = '0;
    logic [P_C*WB-1:0] w_bits_in = '0;
    logic [P_C*WS-1:0] w_signs_in = '0;
    logic [P_R-1:0] load_a_sign_in = '0;
    logic [P_C-1:0] load_w_sign_in = '0;
    logic [P_R*AB-1:0] a_bits_out;
    logic [P_R*AS-1:0] a_signs_out;
    logic [P_C*WB-1:0] w_bits_out;
    logic [P_C*WS-1:0] w_signs_out;
    logic [P_R-1:0] load_a_sign_out;
    logic [P_C-1:0] load_w_sign_out;
    logic [P_R-1:0] ring_out;
    logic [P_R*AW-1:0] acc_in_west = '0;
    logic [P_R*AW-1:0] acc_out_east;

    `VG_GRID_MODULE #(
        .P_ROWS(P_R), .P_COLS(P_C), .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

    int cur_e = -1;
    bit cfg_done = 1'b0;
    int f_kind = 0, f_r = -1, f_c = -1, f_from = 0, f_to = -1;

    logic [P_R*P_C-1:0] ringmask;
    for (genvar r = 0; r < P_R; r++) begin : g_r
        for (genvar c = 0; c < P_C; c++) begin : g_c
            assign ringmask[r*P_C + c] = dut.g_pe_row[r].g_pe_col[c].u_pe.ring_q;

            logic src, early_src, dly, win;
            if (c == 0) begin : g_west
                assign src = ring_in[r] & int_mode;
                assign early_src = 1'b0;
            end else begin : g_inner
                assign src = dut.g_pe_row[r].g_pe_col[c-1].u_pe.ring_q;
                if (c == 1) begin : g_e1
                    assign early_src = ring_in[r] & int_mode;
                end else begin : g_e2
                    assign early_src = dut.g_pe_row[r].g_pe_col[c-2].u_pe.ring_q;
                end
            end
            always @(posedge clk) dly <= src;
            assign win = (cur_e >= f_from) && (cur_e <= f_to);
            initial begin
                wait (cfg_done);
                if (f_kind == 3 && c == 0) begin
                    // negative control: remove the int_mode gate on the west ring input
                    $display("[VG] forcing PE (%0d,0) ring_in = ring_in[%0d] (int_mode gate removed)", r, r);
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_in[r];
                end else if ((f_kind == 1 || f_kind == 2) && f_r == r && f_c == c) begin
                    $display("[VG] forcing PE (%0d,%0d) ring_in %s on edges %0d..%0d",
                             r, c, f_kind == 1 ? "late" : "early", f_from, f_to);
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in =
                        win ? ((f_kind == 1) ? dly : early_src) : src;
                end
            end
        end
    end

    initial begin
        string stim_path, trace_path;
        int fd, tf, code, n_edges;
        logic [3:0] ctl;
        logic [P_R-1:0] ring_v, lda_v;
        logic [P_C-1:0] ldw_v;
        logic [P_R*AS-1:0] asg_v;
        logic [P_C*WS-1:0] wsg_v;
        logic [P_R*AB-1:0] ab_v;
        logic [P_C*WB-1:0] wb_v;
        logic [P_R*AW-1:0] acc_v;
        logic [3:0] smp;

        if (!$value$plusargs("STIM=%s", stim_path)) stim_path = "stim.txt";
        if (!$value$plusargs("TRACE=%s", trace_path)) trace_path = "trace.txt";
        void'($value$plusargs("FKIND=%d", f_kind));
        void'($value$plusargs("FR=%d", f_r));
        void'($value$plusargs("FC=%d", f_c));
        void'($value$plusargs("FFROM=%d", f_from));
        void'($value$plusargs("FTO=%d", f_to));
        if (f_kind == 2 && f_c < 1) $fatal(1, "early link fault needs FC >= 1");

        fd = $fopen(stim_path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", stim_path);
        tf = $fopen(trace_path, "w");
        if (tf == 0) $fatal(1, "cannot open %s", trace_path);
        code = $fscanf(fd, "%d\n", n_edges);
        if (code != 1) $fatal(1, "bad stim header");
        $fwrite(tf, "VGCFG %0d %0d %0d %0d\n", P_R, P_C, LOW_W, n_edges);
        cfg_done = 1'b1;

        for (int e = 0; e < n_edges; e++) begin
            @(negedge clk);
            $fwrite(tf, "T %0d %h\n", e, ringmask);
            code = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h\n",
                           ctl, ring_v, lda_v, ldw_v, asg_v, wsg_v, ab_v, wb_v, acc_v, smp);
            if (code != 10) $fatal(1, "stim line %0d: %0d fields", e, code);
            if (smp[0]) $fwrite(tf, "D %0d %h\n", e, acc_out_east);
            reset = ctl[0];
            int_mode = ctl[1];
            mac_en = ctl[2];
            shift_in = ctl[3];
            ring_in = ring_v;
            load_a_sign_in = lda_v;
            load_w_sign_in = ldw_v;
            a_signs_in = asg_v;
            w_signs_in = wsg_v;
            a_bits_in = ab_v;
            w_bits_in = wb_v;
            acc_in_west = acc_v;
            cur_e = e;
        end
        @(negedge clk);
        $fwrite(tf, "T %0d %h\n", n_edges, ringmask);
        $fwrite(tf, "END\n");
        $fclose(tf);
        $fclose(fd);
        $display("VG_DONE edges=%0d P=%0dx%0d LOW_W=%0d", n_edges, P_R, P_C, LOW_W);
        $finish;
    end
endmodule
