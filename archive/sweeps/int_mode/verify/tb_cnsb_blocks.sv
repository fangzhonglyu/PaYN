// Self-checking bench for the generated CNSB edge blocks against the Python
// reference vectors written by gen_cnsb_rtl.py.  Run via run_cnsb_synth.sh.
`timescale 1ns/1ps
module tb_cnsb_blocks;
    string vdir;
    int errors = 0, checks = 0;

    // ---------------- feeders (combinational) ----------------
    logic int_en, mode4;
    logic [127:0] raw_a;
    logic [255:0] raw_w;
    logic [511:0] sc_mag, pm_exp, pm_r4, pm_hi, pm_lo;
    logic [63:0] sc_sign, ps_exp, ps_r4, ps_hi, ps_lo;
    logic clk = 0;

    cnsb_feed_r4_half u_r4 (.clk, .int_en, .int4(mode4), .raw(raw_a), .sc_mag, .sc_sign,
                            .port_mag(pm_r4), .port_sign(ps_r4));
    cnsb_feed_r16_half_hi u_hi (.clk, .int_en, .w4(mode4), .raw(raw_w), .sc_mag, .sc_sign,
                                .port_mag(pm_hi), .port_sign(ps_hi));
    cnsb_feed_r16_half_lo u_lo (.clk, .int_en, .w4(mode4), .raw(raw_w), .sc_mag, .sc_sign,
                                .port_mag(pm_lo), .port_sign(ps_lo));

    task automatic run_feed(string file, int which);
        int fd, r;
        logic [3:0] e, md;
        logic [255:0] rw;
        fd = $fopen(file, "r");
        if (fd == 0) $fatal(1, "cannot open %s", file);
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h\n", e, md, rw, sc_mag, sc_sign, pm_exp, ps_exp);
            if (r != 7) break;
            int_en = e[0]; mode4 = md[0];
            if (which == 0) raw_a = rw[127:0]; else raw_w = rw;
            #1;
            checks++;
            case (which)
                0: if (pm_r4 !== pm_exp || ps_r4 !== ps_exp) begin errors++; if (errors < 5) $display("r4 mismatch"); end
                1: if (pm_hi !== pm_exp || ps_hi !== ps_exp) begin errors++; if (errors < 5) $display("r16 hi mismatch"); end
                2: if (pm_lo !== pm_exp || ps_lo !== ps_exp) begin errors++; if (errors < 5) $display("r16 lo mismatch"); end
            endcase
        end
        $fclose(fd);
    endtask

    // ---------------- combiners (sequential) ----------------
    logic [1:0] cmode;
    logic cq1, cdrain;
    logic [191:0] cacc;
    logic [143:0] out1, out2;
    logic v1, v2;
    cnsb_combiner_row_1st u_c1 (.clk, .mode(cmode), .q1(cq1), .drain(cdrain), .acc(cacc),
                                .out(out1), .out_valid(v1));
    cnsb_combiner_row_2st u_c2 (.clk, .mode(cmode), .q1(cq1), .drain(cdrain), .acc(cacc),
                                .out(out2), .out_valid(v2));
    always #5 clk = ~clk;

    task automatic run_comb(string file);
        int fd, r, n;
        logic [3:0] m, q, d, vv;
        logic [191:0] a;
        logic [143:0] ov, mk;
        logic exp_v [$];
        logic [143:0] exp_o [$], exp_m [$];
        fd = $fopen(file, "r");
        if (fd == 0) $fatal(1, "cannot open %s", file);
        n = 0;
        @(negedge clk);
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h\n", m, q, d, a, vv, ov, mk);
            if (r != 7) break;
            cmode = m[1:0]; cq1 = q[0]; cdrain = d[0]; cacc = a;
            exp_v.push_back(vv[0]); exp_o.push_back(ov); exp_m.push_back(mk);
            @(posedge clk); #1;
            // 1-stage: result of this cycle's inputs
            checks++;
            if (v1 !== exp_v[n] || (exp_v[n] && ((out1 & exp_m[n]) !== (exp_o[n] & exp_m[n])))) begin
                errors++; if (errors < 5) $display("comb1 mismatch at %0d", n);
            end
            // 2-stage: result of the previous cycle's inputs
            if (n > 0) begin
                checks++;
                if (v2 !== exp_v[n-1] || (exp_v[n-1] && ((out2 & exp_m[n-1]) !== (exp_o[n-1] & exp_m[n-1])))) begin
                    errors++; if (errors < 5) $display("comb2 mismatch at %0d", n-1);
                end
            end
            n++;
            @(negedge clk);
        end
        $fclose(fd);
    endtask

    initial begin
        if (!$value$plusargs("VDIR=%s", vdir)) vdir = "vectors";
        run_feed({vdir, "/feed_r4.hex"}, 0);
        run_feed({vdir, "/feed_r16_hi.hex"}, 1);
        run_feed({vdir, "/feed_r16_lo.hex"}, 2);
        run_comb({vdir, "/combiner.hex"});
        if (errors == 0) $display("PASS: CNSB blocks match Python reference (%0d checks)", checks);
        else $display("FAIL: %0d mismatches of %0d checks", errors, checks);
        $finish;
    end
endmodule
