// fp32_sqrt : single-precision square root
//
// Pade method:  sqrt(x) = 2^( 0.5 * log2(x) ) built from fp32_log2 (Pade[3,3] log2) and fp32_exp2 (Pade[3,3] 2^x).
//
// Specials : sqrt(NaN)=NaN ; sqrt(x<0)=NaN ; sqrt(+0)=+0 ; sqrt(+Inf)=+Inf.
`timescale 1ns/1ps

module fp32_sqrt (
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_HALF = 32'h3F000000;   // 0.5
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    wire        s  = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    wire a_nan  = (E == 8'hFF) && (fa != 0);
    wire a_inf  = (E == 8'hFF) && (fa == 0);
    wire a_zero = (E == 8'h00);
    wire a_neg  = s && !a_zero;                  // sqrt(-x)=NaN, sqrt(-0)=-0

    // sqrt(x) = 2^(0.5 * log2(x))
    wire [31:0] l, h, mag;
    fp32_log2 U_LOG (.a(a),               .y(l));
    fp32_mul  U_H   (.a(l), .b(FP_HALF),  .y(h));
    fp32_exp2 U_EXP (.x(h),               .y(mag));

    reg [31:0] result;
    always @* begin
        if      (a_nan || a_neg) result = FP_QNAN;
        else if (a_zero)         result = {s, 31'h0};             // +0 / -0
        else if (a_inf)          result = {1'b0, 8'hFF, 23'h0};   // +Inf
        else                     result = mag;
    end
    assign y = result;
endmodule
