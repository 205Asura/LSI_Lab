// fp32_acos : single-precision arccos (combinational)
//
// Algorithm
//
//   For |x| <= 1, write  acos(x) = sqrt(2*(1 - |x|)) * h(1 - |x|), then for negative x use  acos(x) = pi - acos(|x|).
//
//   h(u) = 1 + u/12 + 3*u^2/160 + 5*u^3/896 + 35*u^4/18432
//
//   The sqrt singularity at x = +/-1 is captured exactly by the leading sqrt(2u) factor, so the polynomial converges well over the whole [-1, 1] domain.  Worst-case error is ~ 0.1% (near x = 0); that is the weakest point and is acceptable for the cubic solver.
//
// Domain :  inputs slightly outside [-1, 1] are clamped to the nearest boundary (typical case from cubic-solver round-off when the trig branch is on the edge of D = 0).
`timescale 1ns/1ps

module fp32_acos (
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_ONE  = 32'h3F800000;
    localparam [31:0] FP_TWO  = 32'h40000000;
    localparam [31:0] FP_PI   = 32'h40490FDB;
    localparam [31:0] FP_QNAN = 32'h7FC00000;
    localparam [31:0] FP_C1   = 32'h3DAAAAAB;   //  1/12
    localparam [31:0] FP_C2   = 32'h3C99999A;   //  3/160
    localparam [31:0] FP_C3   = 32'h3BB6DB6E;   //  5/896
    localparam [31:0] FP_C4   = 32'h3AF8E38E;   //  35/18432

    wire        sa = a[31];
    wire [31:0] abs_a = {1'b0, a[30:0]};
    wire        a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 23'h0);
    wire        a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 23'h0);

    //  [0, 1]
    wire abs_gt_one = (abs_a > FP_ONE);
    wire [31:0] x_c = abs_gt_one ? FP_ONE : abs_a;

    // u = 1 - x_c   (in [0, 1])
    wire [31:0] u;
    fp32_add U_U  (.a(FP_ONE), .b(x_c), .sub(1'b1), .y(u));

    // 2u
    wire [31:0] two_u;
    fp32_mul U_2U (.a(u), .b(FP_TWO), .y(two_u));

    // v = sqrt(2u)
    wire [31:0] v;
    fp32_sqrt U_S (.a(two_u), .y(v));

    // Horner :   h = 1 + u*(C1 + u*(C2 + u*(C3 + u*C4)))
    wire [31:0] mu4, t3, mu3, t2, mu2, t1, mu1, h;

    fp32_mul U_M4 (.a(u),     .b(FP_C4),  .y(mu4));
    fp32_add U_T3 (.a(FP_C3), .b(mu4),    .sub(1'b0), .y(t3));

    fp32_mul U_M3 (.a(u),     .b(t3),     .y(mu3));
    fp32_add U_T2 (.a(FP_C2), .b(mu3),    .sub(1'b0), .y(t2));

    fp32_mul U_M2 (.a(u),     .b(t2),     .y(mu2));
    fp32_add U_T1 (.a(FP_C1), .b(mu2),    .sub(1'b0), .y(t1));

    fp32_mul U_M1 (.a(u),     .b(t1),     .y(mu1));
    fp32_add U_H  (.a(FP_ONE),.b(mu1),    .sub(1'b0), .y(h));

    // result_pos = v * h
    wire [31:0] result_pos;
    fp32_mul U_RP (.a(v), .b(h), .y(result_pos));

    // For negative inputs : acos(x) = pi - acos(|x|).
    wire [31:0] pi_minus;
    fp32_add U_PMR (.a(FP_PI), .b(result_pos), .sub(1'b1), .y(pi_minus));

    reg [31:0] result;
    always @* begin
        if (a_nan)        result = FP_QNAN;
        else if (a_inf)   result = FP_QNAN;            // acos(+/-inf) = NaN
        else if (sa)      result = pi_minus;
        else              result = result_pos;
    end

    assign y = result;
endmodule
