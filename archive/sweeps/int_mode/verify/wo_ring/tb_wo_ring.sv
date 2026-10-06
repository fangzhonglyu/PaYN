// RTL check of the WO-ring INT mode on the UNMODIFIED committed CSA RTL.
//
// Instantiates, for a PR x PC grid:
//   - one sc_pe_peripheral per PE row (A side) and one per PE column (W side),
//     with the shared random-value buses tied to the claimed INT presets;
//   - PR*PC InnerPESignedSegmentedCsaFlat PEs (K=8, M=16, N=8, OWIDTH=24,
//     LOW_W=9), wired as the clean grid wires them: A bits/signs and the A
//     sign-load wave hop east, W hops south, mac_en and shift_in are global.
// The proposed per-PE ring is built here, OUTSIDE each PE, exactly as the
// design states it (the PE's acc_chain[0] is its acc_in_west port):
//   ring_q[r][c] <= ring_q[r][c-1]   (ring_in[r] at the west edge, sync reset)
//   PE shift_in  = shift_in | ring_q[r][c]
//   acc_in_west  = ring_q ? {own acc_out_east[21:0], 2'b00} : west neighbour
// Stimulus (one line per clock edge) comes from gen_and_check.py; the east
// output of the last PE column is written out on every global drain edge,
// sampled before the edge as a collector would.
`timescale 1ns/1ps

`include "payn/pe_peripheral.sv"
`include "payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv"

`ifndef PR
`define PR 1
`endif
`ifndef PC
`define PC 1
`endif

module tb_wo_ring;
    localparam int PR = `PR, PC = `PC;
    localparam int K = 8, M = 16, NH = 8, NW = 8, WIDTH = 8, OWIDTH = 24, LOW_W = 9;
    localparam int AB = NH*K*WIDTH, AS = NH*K, BB = NH*K*M;

    // INT-mode presets on the shared random-value buses (lane m at [8m+:8]).
    localparam logic [7:0] PRESET_A [M] = '{70, 33, 70, 10, 131, 227, 62, 107,
                                           131, 35, 223, 203, 45, 0, 158, 133};
    localparam logic [7:0] PRESET_W [M] = '{86, 214, 211, 157, 137, 29, 123, 218,
                                           23, 200, 76, 227, 24, 69, 155, 223};
    logic [M*WIDTH-1:0] rv_a, rv_w;
    always_comb
        for (int m = 0; m < M; m++) begin
            rv_a[m*WIDTH +: WIDTH] = PRESET_A[m];
            rv_w[m*WIDTH +: WIDTH] = PRESET_W[m];
        end

    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    logic shift_in, mac_en, load_a, load_w, load_a_sign, load_w_sign;
    logic [PR-1:0] ring_in;
    logic [AB-1:0] a_code [PR];
    logic [AS-1:0] a_sgn  [PR];
    logic [AB-1:0] w_code [PC];
    logic [AS-1:0] w_sgn  [PC];

    // ---------------------------------------------------- edge peripherals --
    logic [BB-1:0] a_bits_e [PR];
    logic [AS-1:0] a_sgn_e  [PR];
    logic [BB-1:0] w_bits_e [PC];
    logic [AS-1:0] w_sgn_e  [PC];

    for (genvar r = 0; r < PR; r++) begin : g_pa
        logic [BB-1:0] unused_w; logic [AS-1:0] unused_ws;
        sc_pe_peripheral #(.K(K), .M(M), .N_H(NH), .N_W(NW), .WIDTH(WIDTH)) u_p (
            .clk, .reset, .load_a(load_a), .load_w(1'b0),
            .a_binary_in(a_code[r]), .a_signs_in(a_sgn[r]),
            .w_binary_in('0), .w_signs_in('0),
            .a_random_values(rv_a), .w_random_values(rv_w),
            .a_bits(a_bits_e[r]), .a_signs(a_sgn_e[r]),
            .w_bits(unused_w), .w_signs(unused_ws));
    end
    for (genvar c = 0; c < PC; c++) begin : g_pw
        logic [BB-1:0] unused_a; logic [AS-1:0] unused_as;
        sc_pe_peripheral #(.K(K), .M(M), .N_H(NH), .N_W(NW), .WIDTH(WIDTH)) u_p (
            .clk, .reset, .load_a(1'b0), .load_w(load_w),
            .a_binary_in('0), .a_signs_in('0),
            .w_binary_in(w_code[c]), .w_signs_in(w_sgn[c]),
            .a_random_values(rv_a), .w_random_values(rv_w),
            .a_bits(unused_a), .a_signs(unused_as),
            .w_bits(w_bits_e[c]), .w_signs(w_sgn_e[c]));
    end

    // ---------------------------------------------------------------- grid --
    logic [BB-1:0] a_link [PR][PC+1];
    logic [AS-1:0] as_link [PR][PC+1];
    logic          la_link [PR][PC+1];
    logic [BB-1:0] w_link [PC][PR+1];
    logic [AS-1:0] ws_link [PC][PR+1];
    logic          lw_link [PC][PR+1];
    logic [NH*OWIDTH-1:0] acc_w [PR][PC];
    logic [NH*OWIDTH-1:0] acc_e [PR][PC];
    logic ring_q [PR][PC];

    always_ff @(posedge clk)
        for (int r = 0; r < PR; r++)
            for (int c = 0; c < PC; c++)
                if (reset) ring_q[r][c] <= 1'b0;
                else ring_q[r][c] <= (c == 0) ? ring_in[r] : ring_q[r][c-1];

    for (genvar r = 0; r < PR; r++) begin : g_r
        assign a_link[r][0] = a_bits_e[r];
        assign as_link[r][0] = a_sgn_e[r];
        assign la_link[r][0] = load_a_sign;
    end
    for (genvar c = 0; c < PC; c++) begin : g_c
        assign w_link[c][0] = w_bits_e[c];
        assign ws_link[c][0] = w_sgn_e[c];
        assign lw_link[c][0] = load_w_sign;
    end

    for (genvar r = 0; r < PR; r++) begin : g_row
        for (genvar c = 0; c < PC; c++) begin : g_col
            logic [NH*OWIDTH-1:0] west;
            assign west = (c == 0) ? '0 : acc_e[r][(c == 0) ? 0 : c-1];
            for (genvar h = 0; h < NH; h++) begin : g_h
`ifdef LSB     // the user's shift-down variant: arithmetic >>2, low 2 bits emitted
                assign acc_w[r][c][h*OWIDTH +: OWIDTH] = ring_q[r][c]
                    ? {{2{acc_e[r][c][h*OWIDTH + OWIDTH-1]}}, acc_e[r][c][h*OWIDTH+2 +: OWIDTH-2]}
                    : west[h*OWIDTH +: OWIDTH];
`else
                assign acc_w[r][c][h*OWIDTH +: OWIDTH] = ring_q[r][c]
                    ? {acc_e[r][c][h*OWIDTH +: OWIDTH-2], 2'b00}
                    : west[h*OWIDTH +: OWIDTH];
`endif
            end
            InnerPESignedSegmentedCsaFlat #(
                .K(K), .M(M), .N_H(NH), .N_W(NW), .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_pe (
                .clk, .reset, .mac_en,
                .shift_in(shift_in | ring_q[r][c]),
                .a_bits_in(a_link[r][c]), .a_signs_in(as_link[r][c]),
                .w_bits_in(w_link[c][r]), .w_signs_in(ws_link[c][r]),
                .load_a_sign_in(la_link[r][c]), .load_w_sign_in(lw_link[c][r]),
                .a_bits_out(a_link[r][c+1]), .a_signs_out(as_link[r][c+1]),
                .w_bits_out(w_link[c][r+1]), .w_signs_out(ws_link[c][r+1]),
                .load_a_sign_out(la_link[r][c+1]), .load_w_sign_out(lw_link[c][r+1]),
                .acc_in_west(acc_w[r][c]), .acc_out_east(acc_e[r][c]));
        end
    end

    // ------------------------------------------------------------ stimulus --
    int fin, fout, n_edges, rc, nx;
    string stim, outf;
    logic [AB-1:0] tok;

    task automatic rd(output logic [AB-1:0] v);
        int k;
        k = $fscanf(fin, "%h", v);
        if (k != 1) $fatal(1, "stimulus read error");
    endtask

    initial begin
        if (!$value$plusargs("stim=%s", stim)) $fatal(1, "+stim= missing");
        if (!$value$plusargs("out=%s", outf)) $fatal(1, "+out= missing");
        fin = $fopen(stim, "r");
        fout = $fopen(outf, "w");
        if (fin == 0 || fout == 0) $fatal(1, "cannot open files");
        rc = $fscanf(fin, "%d", n_edges);
        shift_in = 0; mac_en = 1; ring_in = '0;
        load_a = 1; load_w = 1; load_a_sign = 1; load_w_sign = 1;
        for (int r = 0; r < PR; r++) begin a_code[r] = '0; a_sgn[r] = '0; end
        for (int c = 0; c < PC; c++) begin w_code[c] = '0; w_sgn[c] = '0; end
        reset = 1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;
        nx = 0;
        for (int e = 0; e < n_edges; e++) begin
            // inputs for edge e (applied between edges)
            rd(tok); shift_in = tok[0];
            rd(tok); ring_in = tok[PR-1:0];
            for (int r = 0; r < PR; r++) begin rd(tok); a_code[r] = tok; rd(tok); a_sgn[r] = tok[AS-1:0]; end
            for (int c = 0; c < PC; c++) begin rd(tok); w_code[c] = tok; rd(tok); w_sgn[c] = tok[AS-1:0]; end
            #1;
`ifdef LSB
            for (int r = 0; r < PR; r++)
                for (int c = 0; c < PC; c++)
                    if (ring_q[r][c])
                        for (int h = 0; h < NH; h++)
                            $fwrite(fout, "R %0d %0d %0d %0d %0d\n", e, r, c, h,
                                    acc_e[r][c][h*OWIDTH +: 2]);
`endif
            if (shift_in)
                for (int r = 0; r < PR; r++)
                    for (int h = 0; h < NH; h++) begin
                        if ($isunknown(acc_e[r][PC-1][h*OWIDTH +: OWIDTH])) nx++;
                        $fwrite(fout, "%0d %0d %0d %0d\n", e, r, h,
                                $signed(acc_e[r][PC-1][h*OWIDTH +: OWIDTH]));
                    end
            @(posedge clk);
            @(negedge clk);
        end
        $fwrite(fout, "END %0d\n", nx);
        $fclose(fout);
        $display("TB_DONE edges=%0d x_samples=%0d", n_edges, nx);
        $finish;
    end
endmodule
