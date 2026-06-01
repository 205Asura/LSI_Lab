/*
fp32_exp2 (Floating-Point Exponential)

Algorithm: Computes 2x utilizing an optimized Pade[3,3] Rational Function Approximation.

- Extracts the input scalar and separates it into an isolated integer part (n=⌊x⌋) and a positive fractional remainder (f=x−n).
- Center-shifts the fraction into a localized domain (t=f−0.5) and computes the corresponding numerator P(t) and denominator Q(t) polynomial approximations via serialized Horner's Scheme multiplier/adder chains.
- Pipelines the polynomials into the fp32_div module to determine the fractional value P(t)/Q(t).
- Restores the integer value n by directly adding it to the exponent field of the divided mantissa product, executing a zero-overhead scale multiplication by 2^n.
*/

`timescale 1ns/1ps

module fp32_exp2 (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] x,
    output wire [31:0] y
);
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
    wire signed [9:0] xe = $signed({2'b0, E}) - 10'sd127;           
    wire x_big = (!x_zero) && (!x_nan) && (!x_inf) && (xe >= 10'sd10); 

    wire signed [11:0] n    = f2i_floor(x);
    wire [31:0]        n_fp = i2f(n);

    // 81-cycle bypass register to match T=81 Division output
    reg [16:0] ctx_pipe [0:80];
    integer i;
    always @(posedge clk) begin
        if (en) begin
            ctx_pipe[0] <= {s, x_nan, x_inf, x_zero, x_big, n};
            for (i=1; i<81; i=i+1) begin
                ctx_pipe[i] <= ctx_pipe[i-1];
            end
        end
    end

    // Initial Math
    wire [31:0] f;
    fp32_add UF (.clk(clk), .en(en), .a(x), .b(n_fp), .sub(1'b1), .y(f)); 
    
    wire [31:0] t;
    fp32_add UT (.clk(clk), .en(en), .a(f), .b(FP_HALF), .sub(1'b1), .y(t)); 

    reg [31:0] t_pipe [0:15];
    integer j;
    always @(posedge clk) begin
        if (en) begin
            t_pipe[0] <= t;
            for (j=1; j<16; j=j+1) t_pipe[j] <= t_pipe[j-1];
        end
    end

    // Horner Evaluation
    wire [31:0] pm1, qm1;
    fp32_mul UP1 (.clk(clk), .en(en), .a(P3), .b(t), .y(pm1));
    fp32_mul UQ1 (.clk(clk), .en(en), .a(Q3), .b(t), .y(qm1));

    wire [31:0] pa1, qa1;
    fp32_add UP2 (.clk(clk), .en(en), .a(pm1), .b(P2), .sub(1'b0), .y(pa1));
    fp32_add UQ2 (.clk(clk), .en(en), .a(qm1), .b(Q2), .sub(1'b0), .y(qa1));

    wire [31:0] pm2, qm2;
    fp32_mul UP3 (.clk(clk), .en(en), .a(pa1), .b(t_pipe[7]), .y(pm2));
    fp32_mul UQ3 (.clk(clk), .en(en), .a(qa1), .b(t_pipe[7]), .y(qm2));

    wire [31:0] pa2, qa2;
    fp32_add UP4 (.clk(clk), .en(en), .a(pm2), .b(P1), .sub(1'b0), .y(pa2));
    fp32_add UQ4 (.clk(clk), .en(en), .a(qm2), .b(Q1), .sub(1'b0), .y(qa2));

    wire [31:0] pm3, qm3;
    fp32_mul UP5 (.clk(clk), .en(en), .a(pa2), .b(t_pipe[15]), .y(pm3));
    fp32_mul UQ5 (.clk(clk), .en(en), .a(qa2), .b(t_pipe[15]), .y(qm3));

    wire [31:0] Pv, Qv;
    fp32_add UP6 (.clk(clk), .en(en), .a(pm3), .b(P0), .sub(1'b0), .y(Pv));
    fp32_add UQ6 (.clk(clk), .en(en), .a(qm3), .b(Q0), .sub(1'b0), .y(Qv));

    // Division (T=81)
    wire [31:0] e2f;
    fp32_div UD (.clk(clk), .en(en), .a(Pv), .b(Qv), .y(e2f)); 

    // Final Scaling
    wire [16:0] final_ctx = ctx_pipe[80];
    wire fs       = final_ctx[16];
    wire fx_nan   = final_ctx[15];
    wire fx_inf   = final_ctx[14];
    wire fx_zero  = final_ctx[13];
    wire fx_big   = final_ctx[12];
    wire signed [11:0] fn = final_ctx[11:0];

    wire [7:0]  ef = e2f[30:23];
    wire signed [11:0] ne = $signed({4'b0, ef}) + fn;

    reg [31:0] result;
    always @* begin
        if      (fx_nan)         result = FP_QNAN;
        else if (fx_inf)         result = fs ? 32'h00000000 : FP_PINF; 
        else if (fx_zero)        result = FP_ONE;                     
        else if (fx_big)         result = fs ? 32'h00000000 : FP_PINF;
        else if (ne <= 12'sd0)   result = 32'h00000000;             
        else if (ne >= 12'sd255) result = FP_PINF;                  
        else                     result = {1'b0, ne[7:0], e2f[22:0]};
    end

    // Result Register
    reg [31:0] y_reg;
    always @(posedge clk) begin
        if (en) y_reg <= result;
    end
    assign y = y_reg;

    
    function [31:0] i2f;
        input signed [11:0] n_in;
        reg sign; reg [11:0] mag; integer k; reg [4:0] p; reg k_done; reg [34:0] shf; reg [7:0] e_val;
        begin
            if (n_in == 0) i2f = 32'h00000000;
            else begin
                sign = n_in[11]; mag  = sign ? (~n_in + 12'd1) : n_in; p = 0; k_done = 1'b0;
                for (k = 11; k >= 0; k = k - 1) begin
                    if (!k_done && mag[k]) begin p = k[4:0]; k_done = 1'b1; end
                end
                e_val = 8'd127 + {3'd0, p}; shf   = ({23'd0, mag} << (23 - p));
                i2f   = {sign, e_val, shf[22:0]};
            end
        end
    endfunction

    function signed [11:0] f2i_floor;
        input [31:0] v;
        reg s2; reg [7:0] Ev; reg [22:0] fv; reg signed [9:0] ev;
        reg [23:0] sig; reg [4:0] rsh; reg [23:0] ipart; reg [23:0] fmask; reg hf;
        begin
            s2 = v[31]; Ev = v[30:23]; fv = v[22:0];
            if (Ev == 8'd0) f2i_floor = 12'sd0;                 
            else begin
                ev  = $signed({2'b0, Ev}) - 10'sd127;
                sig = {1'b1, fv};
                if (ev < 0) f2i_floor = s2 ? -12'sd1 : 12'sd0;          
                else begin
                    rsh    = (5'd23 - ev[4:0]); ipart  = sig >> rsh;
                    fmask  = (ev >= 10'sd23) ? 24'd0 : ((24'd1 << rsh) - 24'd1); hf = |(sig & fmask);
                    if (!s2) f2i_floor =  $signed(ipart[11:0]);
                    else     f2i_floor = -($signed(ipart[11:0]) + (hf ? 12'sd1 : 12'sd0));
                end
            end
        end
    endfunction
endmodule