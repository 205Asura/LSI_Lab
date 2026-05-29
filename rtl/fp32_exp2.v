// fp32_exp2 : single-precision  2^x  
//
// Method :
//     x = n + f ,   n = floor(x) (integer) ,  f in [0, 1)
//     2^x = 2^n * 2^f
//
//   * n = floor(x) via the local f2i_floor() ; f = x - n via one FP subtract.
//   * 2^f for f in [0,1) is a Pade[3,3] approximant about x = 0.5 :
//         2^f ~ P(t)/Q(t) ,  t = f - 0.5      (P(0) = sqrt(2)) (max abs error on [0,1) ~ 1e-8).
//   * The 2^n scaling is an exponent add (n added to 2^f's exponent).
//
// Specials :  2^NaN=NaN ; 2^(+Inf)=+Inf ; 2^(-Inf)=+0 ; over/underflow ->
//             +Inf / +0 (flush).  |x| >= 1024 is clamped before floor().
`timescale 1ns/1ps

module fp32_exp2 (
    input  wire [31:0] x,
    output wire [31:0] y
);
    // Pade[3,3] for 2^(0.5+t) (t = f - 0.5)
    localparam [31:0] P0 = 32'h3FB504F3, P1 = 32'h3EFAF233,
                      P2 = 32'h3D8B2770, P3 = 32'h3B809B0C;
    localparam [31:0] Q0 = 32'h3F800000, Q1 = 32'hBEB17218,
                      Q2 = 32'h3D44CB26, Q3 = 32'hBB35E039;
    localparam [31:0] FP_HALF = 32'h3F000000;   // 0.5
    localparam [31:0] FP_ONE  = 32'h3F800000;   // 1.0
    localparam [31:0] FP_PINF = 32'h7F800000;
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    wire        s  = x[31];
    wire [7:0]  E  = x[30:23];
    wire [22:0] fx = x[22:0];
    wire x_nan  = (E == 8'hFF) && (fx != 0);
    wire x_inf  = (E == 8'hFF) && (fx == 0);
    wire x_zero = (E == 8'h00);
    wire signed [9:0] xe = $signed({2'b0, E}) - 10'sd127;            // unbiased exp
    wire x_big = (!x_zero) && (!x_nan) && (!x_inf) && (xe >= 10'sd10); // |x| >= 1024

    // n = floor(x) ; f = x - n  in [0,1)
    wire signed [11:0] n    = f2i_floor(x);
    wire [31:0]        n_fp = i2f(n);
    wire [31:0] f;
    fp32_add UF (.a(x), .b(n_fp), .sub(1'b1), .y(f));
    // t = f - 0.5
    wire [31:0] t;
    fp32_add UT (.a(f), .b(FP_HALF), .sub(1'b1), .y(t));

    // P(t), Q(t) via Horner
    wire [31:0] pm1, pa1, pm2, pa2, pm3, Pv;
    fp32_mul UP1 (.a(P3),  .b(t),  .y(pm1));
    fp32_add UP2 (.a(pm1), .b(P2), .sub(1'b0), .y(pa1));
    fp32_mul UP3 (.a(pa1), .b(t),  .y(pm2));
    fp32_add UP4 (.a(pm2), .b(P1), .sub(1'b0), .y(pa2));
    fp32_mul UP5 (.a(pa2), .b(t),  .y(pm3));
    fp32_add UP6 (.a(pm3), .b(P0), .sub(1'b0), .y(Pv));

    wire [31:0] qm1, qa1, qm2, qa2, qm3, Qv;
    fp32_mul UQ1 (.a(Q3),  .b(t),  .y(qm1));
    fp32_add UQ2 (.a(qm1), .b(Q2), .sub(1'b0), .y(qa1));
    fp32_mul UQ3 (.a(qa1), .b(t),  .y(qm2));
    fp32_add UQ4 (.a(qm2), .b(Q1), .sub(1'b0), .y(qa2));
    fp32_mul UQ5 (.a(qa2), .b(t),  .y(qm3));
    fp32_add UQ6 (.a(qm3), .b(Q0), .sub(1'b0), .y(Qv));

    // 2^f = P/Q  (in [1,2), exponent field ~127)
    wire [31:0] e2f;
    fp32_div UD (.a(Pv), .b(Qv), .y(e2f));

    // scale by 2^n : add n to 2^f's exponent field
    wire [7:0]  ef = e2f[30:23];
    wire signed [11:0] ne = $signed({4'b0, ef}) + n;

    reg [31:0] result;
    always @* begin
        if      (x_nan)        result = FP_QNAN;
        else if (x_inf)        result = s ? 32'h00000000 : FP_PINF; // 2^-inf=0,2^+inf=inf
        else if (x_zero)       result = FP_ONE;                     // 2^0 = 1
        else if (x_big)        result = s ? 32'h00000000 : FP_PINF;
        else if (ne <= 12'sd0)   result = 32'h00000000;             // underflow -> 0
        else if (ne >= 12'sd255) result = FP_PINF;                  // overflow  -> Inf
        else                     result = {1'b0, ne[7:0], e2f[22:0]};
    end
    assign y = result;

    // signed int (|n| < 2048) -> FP32 (exact) 
    function [31:0] i2f;
        input signed [11:0] n;
        reg sign; reg [11:0] mag; integer i; reg [4:0] p; reg done; reg [34:0] shf; reg [7:0] e;
        begin
            if (n == 0) i2f = 32'h00000000;
            else begin
                sign = n[11];
                mag  = sign ? (~n + 12'd1) : n;
                p = 0; done = 1'b0;
                for (i = 11; i >= 0; i = i - 1)
                    if (!done && mag[i]) begin p = i[4:0]; done = 1'b1; end
                e   = 8'd127 + {3'd0, p};
                shf = ({23'd0, mag} << (23 - p));
                i2f = {sign, e, shf[22:0]};
            end
        end
    endfunction

    // FP32 -> floor() as signed 12-bit integer (valid |x| < 1024) 
    function signed [11:0] f2i_floor;
        input [31:0] v;
        reg s2; reg [7:0] Ev; reg [22:0] fv; reg signed [9:0] ev;
        reg [23:0] sig; reg [4:0] rsh; reg [23:0] ipart; reg [23:0] fmask; reg hf;
        begin
            s2 = v[31]; Ev = v[30:23]; fv = v[22:0];
            if (Ev == 8'd0) f2i_floor = 12'sd0;                 // |v| ~ 0
            else begin
                ev  = $signed({2'b0, Ev}) - 10'sd127;
                sig = {1'b1, fv};
                if (ev < 0)
                    f2i_floor = s2 ? -12'sd1 : 12'sd0;          // |v| < 1
                else begin
                    rsh    = (5'd23 - ev[4:0]);
                    ipart  = sig >> rsh;
                    fmask  = (ev >= 10'sd23) ? 24'd0 : ((24'd1 << rsh) - 24'd1);
                    hf     = |(sig & fmask);
                    if (!s2) f2i_floor =  $signed(ipart[11:0]);
                    else     f2i_floor = -($signed(ipart[11:0]) + (hf ? 12'sd1 : 12'sd0));
                end
            end
        end
    endfunction
endmodule
