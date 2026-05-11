// fp32_add : single-precision adder/subtractor (combinational)
//
//   y = a + b  when sub == 1'b0
//   y = a - b  when sub == 1'b1
//
// Behaviour: 
//   * Subnormal operands are flushed to zero before processing.
//   * NaN propagates : (NaN op x) = NaN.
//   * Inf  - Inf     = NaN ; Inf + Inf (same sign) = Inf.
//   * Round-to-zero (truncation) on the result mantissa.  The cubic solver tolerates the resulting ~1 ulp bias on each elementary op.

`timescale 1ns/1ps

module fp32_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sub,
    output wire [31:0] y
);
    // Flip the sign of b for subtraction
    wire [31:0] b_eff = sub ? {~b[31], b[30:0]} : b;

    // Unpack
    wire        sa = a[31];
    wire [7:0]  ea = a[30:23];
    wire [22:0] fa = a[22:0];
    wire        sb = b_eff[31];
    wire [7:0]  eb = b_eff[30:23];
    wire [22:0] fb = b_eff[22:0];

    // Special case detection
    wire a_nan  = (ea == 8'hFF) && (fa != 23'h0);
    wire b_nan  = (eb == 8'hFF) && (fb != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa == 23'h0);
    wire b_inf  = (eb == 8'hFF) && (fb == 23'h0);
    wire a_zero = (ea == 8'h00);                       // flush subnormals
    wire b_zero = (eb == 8'h00);

    // 24-bit mantissas with hidden bit
    wire [23:0] ma = a_zero ? 24'h0 : {1'b1, fa};
    wire [23:0] mb = b_zero ? 24'h0 : {1'b1, fb};

    // Order operands so that the larger magnitude is "l" and the smaller "s"
    wire a_ge = (ea > eb) || ((ea == eb) && (ma >= mb));
    wire [7:0]  el = a_ge ? ea : eb;
    wire [7:0]  es = a_ge ? eb : ea;
    wire [23:0] ml = a_ge ? ma : mb;
    wire [23:0] ms = a_ge ? mb : ma;
    wire        sl = a_ge ? sa : sb;
    wire        ss = a_ge ? sb : sa;

    // Align : right-shift the smaller mantissa by the exponent difference.
    // Bit layout (28 bits) : [27]=carry, [26]=hidden 1, [25:3]=fraction, [2:0]=guard
    wire [7:0]  shamt   = el - es;
    wire [27:0] ml_ext  = {1'b0, ml, 3'b000};
    wire [27:0] ms_ext  = {1'b0, ms, 3'b000};
    wire [27:0] ms_alig = (shamt >= 8'd28) ? 28'h0 : (ms_ext >> shamt);

    // Add or subtract the magnitudes.
    wire        same_sign = (sl == ss);
    wire [27:0] mag_sum   = same_sign ? (ml_ext + ms_alig) : (ml_ext - ms_alig);

    // Normalisation : find the leading 1 in mag_sum
    reg  [4:0]  lz;
    reg  [27:0] norm_m;
    reg  [9:0]  norm_e;        
    integer     i;
    reg         found;

    always @* begin
        lz      = 5'd0;
        found   = 1'b0;
        norm_m  = mag_sum;
        norm_e  = {2'b00, el};

        if (mag_sum[27]) begin
            // Carry out from same-sign add : shift right 1, exp += 1
            norm_m = mag_sum >> 1;
            norm_e = {2'b00, el} + 10'd1;
        end else if (mag_sum == 28'h0) begin
            norm_m = 28'h0;
            norm_e = 10'h0;
        end else begin
            // Search for leading 1 in bits [26:0]; ideal position is bit 26.
            for (i = 26; i >= 0; i = i - 1) begin
                if (mag_sum[i] && !found) begin
                    lz    = 5'd26 - i[4:0];
                    found = 1'b1;
                end
            end
            if ({5'b0, lz} >= norm_e) begin
                // Underflow : flush to zero
                norm_m = 28'h0;
                norm_e = 10'h0;
            end else begin
                norm_m = mag_sum << lz;
                norm_e = norm_e - {5'b0, lz};
            end
        end
    end

    // After normalisation : norm_m[26] is the implicit 1, norm_m[25:3] is the 23-bit fraction (truncate the 3 guard bits = round-to-zero).
    wire [22:0] frac_norm = norm_m[25:3];

    // Result mux : handle specials and pack the normal result
    reg [31:0] result;
    always @* begin
        if (a_nan || b_nan) begin
            result = 32'h7FC00000;                              // qNaN
        end else if (a_inf && b_inf) begin
            result = (sa == sb) ? {sa, 8'hFF, 23'h0}
                                : 32'h7FC00000;                 // Inf - Inf
        end else if (a_inf) begin
            result = a;
        end else if (b_inf) begin
            result = b_eff;
        end else if (a_zero && b_zero) begin
            result = 32'h00000000;
        end else if (a_zero) begin
            result = b_eff;
        end else if (b_zero) begin
            result = a;
        end else if (mag_sum == 28'h0) begin
            result = 32'h00000000;                              // exact cancellation
        end else if (norm_e >= 10'd255) begin
            result = {sl, 8'hFF, 23'h0};                        // overflow -> Inf
        end else if (norm_e == 10'h0) begin
            result = 32'h00000000;                              // underflow -> 0
        end else begin
            result = {sl, norm_e[7:0], frac_norm};
        end
    end

    assign y = result;
endmodule
