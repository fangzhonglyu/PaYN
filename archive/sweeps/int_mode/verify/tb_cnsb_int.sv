`timescale 1ns/1ps

// RTL check of the CNSB / spatial-Booth INT mode on the UNMODIFIED CSA RTL.
//
// Stimulus comes from sweeps/int_mode/verify/cnsb_rtl_cases.py (one line per
// clock: repeat count, control bits, per-edge 8-bit codes and digit signs).
// The INT-mode Sobol preset does not exist in RTL yet, so it is emulated:
//   CNSB_USE_TOP (1x1): the real payn_array_signed_segmented_csa top, with its
//     two random_values buses forced to the preset constants (rng_en=0).
//   otherwise: a PR x PC grid built here from the real sc_pe_peripheral (one
//     per west/north edge, routed scramble salts 0/128) and the real
//     InnerPESignedSegmentedCsaFlat PEs, wired through the PE re-export rails
//     (A east, W south, load wave forwarded) and the cross-PE drain chain,
//     with the shared random_values buses driven to the preset constants.
// Each cycle with shift_in=1, the grid-east acc_out_east of every PE row is
// sampled before the clock edge and written to the output file.
//
// Plusargs: +stim=<file> +out=<file>.  Defines: CNSB_PR, CNSB_PC, CNSB_USE_TOP.
// Stimulus header line: <A preset bus hex (128 b)> <W preset bus hex (128 b)>.

`include "payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv"

`ifndef CNSB_PR
`define CNSB_PR 1
`endif
`ifndef CNSB_PC
`define CNSB_PC 1
`endif

module tb_cnsb_int;
    localparam int K = 8, M = 16, N_H = 8, N_W = 8, WIDTH = 8;
    localparam int OWIDTH = 24, LOW_W = 9;
    localparam int PR = `CNSB_PR, PC = `CNSB_PC;
    localparam int ABW = N_H*K*WIDTH, ASW = N_H*K;
    localparam int WBW = N_W*K*WIDTH, WSW = N_W*K;

    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    logic mac_en = 0, shift_in = 0, ld = 0, lds = 0;
    logic [ABW-1:0] a_bin [PR];
    logic [ASW-1:0] a_sg  [PR];
    logic [WBW-1:0] w_bin [PC];
    logic [WSW-1:0] w_sg  [PC];
    logic [M*WIDTH-1:0] a_preset, w_preset;
    logic signed [OWIDTH-1:0] east [PR][N_H];

`ifdef CNSB_USE_TOP
    initial assert (PR == 1 && PC == 1) else $fatal(1, "top mode is 1x1");
    logic [N_H*OWIDTH-1:0] acc_out_east_flat;
    payn_array_signed_segmented_csa #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (
        .clk, .reset, .rng_en(1'b0),
        .load_a(ld), .load_w(ld), .load_a_sign(lds), .load_w_sign(lds),
        .mac_en, .shift_in,
        .a_binary_in(a_bin[0]), .a_signs_in(a_sg[0]),
        .w_binary_in(w_bin[0]), .w_signs_in(w_sg[0]),
        .acc_in_west('0), .acc_out_east(acc_out_east_flat)
    );
    // Emulated INT preset: the shared Sobol buses parked at constants.
    initial begin
        wait (a_preset !== 'x);
        force dut.a_random_values = a_preset;
        force dut.w_random_values = w_preset;
    end
    for (genvar h = 0; h < N_H; h++) begin : g_east
        assign east[0][h] = $signed(acc_out_east_flat[h*OWIDTH +: OWIDTH]);
    end
`else
    logic [N_H*K*M-1:0] a_bits_e  [PR];
    logic [N_H*K-1:0]   a_signs_e [PR];
    logic [N_W*K*M-1:0] w_bits_e  [PC];
    logic [N_W*K-1:0]   w_signs_e [PC];

    for (genvar r = 0; r < PR; r++) begin : g_pa
        sc_pe_peripheral #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
                           .SCRAMBLE_ENABLE(1'b1), .A_SCRAMBLE_SALT(0),
                           .W_SCRAMBLE_SALT(1 << (WIDTH - 1))) u_p (
            .clk, .reset, .load_a(ld), .load_w(1'b0),
            .a_binary_in(a_bin[r]), .a_signs_in(a_sg[r]),
            .w_binary_in('0), .w_signs_in('0),
            .a_random_values(a_preset), .w_random_values(w_preset),
            .a_bits(a_bits_e[r]), .a_signs(a_signs_e[r]), .w_bits(), .w_signs()
        );
    end
    for (genvar c = 0; c < PC; c++) begin : g_pw
        sc_pe_peripheral #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
                           .SCRAMBLE_ENABLE(1'b1), .A_SCRAMBLE_SALT(0),
                           .W_SCRAMBLE_SALT(1 << (WIDTH - 1))) u_p (
            .clk, .reset, .load_a(1'b0), .load_w(ld),
            .a_binary_in('0), .a_signs_in('0),
            .w_binary_in(w_bin[c]), .w_signs_in(w_sg[c]),
            .a_random_values(a_preset), .w_random_values(w_preset),
            .a_bits(), .a_signs(), .w_bits(w_bits_e[c]), .w_signs(w_signs_e[c])
        );
    end

    logic [N_H*K*M-1:0] a_bits_o  [PR][PC];
    logic [N_H*K-1:0]   a_signs_o [PR][PC];
    logic [N_W*K*M-1:0] w_bits_o  [PR][PC];
    logic [N_W*K-1:0]   w_signs_o [PR][PC];
    logic               lda_o [PR][PC], ldw_o [PR][PC];
    logic [N_H*OWIDTH-1:0] acc_o [PR][PC];

    logic [N_H*K*M-1:0] a_bits_i  [PR][PC];
    logic [N_H*K-1:0]   a_signs_i [PR][PC];
    logic [N_W*K*M-1:0] w_bits_i  [PR][PC];
    logic [N_W*K-1:0]   w_signs_i [PR][PC];
    logic               lda_i [PR][PC], ldw_i [PR][PC];
    logic [N_H*OWIDTH-1:0] acc_i [PR][PC];

    for (genvar r = 0; r < PR; r++) begin : g_r
        for (genvar c = 0; c < PC; c++) begin : g_c
            if (c == 0) begin : g_west_edge
                assign a_bits_i[r][c] = a_bits_e[r];
                assign a_signs_i[r][c] = a_signs_e[r];
                assign lda_i[r][c] = lds;
                assign acc_i[r][c] = '0;
            end else begin : g_west_pe
                assign a_bits_i[r][c] = a_bits_o[r][c-1];
                assign a_signs_i[r][c] = a_signs_o[r][c-1];
                assign lda_i[r][c] = lda_o[r][c-1];
                assign acc_i[r][c] = acc_o[r][c-1];
            end
            if (r == 0) begin : g_north_edge
                assign w_bits_i[r][c] = w_bits_e[c];
                assign w_signs_i[r][c] = w_signs_e[c];
                assign ldw_i[r][c] = lds;
            end else begin : g_north_pe
                assign w_bits_i[r][c] = w_bits_o[r-1][c];
                assign w_signs_i[r][c] = w_signs_o[r-1][c];
                assign ldw_i[r][c] = ldw_o[r-1][c];
            end
            InnerPESignedSegmentedCsaFlat #(
                .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_pe (
                .clk, .reset, .mac_en, .shift_in,
                .a_bits_in(a_bits_i[r][c]), .a_signs_in(a_signs_i[r][c]),
                .w_bits_in(w_bits_i[r][c]), .w_signs_in(w_signs_i[r][c]),
                .load_a_sign_in(lda_i[r][c]), .load_w_sign_in(ldw_i[r][c]),
                .a_bits_out(a_bits_o[r][c]), .a_signs_out(a_signs_o[r][c]),
                .w_bits_out(w_bits_o[r][c]), .w_signs_out(w_signs_o[r][c]),
                .load_a_sign_out(lda_o[r][c]), .load_w_sign_out(ldw_o[r][c]),
                .acc_in_west(acc_i[r][c]),
                .acc_out_east(acc_o[r][c])
            );
        end
        for (genvar h = 0; h < N_H; h++) begin : g_east
            assign east[r][h] = $signed(acc_o[r][PC-1][h*OWIDTH +: OWIDTH]);
        end
    end
`endif

    // ------------------------------------------------------------ driver --
    integer fd, fo, rc, rep, line_no, nlines;
    logic [ABW-1:0] tmp_a;
    logic [ASW-1:0] tmp_as;
    logic [WBW-1:0] tmp_w;
    logic [WSW-1:0] tmp_ws;
    integer i_mac, i_shift, i_ld, i_lds;
    string stim_path, out_path;
    bit done = 0;
    longint unsigned cyc = 0;
    integer xs = 0;

    task automatic read_line(output bit eof);
        rc = $fscanf(fd, "%d %d %d %d %d", rep, i_mac, i_shift, i_ld, i_lds);
        if (rc != 5) begin eof = 1; return; end
        for (int r = 0; r < PR; r++) begin
            rc = $fscanf(fd, "%h %h", tmp_a, tmp_as);
            a_bin[r] = tmp_a; a_sg[r] = tmp_as;
        end
        for (int c = 0; c < PC; c++) begin
            rc = $fscanf(fd, "%h %h", tmp_w, tmp_ws);
            w_bin[c] = tmp_w; w_sg[c] = tmp_ws;
        end
        mac_en = i_mac[0]; shift_in = i_shift[0]; ld = i_ld[0]; lds = i_lds[0];
        eof = 0;
    endtask

    initial begin
        bit eof;
        if (!$value$plusargs("stim=%s", stim_path)) $fatal(1, "+stim= missing");
        if (!$value$plusargs("out=%s", out_path)) $fatal(1, "+out= missing");
        fd = $fopen(stim_path, "r");
        fo = $fopen(out_path, "w");
        if (fd == 0 || fo == 0) $fatal(1, "cannot open stim/out");
        rc = $fscanf(fd, "%h %h", a_preset, w_preset);
        for (int r = 0; r < PR; r++) begin a_bin[r] = '0; a_sg[r] = '0; end
        for (int c = 0; c < PC; c++) begin w_bin[c] = '0; w_sg[c] = '0; end
        ld = 1; lds = 1; mac_en = 0; shift_in = 0;
        reset = 1;
        repeat (4) @(posedge clk);
        #1 reset = 0;
        line_no = 0;
        read_line(eof);
        while (!eof) begin
            for (int t = 0; t < rep; t++) begin
                @(negedge clk);
                if (shift_in) begin
                    for (int r = 0; r < PR; r++)
                        for (int h = 0; h < N_H; h++) begin
                            if ($isunknown(east[r][h])) xs++;
                            $fwrite(fo, "D %0d %0d %0d %0d\n", cyc, r, h, east[r][h]);
                        end
                end
                @(posedge clk);
                cyc++;
                #1;
            end
            line_no++;
            read_line(eof);
        end
        $fwrite(fo, "END cycles=%0d xs=%0d\n", cyc, xs);
        $fclose(fo);
        $display("CNSB_TB done: %0d lines, %0d cycles, %0d X samples", line_no, cyc, xs);
        $finish;
    end
endmodule
