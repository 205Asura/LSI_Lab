// fp32_div :  single-precision divider (combinational)
//
// Algorithm : Newton-Raphson reciprocal + final multiply.
//
//   1. Capture b's sign and exponent ; build  b_norm = 1.fb  in [1, 2).
//   2. Linear seed   y0 = 1.5 - 0.5 * b_norm                  (~12% error).
//   3. Iterate four times : y_{n+1} = y_n * (2 - b_norm * y_n)
//      Each NR step squares the error, so 4 iterations from a 12% seed give
//      well under 1 ulp of FP32.
//   4. Adjust exponent : 1/b = 2^(127-eb) * 1/b_norm = 2^(127-eb) * y4.
//   5. Result  = a * (1/b).
//
// Specials
//   * b == NaN -> NaN ; b == 0 -> signed Inf ; b == Inf -> signed 0.
//   * Subnormal operands are flushed to zero through the sub-modules.
`timescale 1ns/1ps

module fp32_div (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);
    // Constants
    localparam [31:0] FP_HALF = 32'h3F000000;   // 0.5
    localparam [31:0] FP_ONE5 = 32'h3FC00000;   // 1.5
    localparam [31:0] FP_TWO  = 32'h40000000;   // 2.0
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    // Decode b
    wire        sb = b[31];
    wire [7:0]  eb = b[30:23];
    wire [22:0] fb = b[22:0];
    wire b_nan  = (eb == 8'hFF) && (fb != 23'h0);
    wire b_inf  = (eb == 8'hFF) && (fb == 23'h0);
    wire b_zero = (eb == 8'h00);

    // Decode a (just for special-case handling at the end)
    wire        sa = a[31];
    wire [7:0]  ea = a[30:23];
    wire [22:0] fa_bits = a[22:0];
    wire a_nan  = (ea == 8'hFF) && (fa_bits != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa_bits == 23'h0);
    wire a_zero = (ea == 8'h00);

    // Normalise b to [1, 2) by forcing exponent = 127.
    wire [31:0] b_norm = {1'b0, 8'd127, fb};

    // ---- Seed : y0 = 1.5 - 0.5 * b_norm  -----------------------------------
    wire [31:0] half_b;
    fp32_mul U_HB   (.a(b_norm), .b(FP_HALF), .y(half_b));
    wire [31:0] y0;
    fp32_add U_SEED (.a(FP_ONE5), .b(half_b), .sub(1'b1), .y(y0));

    // ---- 4 Newton-Raphson iterations  --------------------------------------
    wire [31:0] by0, t0, y1;
    fp32_mul U_BY0 (.a(b_norm), .b(y0),   .y(by0));
    fp32_add U_T0  (.a(FP_TWO), .b(by0),  .sub(1'b1), .y(t0));
    fp32_mul U_Y1  (.a(y0),     .b(t0),   .y(y1));

    wire [31:0] by1, t1, y2;
    fp32_mul U_BY1 (.a(b_norm), .b(y1),   .y(by1));
    fp32_add U_T1  (.a(FP_TWO), .b(by1),  .sub(1'b1), .y(t1));
    fp32_mul U_Y2  (.a(y1),     .b(t1),   .y(y2));

    wire [31:0] by2, t2, y3;
    fp32_mul U_BY2 (.a(b_norm), .b(y2),   .y(by2));
    fp32_add U_T2  (.a(FP_TWO), .b(by2),  .sub(1'b1), .y(t2));
    fp32_mul U_Y3  (.a(y2),     .b(t2),   .y(y3));

    wire [31:0] by3, t3, y4;
    fp32_mul U_BY3 (.a(b_norm), .b(y3),   .y(by3));
    fp32_add U_T3  (.a(FP_TWO), .b(by3),  .sub(1'b1), .y(t3));
    fp32_mul U_Y4  (.a(y3),     .b(t3),   .y(y4));

    // ---- Build  recip_b = 2^(127 - eb) * y4  -------------------------------
    // y4 has biased exponent ey4 (~127 since y4 in (0.5,1]).  We want
    // exp_recip = ey4 + 127 - eb  (biased).
    wire [7:0]  ey4   = y4[30:23];
    wire [9:0]  ne_t  = {2'b00, ey4} + 10'd127 - {2'b00, eb};

    reg [31:0] recip_b;
    always @* begin
        if (b_nan) begin
            recip_b = FP_QNAN;
        end else if (b_zero) begin
            recip_b = {sb, 8'hFF, 23'h0};                    // 1/0 = signed Inf
        end else if (b_inf) begin
            recip_b = {sb, 31'h0};                           // 1/Inf = signed 0
        end else if (ne_t[9]) begin
            recip_b = {sb, 31'h0};                           // exp underflow
        end else if (ne_t >= 10'd255) begin
            recip_b = {sb, 8'hFF, 23'h0};                    // exp overflow
        end else if (ne_t == 10'h0) begin
            recip_b = {sb, 31'h0};
        end else begin
            recip_b = {sb, ne_t[7:0], y4[22:0]};
        end
    end

    // ---- Final multiply  ---------------------------------------------------
    wire [31:0] mul_y;
    fp32_mul U_FIN (.a(a), .b(recip_b), .y(mul_y));

    // Top-level special handling : 0/0, Inf/Inf are NaN; nothing else surprising.
    reg [31:0] result;
    always @* begin
        if (a_nan || b_nan) begin
            result = FP_QNAN;
        end else if (a_zero && b_zero) begin
            result = FP_QNAN;
        end else if (a_inf && b_inf) begin
            result = FP_QNAN;
        end else begin
            result = mul_y;
        end
    end

    assign y = result;
endmodule
