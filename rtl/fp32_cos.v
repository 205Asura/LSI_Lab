// fp32_cos : single-precision cosine (combinational)
//
// Algorithm
//   * abs_a = |a|.   (cos is even.)
//   * If abs_a > pi/2 :  arg = pi - abs_a, sign-flip the result.
//     Else            :  arg = abs_a.
//     Now  arg in [0, pi/2].
//   * 8-th-order Taylor (truncated) :
//
//       cos(arg) = 1 + u*(-1/2 + u*(1/24 + u*(-1/720 + u*(1/40320))))
//
//     where  u = arg^2.   Max abs error on [0, pi/2] ~ 3e-5.
//
// Caller contract :  |a| <= pi.  (No 2*pi reduction is done.)
//   Within the cubic solver this is always satisfied because the cos arg is  theta/3 + k*(2*pi/3)  with theta/3 in [0, pi/3]
`timescale 1ns/1ps

module fp32_cos (
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_QNAN     = 32'h7FC00000;
    localparam [31:0] FP_PI       = 32'h40490FDB;
    localparam [31:0] FP_PI_2     = 32'h3FC90FDB;
    localparam [31:0] FP_ONE      = 32'h3F800000;
    localparam [31:0] FP_NEG_HALF = 32'hBF000000;   // -1/2
    localparam [31:0] FP_1_24     = 32'h3D2AAAAB;   //  1/24
    localparam [31:0] FP_NEG_720  = 32'hBAB60B61;   // -1/720
    localparam [31:0] FP_1_40320  = 32'h37D00D01;   //  1/40320

    // |a|
    wire [31:0] abs_a = {1'b0, a[30:0]};
    wire        a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 23'h0);
    wire        a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 23'h0);

    // Compare abs_a > pi/2.  Both are positive normals -> integer compare works.
    wire abs_gt_pi2 = (abs_a > FP_PI_2);

    // pi - abs_a
    wire [31:0] pi_minus_abs;
    fp32_add U_PSU (.a(FP_PI), .b(abs_a), .sub(1'b1), .y(pi_minus_abs));

    wire [31:0] arg = abs_gt_pi2 ? pi_minus_abs : abs_a;

    // u = arg * arg
    wire [31:0] u;
    fp32_mul U_USQ (.a(arg), .b(arg), .y(u));

    // Horner evaluation of the Taylor polynomial
    wire [31:0] mu4, t3, mu3, t2, mu2, t1, mu1, cos_pos;

    fp32_mul U_M4 (.a(u),         .b(FP_1_40320), .y(mu4));
    fp32_add U_T3 (.a(FP_NEG_720),.b(mu4),        .sub(1'b0), .y(t3));

    fp32_mul U_M3 (.a(u),    .b(t3),       .y(mu3));
    fp32_add U_T2 (.a(FP_1_24),.b(mu3),    .sub(1'b0), .y(t2));

    fp32_mul U_M2 (.a(u),    .b(t2),       .y(mu2));
    fp32_add U_T1 (.a(FP_NEG_HALF),.b(mu2),.sub(1'b0), .y(t1));

    fp32_mul U_M1 (.a(u),    .b(t1),       .y(mu1));
    fp32_add U_C  (.a(FP_ONE),.b(mu1),     .sub(1'b0), .y(cos_pos));

    // Restore sign for the [pi/2, pi] half by flipping the sign bit.
    wire [31:0] cos_signed = abs_gt_pi2 ? {~cos_pos[31], cos_pos[30:0]}
                                        :  cos_pos;

    reg [31:0] result;
    always @* begin
        if (a_nan || a_inf) result = FP_QNAN;
        else                result = cos_signed;
    end

    assign y = result;
endmodule
