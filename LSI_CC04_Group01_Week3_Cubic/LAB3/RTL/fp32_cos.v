// fp32_cos : single-precision cosine (pipelined)
// Latency  : 40 cycles
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
//     where  u = arg^2.    Max abs error on [0, pi/2] ~ 3e-5.
//
// Caller contract :  |a| <= pi.  (No 2*pi reduction is done.)
`timescale 1ns/1ps

module fp32_cos (
    input  wire        clk,
    input  wire        en,
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

    // Initial Flags & Abs
    wire [31:0] abs_a = {1'b0, a[30:0]};
    wire        a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 23'h0);
    wire        a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 23'h0);
    wire abs_gt_pi2   = (abs_a > FP_PI_2);

    // PIPELINE DELAY REGISTERS
    // Flags need a full 40-cycle delay to meet the end of the pipeline
    reg [40:1] delay_a_nan;
    reg [40:1] delay_a_inf;
    reg [40:1] delay_abs_gt_pi2;

    // abs_a needs 4 cycles of delay to align with the output of U_PSU
    reg [31:0] delay_abs_a [1:4];

    // 'u' (arg^2) is generated at cycle 8 and is needed at cycles 16, 24, and 32. 
    // We need 24 cycles of delay after its generation.
    reg [31:0] delay_u [1:24];
    wire [31:0] u;

    integer i;
    always @(posedge clk) begin
        if (en) begin
            // Shift single-bit flags
            delay_a_nan      <= {delay_a_nan[39:1], a_nan};
            delay_a_inf      <= {delay_a_inf[39:1], a_inf};
            delay_abs_gt_pi2 <= {delay_abs_gt_pi2[39:1], abs_gt_pi2};

            // Shift abs_a
            delay_abs_a[1] <= abs_a;
            for (i = 2; i <= 4; i = i + 1) begin
                delay_abs_a[i] <= delay_abs_a[i-1];
            end

            // Shift u
            delay_u[1] <= u;
            for (i = 2; i <= 24; i = i + 1) begin
                delay_u[i] <= delay_u[i-1];
            end
        end
    end

    // Phase Subtraction
    wire [31:0] pi_minus_abs;
    fp32_add U_PSU (
        .clk(clk), .en(en), 
        .a(FP_PI), .b(abs_a), .sub(1'b1), .y(pi_minus_abs)
    );

    // Argument Selection
    wire [31:0] arg = delay_abs_gt_pi2[4] ? pi_minus_abs : delay_abs_a[4];

    // Argument Squared (u = arg * arg)
    
    fp32_mul U_USQ (
        .clk(clk), .en(en), 
        .a(arg), .b(arg), .y(u)
    );

    // Horner Term 4
    wire [31:0] mu4;
    fp32_mul U_M4 (
        .clk(clk), .en(en), 
        .a(u), .b(FP_1_40320), .y(mu4)
    );

    // Horner Term 3
    wire [31:0] t3;
    fp32_add U_T3 (
        .clk(clk), .en(en), 
        .a(FP_NEG_720), .b(mu4), .sub(1'b0), .y(t3)
    );

    // CYCLE 16 -> 20 : Horner Term 3 Mul
    // delay_u[8] holds 'u' from cycle 8
    wire [31:0] mu3;
    fp32_mul U_M3 (
        .clk(clk), .en(en), 
        .a(delay_u[8]), .b(t3), .y(mu3)
    );

    // CYCLE 20 -> 24 : Horner Term 2
    wire [31:0] t2;
    fp32_add U_T2 (
        .clk(clk), .en(en), 
        .a(FP_1_24), .b(mu3), .sub(1'b0), .y(t2)
    );

    // CYCLE 24 -> 28 : Horner Term 2 Mul
    // delay_u[16] holds 'u' from cycle 8
    wire [31:0] mu2;
    fp32_mul U_M2 (
        .clk(clk), .en(en), 
        .a(delay_u[16]), .b(t2), .y(mu2)
    );

    // CYCLE 28 -> 32 : Horner Term 1
    wire [31:0] t1;
    fp32_add U_T1 (
        .clk(clk), .en(en), 
        .a(FP_NEG_HALF), .b(mu2), .sub(1'b0), .y(t1)
    );

    // CYCLE 32 -> 36 : Horner Term 1 Mul
    // delay_u[24] holds 'u' from cycle 8
    wire [31:0] mu1;
    fp32_mul U_M1 (
        .clk(clk), .en(en), 
        .a(delay_u[24]), .b(t1), .y(mu1)
    );

    // CYCLE 36 -> 40 : Final Cosine Addition
    wire [31:0] cos_pos;
    fp32_add U_C (
        .clk(clk), .en(en), 
        .a(FP_ONE), .b(mu1), .sub(1'b0), .y(cos_pos)
    );

    // CYCLE 40 : Sign Reversion & Output Multiplexing
    // Retrieve the fully delayed exception/sign flags
    wire [31:0] cos_signed = delay_abs_gt_pi2[40] ? {~cos_pos[31], cos_pos[30:0]} : cos_pos;

    reg [31:0] result;
    always @* begin
        if (delay_a_nan[40] || delay_a_inf[40]) begin
            result = FP_QNAN;
        end else begin
            result = cos_signed;
        end
    end

    assign y = result;

endmodule