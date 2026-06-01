/*
Algorithm: Newton-Raphson Iterative Reciprocal Approximation. Rather than relying on a slow, bit-by-bit digit recurrence loop, this architecture eliminates division by solving for the exact reciprocal of the denominator (1/b) and performing a terminal multiplication (a×(1/b)).

- Computes an initial coarse reciprocal guess (y0​) using a hardware seed pipeline implementing the linear equation: y0​=1.5−0.5bnorm​.
- Unrolls 3 consecutive iteration stages of the Newton-Raphson error-correction equation: yn+1​=yn​×(2−b×yn​). Because each iteration quadratically doubles the number of accurate precision bits, 3 passes comfortably exceed the 24-bit single-precision mantissa threshold.
- Feeds the finalized reciprocal into an instance of fp32_mul to calculate the final quotient.
*/


`timescale 1ns/1ps

module fp32_div (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);
    localparam [31:0] FP_HALF = 32'h3F000000;   // 0.5
    localparam [31:0] FP_ONE5 = 32'h3FC00000;   // 1.5
    localparam [31:0] FP_TWO  = 32'h40000000;   // 2.0
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    // Decode Inputs
    wire        sb = b[31];
    wire [7:0]  eb = b[30:23];
    wire [22:0] fb = b[22:0];
    wire b_nan  = (eb == 8'hFF) && (fb != 23'h0);
    wire b_inf  = (eb == 8'hFF) && (fb == 23'h0);
    wire b_zero = (eb == 8'h00);

    wire [7:0]  ea = a[30:23];
    wire [22:0] fa_bits = a[22:0];
    wire a_nan  = (ea == 8'hFF) && (fa_bits != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa_bits == 23'h0);
    wire a_zero = (ea == 8'h00);

    wire [31:0] b_norm = {1'b0, 8'd127, fb};

    // Global context shift registers
    reg [31:0] a_pipe      [0:43]; 
    reg [31:0] b_norm_pipe [0:31]; 
    reg [7:0]  eb_pipe     [0:43];
    reg        sb_pipe     [0:43];
    reg [5:0]  flags_pipe  [0:43]; // {a_nan, a_inf, a_zero, b_nan, b_inf, b_zero}

    integer i;
    always @(posedge clk) begin
        if (en) begin
            a_pipe[0]      <= a;
            b_norm_pipe[0] <= b_norm;
            eb_pipe[0]     <= eb;
            sb_pipe[0]     <= sb;
            flags_pipe[0]  <= {a_nan, a_inf, a_zero, b_nan, b_inf, b_zero};
            
            for (i = 1; i < 44; i = i + 1) begin
                a_pipe[i]     <= a_pipe[i-1];
                eb_pipe[i]    <= eb_pipe[i-1];
                sb_pipe[i]    <= sb_pipe[i-1];
                flags_pipe[i] <= flags_pipe[i-1];
                if (i < 32) b_norm_pipe[i] <= b_norm_pipe[i-1];
            end
        end
    end

    // Seed Generation
    wire [31:0] half_b, y0;
    fp32_mul           U_HB   (.clk(clk), .en(en), .a(b_norm), .b(FP_HALF), .y(half_b)); // T=4
    fp32_add U_SEED (.clk(clk), .en(en), .a(FP_ONE5), .b(half_b), .sub(1'b1), .y(y0)); // T=8

    // y_n Shift register
    reg [31:0] y0_pipe [0:7];
    reg [31:0] y1_pipe [0:7];
    reg [31:0] y2_pipe [0:7];

    wire [31:0] by0, t0, y1;
    wire [31:0] by1, t1, y2;

    
    always @(posedge clk) begin
        if (en) begin
            y0_pipe[0] <= y0; y1_pipe[0] <= y1; y2_pipe[0] <= y2; 
            for (i = 1; i < 8; i = i + 1) begin
                y0_pipe[i] <= y0_pipe[i-1];
                y1_pipe[i] <= y1_pipe[i-1];
                y2_pipe[i] <= y2_pipe[i-1];
            end
        end
    end

    // 3 Newton-Raphson Iterations
    
    // Iteration 1 (Starts T=8, Ends T=20)
    fp32_mul           U_BY0 (.clk(clk), .en(en), .a(b_norm_pipe[7]), .b(y0),         .y(by0)); // T=12
    fp32_add U_T0  (.clk(clk), .en(en), .a(FP_TWO),         .b(by0),        .sub(1'b1), .y(t0));  // T=16
    fp32_mul           U_Y1  (.clk(clk), .en(en), .a(y0_pipe[7]),     .b(t0),         .y(y1));  // T=20

    // Iteration 2 (Starts T=20, Ends T=32)
    fp32_mul           U_BY1 (.clk(clk), .en(en), .a(b_norm_pipe[19]), .b(y1),        .y(by1)); // T=24
    fp32_add U_T1  (.clk(clk), .en(en), .a(FP_TWO),          .b(by1),       .sub(1'b1), .y(t1));  // T=28
    fp32_mul           U_Y2  (.clk(clk), .en(en), .a(y1_pipe[7]),      .b(t1),        .y(y2));  // T=32

    // Iteration 3 (Starts T=32, Ends T=44)
    // For FP32, Iteration 3 guarantees >24 bits of precision. 
    wire [31:0] by2, t2, y3;
    fp32_mul           U_BY2 (.clk(clk), .en(en), .a(b_norm_pipe[31]), .b(y2),        .y(by2)); // T=36
    fp32_add U_T2  (.clk(clk), .en(en), .a(FP_TWO),          .b(by2),       .sub(1'b1), .y(t2));  // T=40
    fp32_mul           U_Y3  (.clk(clk), .en(en), .a(y2_pipe[7]),      .b(t2),        .y(y3));  // T=44

    // Exponent Adjust
    wire [7:0]  ey3  = y3[30:23];
    wire [9:0]  ne_t = {2'b00, ey3} + 10'd127 - {2'b00, eb_pipe[43]};

    // Unpack context flags delayed by 44 cycles
    wire f_a_nan  = flags_pipe[43][5];
    wire f_a_inf  = flags_pipe[43][4];
    wire f_a_zero = flags_pipe[43][3];
    wire f_b_nan  = flags_pipe[43][2];
    wire f_b_inf  = flags_pipe[43][1];
    wire f_b_zero = flags_pipe[43][0];
    wire f_sb     = sb_pipe[43];

    reg [31:0] recip_b;
    always @* begin
        if (f_b_nan) begin
            recip_b = FP_QNAN;
        end else if (f_b_zero) begin
            recip_b = {f_sb, 8'hFF, 23'h0};                  // 1/0 = signed Inf
        end else if (f_b_inf) begin
            recip_b = {f_sb, 31'h0};                         // 1/Inf = signed 0
        end else if (ne_t[9]) begin
            recip_b = {f_sb, 31'h0};                         // exp underflow
        end else if (ne_t >= 10'd255) begin
            recip_b = {f_sb, 8'hFF, 23'h0};                  // exp overflow
        end else if (ne_t == 10'h0) begin
            recip_b = {f_sb, 31'h0};
        end else begin
            recip_b = {f_sb, ne_t[7:0], y3[22:0]}; // Use y3 directly
        end
    end

    // Final Multiply (T=44 to T=48)
    wire [31:0] mul_y;
    fp32_mul U_FIN (.clk(clk), .en(en), .a(a_pipe[43]), .b(recip_b), .y(mul_y)); // Valid at T=48

    // Delay the flags for 4 more cycles to match U_FIN
    reg [5:0] fin_flags_pipe [0:3];
    always @(posedge clk) begin
        if (en) begin
            fin_flags_pipe[0] <= flags_pipe[43];
            for (i = 1; i < 4; i = i + 1) fin_flags_pipe[i] <= fin_flags_pipe[i-1];
        end
    end

    // Special Muxing
    wire final_a_nan  = fin_flags_pipe[3][5];
    wire final_a_inf  = fin_flags_pipe[3][4];
    wire final_a_zero = fin_flags_pipe[3][3];
    wire final_b_nan  = fin_flags_pipe[3][2];
    wire final_b_inf  = fin_flags_pipe[3][1];
    wire final_b_zero = fin_flags_pipe[3][0];

    reg [31:0] result_w;
    always @* begin
        if (final_a_nan || final_b_nan) begin
            result_w = FP_QNAN;
        end else if (final_a_zero && final_b_zero) begin
            result_w = FP_QNAN;
        end else if (final_a_inf && final_b_inf) begin
            result_w = FP_QNAN;
        end else begin
            result_w = mul_y;
        end
    end

    // Final Output Register (Valid at T=49)
    reg [31:0] y_reg;
    always @(posedge clk) begin
        if (en) begin
            y_reg <= result_w;
        end
    end

    assign y = y_reg;

endmodule