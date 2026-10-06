`timescale 1ns/1ps
// Probe: does payn_array_signed_segmented_csa_bp elaborate and start at its own
// default parameters (PAYN_K=6, PAYN_NH=9, PAYN_NW=9 unless defined), the shape
// the SC benches use when no SC_* shape defines are given?
`include "payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv"
module TbBpDefaultParams;
    payn_array_signed_segmented_csa_bp dut (
        .clk(1'b0), .reset(1'b1), .rng_en(1'b0), .load_a(1'b0), .load_w(1'b0),
        .load_a_sign(1'b0), .load_w_sign(1'b0), .mac_en(1'b0), .shift_in(1'b0),
        .a_binary_in('0), .a_signs_in('0), .w_binary_in('0), .w_signs_in('0),
        .acc_in_west('0), .acc_out_east(),
        .int_mode(1'b0), .int_prec(1'b0), .ring_in(1'b0), .a_raw_in('0), .w_raw_in('0),
        .int_out(), .int_out_valid());
    initial begin #1; $display("DEFAULT_PARAMS_OK N_H=%0d N_W=%0d K=%0d", dut.N_H, dut.N_W, dut.K); $finish; end
endmodule
