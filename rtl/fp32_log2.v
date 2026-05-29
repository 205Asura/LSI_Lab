// fp32_log2 : single-precision  log2(x)  for x > 0  
//
// Method:
//     x = 2^(E-127) * m ,   m = 1.f  in [1, 2)
//     log2(x) = (E - 127) + log2(m)
//
//   * (E - 127) is the exact integer part of the exponent, converted to FP32 by the i2f() function.
//   * log2(m) for m in [1,2) is a Pade[3,3] approximant about m = 1.5:
//         log2(m) ~ P(t)/Q(t) ,  t = m - 1.5
//     (max abs error on [1,2) ~ 9e-7, i.e. < 1 FP32 ulp).
//
// Specials :  log2(NaN)=NaN ; log2(x<0)=NaN ; log2(+0)=-Inf ; log2(+Inf)=+Inf.
`timescale 1ns/1ps

module fp32_log2 (
    input  wire [31:0] a,
    output wire [31:0] y
);
    // Pade[3,3] numerator / denominator (t = m - 1.5)
    localparam [31:0] P0 = 32'h3F15C01A, P1 = 32'h3FC5FC35,
                      P2 = 32'h3F4C1480, P3 = 32'h3DB23F44;
    localparam [31:0] Q0 = 32'h3F800000, Q1 = 32'h3F800000,
                      Q2 = 32'h3E888889, Q3 = 32'h3C72B9D6;
    localparam [31:0] FP_ONEHALF = 32'h3FC00000;   // 1.5
    localparam [31:0] FP_QNAN    = 32'h7FC00000;
    localparam [31:0] FP_NINF    = 32'hFF800000;
    localparam [31:0] FP_PINF    = 32'h7F800000;

    wire        s  = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    wire a_nan  = (E == 8'hFF) && (fa != 0);
    wire a_inf  = (E == 8'hFF) && (fa == 0);
    wire a_zero = (E == 8'h00);

    // m = 1.f  (force exponent to 127)
    wire [31:0] m = {1'b0, 8'd127, fa};
    // t = m - 1.5
    wire [31:0] t;
    fp32_add U_T (.a(m), .b(FP_ONEHALF), .sub(1'b1), .y(t));

    // P(t) via Horner : ((P3*t + P2)*t + P1)*t + P0
    wire [31:0] pm1, pa1, pm2, pa2, pm3, Pv;
    fp32_mul UP1 (.a(P3),  .b(t),  .y(pm1));
    fp32_add UP2 (.a(pm1), .b(P2), .sub(1'b0), .y(pa1));
    fp32_mul UP3 (.a(pa1), .b(t),  .y(pm2));
    fp32_add UP4 (.a(pm2), .b(P1), .sub(1'b0), .y(pa2));
    fp32_mul UP5 (.a(pa2), .b(t),  .y(pm3));
    fp32_add UP6 (.a(pm3), .b(P0), .sub(1'b0), .y(Pv));

    // Q(t) via Horner
    wire [31:0] qm1, qa1, qm2, qa2, qm3, Qv;
    fp32_mul UQ1 (.a(Q3),  .b(t),  .y(qm1));
    fp32_add UQ2 (.a(qm1), .b(Q2), .sub(1'b0), .y(qa1));
    fp32_mul UQ3 (.a(qa1), .b(t),  .y(qm2));
    fp32_add UQ4 (.a(qm2), .b(Q1), .sub(1'b0), .y(qa2));
    fp32_mul UQ5 (.a(qa2), .b(t),  .y(qm3));
    fp32_add UQ6 (.a(qm3), .b(Q0), .sub(1'b0), .y(Qv));

    // log2(m) = P/Q
    wire [31:0] log2m;
    fp32_div UD (.a(Pv), .b(Qv), .y(log2m));

    // integer part (E - 127) -> FP32
    wire signed [11:0] eint    = $signed({4'b0, E}) - 12'sd127;
    wire [31:0]        eint_fp = i2f(eint);

    // result = (E-127) + log2(m)
    wire [31:0] sum;
    fp32_add US (.a(eint_fp), .b(log2m), .sub(1'b0), .y(sum));

    reg [31:0] result;
    always @* begin
        if      (a_nan)          result = FP_QNAN;
        else if (s && !a_zero)   result = FP_QNAN;   // log2 of a negative
        else if (a_zero)         result = FP_NINF;   // log2(0) = -Inf
        else if (a_inf)          result = FP_PINF;   // log2(+Inf) = +Inf
        else                     result = sum;
    end
    assign y = result;

    // signed int (|n| < 2048) -> FP32 (exact)
    function [31:0] i2f;
        input signed [11:0] n;
        reg        sign;
        reg [11:0] mag;
        integer    i;
        reg [4:0]  p;
        reg        done;
        reg [34:0] shf;
        reg [7:0]  e;
        begin
            if (n == 0) i2f = 32'h00000000;
            else begin
                sign = n[11];
                mag  = sign ? (~n + 12'd1) : n;
                p = 0; done = 1'b0;
                for (i = 11; i >= 0; i = i - 1)
                    if (!done && mag[i]) begin p = i[4:0]; done = 1'b1; end
                e   = 8'd127 + {3'd0, p};
                shf = ({23'd0, mag} << (23 - p));   // MSB -> bit23
                i2f = {sign, e, shf[22:0]};
            end
        end
    endfunction
endmodule
