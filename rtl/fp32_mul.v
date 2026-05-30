// fp32_mul : single-precision multiplier (combinational)
//
// Behaviour
//   * Subnormal operands are flushed to zero before processing.
//   * NaN propagates ; 0 * Inf = NaN ; Inf * x = signed Inf.
//   * Round-to-nearest and ties-to-even on the result mantissa.
`timescale 1ns/1ps

module fp32_mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);
    wire        sa = a[31];
    wire [7:0]  ea = a[30:23];
    wire [22:0] fa = a[22:0];
    wire        sb = b[31];
    wire [7:0]  eb = b[30:23];
    wire [22:0] fb = b[22:0];

    wire a_nan  = (ea == 8'hFF) && (fa != 23'h0);
    wire b_nan  = (eb == 8'hFF) && (fb != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa == 23'h0);
    wire b_inf  = (eb == 8'hFF) && (fb == 23'h0);
    wire a_zero = (ea == 8'h00);
    wire b_zero = (eb == 8'h00);

    // Sign of the product
    wire sign = sa ^ sb;

    // 24 x 24 -> 48-bit unsigned product of the mantissas (with hidden bit).
    wire [23:0] ma = {1'b1, fa};
    wire [23:0] mb = {1'b1, fb};
    wire [47:0] prod = ma * mb;

    // Tentative biased exponent : ea + eb - 127.  Use 10 bits to keep sign.
    wire [9:0]  exp_t = {2'b00, ea} + {2'b00, eb} - 10'd127;

    // Normalise : the product's MSB is bit[47] (when ma*mb >= 2.0) or
    // bit[46] (when 1.0 <= ma*mb < 2.0).
    reg [24:0] mantissa_rounded; // Extra bit to catch rounding overflow
    reg [22:0] frac_n;
    reg [9:0]  exp_n;
    
    reg G, R, S, round_up;

    always @* begin
        if (prod[47]) begin
            // Case 1: Mantissa product >= 2.0 (Needs 1-bit right shift)
            // Fraction is prod[46:24]. Discarded is prod[23:0].
            G = prod[23];
            S = |prod[22:0];
            
            // Round up if > 0.5 (G & S), OR if exactly 0.5 and the LSB (prod[24]) is 1 (Ties-to-Even, G & prod[24])
            round_up = G & (S | prod[24]);
            
            // Add the round bit to the {hidden bit, fraction}. Padded to 25 bits to catch overflow.
            mantissa_rounded = {2'b01, prod[46:24]} + round_up;
            
            // Check if rounding caused an overflow
            if (mantissa_rounded[24]) begin
                frac_n = mantissa_rounded[23:1];
                exp_n  = exp_t + 10'd2; // Shifted twice (the >= 2.0 shift and the rounding overflow shift)
            end else begin
                frac_n = mantissa_rounded[22:0];
                exp_n  = exp_t + 10'd1; // The >= 2.0 shift
            end
            
        end else begin
            // Case 2: Mantissa product < 2.0 (No shift needed)
            // Fraction is prod[45:23]. Discarded is prod[22:0].
            G = prod[22];
            S = |prod[21:0];
            
            round_up = G & (S | prod[23]);
            
            mantissa_rounded = {2'b01, prod[45:23]} + round_up;
            
            if (mantissa_rounded[24]) begin
                frac_n = mantissa_rounded[23:1];
                exp_n  = exp_t + 10'd1; // Shifted for rounding overflow
            end else begin
                frac_n = mantissa_rounded[22:0];
                exp_n  = exp_t;
            end
        end
    end

    // Pack with special-case handling
    reg [31:0] result;
    always @* begin
        if (a_nan || b_nan) begin
            result = 32'h7FC00000;
        end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
            result = 32'h7FC00000;                        // 0 * Inf = NaN
        end else if (a_inf || b_inf) begin
            result = {sign, 8'hFF, 23'h0};
        end else if (a_zero || b_zero) begin
            result = {sign, 31'h0};
        end else if (exp_n[9]) begin
            result = {sign, 31'h0};                       // exp went negative -> 0
        end else if (exp_n >= 10'd255) begin
            result = {sign, 8'hFF, 23'h0};                // overflow -> Inf
        end else if (exp_n == 10'h0) begin
            result = {sign, 31'h0};                       // underflow -> 0
        end else begin
            result = {sign, exp_n[7:0], frac_n};
        end
    end

    assign y = result;
endmodule
