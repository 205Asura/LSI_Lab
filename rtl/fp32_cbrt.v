// fp32_cbrt : single-precision cube root
//
// Pade method:  cbrt(x) = sign(x) * 2^( (1/3)*log2(|x|) ) built from fp32_log2 (Pade[3,3] log2) and fp32_exp2 (Pade[3,3] 2^x)
//   note: cbrt is odd, so the sign is stripped before log2 and reapplied at the end
//
// Specials : cbrt(NaN)=NaN ; cbrt(+/-0)=+/-0 ; cbrt(+/-Inf)=+/-Inf.
`timescale 1ns/1ps

module fp32_cbrt (
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_THIRD = 32'h3EAAAAAB;   // 1/3
    localparam [31:0] FP_QNAN  = 32'h7FC00000;

    wire        s  = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    wire a_nan  = (E == 8'hFF) && (fa != 0);
    wire a_inf  = (E == 8'hFF) && (fa == 0);
    wire a_zero = (E == 8'h00);

    wire [31:0] absa = {1'b0, a[30:0]};          // |a|

    // |cbrt(x)| = 2^((1/3) * log2(|x|))
    wire [31:0] l, h, mag;
    fp32_log2 U_LOG (.a(absa),             .y(l));
    fp32_mul  U_H   (.a(l), .b(FP_THIRD),  .y(h));
    fp32_exp2 U_EXP (.x(h),                .y(mag));

    reg [31:0] result;
    always @* begin
        if      (a_nan)  result = FP_QNAN;
        else if (a_zero) result = {s, 31'h0};                 // +/-0
        else if (a_inf)  result = {s, 8'hFF, 23'h0};          // +/-Inf
        else             result = {s, mag[30:0]};             // reapply sign
    end
    assign y = result;
endmodule
