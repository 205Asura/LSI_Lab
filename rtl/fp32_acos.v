// fp32_acos : single-precision arccos (pipelined)
// Latency   : 68 cycles
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
    input  wire        clk,
    input  wire        en,
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

    // Initial Extraction & Clamping
    wire        sa = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    
    wire [31:0] abs_a = {1'b0, a[30:0]};
    wire        a_nan = (E == 8'hFF) && (fa != 23'h0);
    wire        a_inf = (E == 8'hFF) && (fa == 23'h0);

    //  [0, 1]
    wire abs_gt_one = (abs_a > FP_ONE);
    wire [31:0] x_c = abs_gt_one ? FP_ONE : abs_a;

    // PIPELINE DELAY REGISTERS
    reg [2:0]  delay_flags [1:68]; // {a_nan, a_inf, sa}
    
    // 'u' is generated at T=4, needed at T=12, T=20, T=28 for Horner
    reg [31:0] delay_u [1:24];
    wire [31:0] u;

    // 'h' is generated at T=36, needed at T=60 to multiply with 'v'
    reg [31:0] delay_h [1:24];
    wire [31:0] mu4, t3, mu3, t2, mu2, t1, mu1, h;

    // 'result_pos' is generated at T=64, needed at T=68 for the positive output bypass
    reg [31:0] delay_result_pos [1:4];
    wire [31:0] result_pos;


    integer i;
    always @(posedge clk) begin
        if (en) begin
            // Shift exception flags through the entire 68-cycle pipeline
            delay_flags[1] <= {a_nan, a_inf, sa};
            for (i=2; i<=68; i=i+1) delay_flags[i] <= delay_flags[i-1];

            // Delay 'u' for Horner polynomial multiplications
            delay_u[1] <= u;
            for (i=2; i<=24; i=i+1) delay_u[i] <= delay_u[i-1];

            // Delay 'h' to wait for the Square Root pipeline to finish
            delay_h[1] <= h;
            for (i=2; i<=24; i=i+1) delay_h[i] <= delay_h[i-1];

            // Delay 'result_pos' to align with the 'pi_minus' subtraction
            delay_result_pos[1] <= result_pos;
            for (i=2; i<=4; i=i+1) delay_result_pos[i] <= delay_result_pos[i-1];
        end
    end

    // Calculate u = 1 - x_c
    fp32_add U_U  (.clk(clk), .en(en), .a(FP_ONE), .b(x_c), .sub(1'b1), .y(u));

    // Square Root (CYCLE 4 -> 60)
    // 2u
    wire [31:0] two_u;
    fp32_mul U_2U (.clk(clk), .en(en), .a(u), .b(FP_TWO), .y(two_u));

    // v = sqrt(2u)
    wire [31:0] v;
    fp32_sqrt U_S (.clk(clk), .en(en), .a(two_u), .y(v));

    // Horner Polynomial
    // Horner :   h = 1 + u*(C1 + u*(C2 + u*(C3 + u*C4)))

    fp32_mul U_M4 (.clk(clk), .en(en), .a(u),         .b(FP_C4),  .y(mu4));
    
    fp32_add U_T3 (.clk(clk), .en(en), .a(FP_C3),     .b(mu4),    .sub(1'b0), .y(t3));

    fp32_mul U_M3 (.clk(clk), .en(en), .a(delay_u[8]),.b(t3),     .y(mu3));
    
    fp32_add U_T2 (.clk(clk), .en(en), .a(FP_C2),     .b(mu3),    .sub(1'b0), .y(t2));

    fp32_mul U_M2 (.clk(clk), .en(en), .a(delay_u[16]),.b(t2),    .y(mu2));
    
    fp32_add U_T1 (.clk(clk), .en(en), .a(FP_C1),     .b(mu2),    .sub(1'b0), .y(t1));

    fp32_mul U_M1 (.clk(clk), .en(en), .a(delay_u[24]),.b(t1),    .y(mu1));
    
    // h is buffered until T=60 in delay_h
    fp32_add U_H  (.clk(clk), .en(en), .a(FP_ONE),    .b(mu1),    .sub(1'b0), .y(h));

    // Combine Paths (result_pos = v * h)
    fp32_mul U_RP (.clk(clk), .en(en), .a(v), .b(delay_h[24]), .y(result_pos));

    // Negative Input Adjustment
    // For negative inputs : acos(x) = pi - acos(|x|).
    wire [31:0] pi_minus;
    fp32_add U_PMR (.clk(clk), .en(en), .a(FP_PI), .b(result_pos), .sub(1'b1), .y(pi_minus));

    // Final Output Muxing
    wire f_nan = delay_flags[68][2];
    wire f_inf = delay_flags[68][1];
    wire f_sa  = delay_flags[68][0];

    reg [31:0] result;
    always @* begin
        if (f_nan)        result = FP_QNAN;
        else if (f_inf)   result = FP_QNAN;            // acos(+/-inf) = NaN
        else if (f_sa)    result = pi_minus;           // Negative input
        else              result = delay_result_pos[4]; // Positive input
    end

    assign y = result;

endmodule