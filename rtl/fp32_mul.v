`timescale 1ns/1ps

module fp32_mul (
    input  wire        clk,
    input  wire        en,       // Pipeline enable/stall
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);

    // Unpack & Register Inputs
    
    // Unpack fields
    wire        sa_w = a[31];
    wire [7:0]  ea_w = a[30:23];
    wire [22:0] fa_w = a[22:0];
    wire        sb_w = b[31];
    wire [7:0]  eb_w = b[30:23];
    wire [22:0] fb_w = b[22:0];

    // Detect specials
    wire a_nan_w  = (ea_w == 8'hFF) && (fa_w != 23'h0);
    wire b_nan_w  = (eb_w == 8'hFF) && (fb_w != 23'h0);
    wire a_inf_w  = (ea_w == 8'hFF) && (fa_w == 23'h0);
    wire b_inf_w  = (eb_w == 8'hFF) && (fb_w == 23'h0);
    wire a_zero_w = (ea_w == 8'h00);
    wire b_zero_w = (eb_w == 8'h00);

    // Add hidden bits (0s are overridden at the final packing stage)
    wire [23:0] ma_w = {1'b1, fa_w};
    wire [23:0] mb_w = {1'b1, fb_w};

    // Stage 1 Registers
    reg [23:0] s1_ma, s1_mb;
    reg [7:0]  s1_ea, s1_eb;
    reg        s1_sign;
    reg [5:0]  s1_flags;     // packed: {a_nan, b_nan, a_inf, b_inf, a_zero, b_zero}

    always @(posedge clk) begin
        if (en) begin
            s1_ma    <= ma_w;
            s1_mb    <= mb_w;
            s1_ea    <= ea_w;
            s1_eb    <= eb_w;
            s1_sign  <= sa_w ^ sb_w;
            s1_flags <= {a_nan_w, b_nan_w, a_inf_w, b_inf_w, a_zero_w, b_zero_w};
        end
    end

    // Multiply & Add Exponents
    
    // 24 x 24 -> 48-bit unsigned product of the mantissas
    wire [47:0] prod_w  = s1_ma * s1_mb;
    
    // Tentative biased exponent : ea + eb - 127. (10 bits to catch sign/underflows)
    wire [9:0]  exp_t_w = {2'b00, s1_ea} + {2'b00, s1_eb} - 10'd127;

    // Stage 2 Registers
    reg [47:0] s2_prod;
    reg [9:0]  s2_exp_t;
    reg        s2_sign;
    reg [5:0]  s2_flags;

    always @(posedge clk) begin
        if (en) begin
            s2_prod  <= prod_w;
            s2_exp_t <= exp_t_w;
            s2_sign  <= s1_sign;
            s2_flags <= s1_flags;
        end
    end

    // Normalise & Round (Ties-to-Even)
    
    reg [24:0] mantissa_rounded_w;
    reg [22:0] frac_n_w;
    reg [9:0]  exp_n_w;
    reg        G_w, S_w, round_up_w;

    always @* begin
        if (s2_prod[47]) begin
            // Case 1: Mantissa product >= 2.0 (Needs 1-bit right shift)
            G_w = s2_prod[23];
            S_w = |s2_prod[22:0];
            
            // Round up if > 0.5 (G & S), OR if exactly 0.5 and the LSB is 1 (Ties-to-Even)
            round_up_w = G_w & (S_w | s2_prod[24]);
            
            // Add the round bit (padded to 25 bits to catch rounding overflow)
            mantissa_rounded_w = {2'b01, s2_prod[46:24]} + round_up_w;
            
            if (mantissa_rounded_w[24]) begin
                frac_n_w = mantissa_rounded_w[23:1];
                exp_n_w  = s2_exp_t + 10'd2; // Shifted twice 
            end else begin
                frac_n_w = mantissa_rounded_w[22:0];
                exp_n_w  = s2_exp_t + 10'd1; // Shifted once
            end
            
        end else begin
            // Case 2: Mantissa product < 2.0 (No shift needed)
            G_w = s2_prod[22];
            S_w = |s2_prod[21:0];
            
            round_up_w = G_w & (S_w | s2_prod[23]);
            
            mantissa_rounded_w = {2'b01, s2_prod[45:23]} + round_up_w;
            
            if (mantissa_rounded_w[24]) begin
                frac_n_w = mantissa_rounded_w[23:1];
                exp_n_w  = s2_exp_t + 10'd1; // Shifted for rounding overflow
            end else begin
                frac_n_w = mantissa_rounded_w[22:0];
                exp_n_w  = s2_exp_t;
            end
        end
    end

    // Registers
    reg [22:0] s3_frac_n;
    reg [9:0]  s3_exp_n;
    reg        s3_sign;
    reg [5:0]  s3_flags;

    always @(posedge clk) begin
        if (en) begin
            s3_frac_n <= frac_n_w;
            s3_exp_n  <= exp_n_w;
            s3_sign   <= s2_sign;
            s3_flags  <= s2_flags;
        end
    end

    // Pack Output & Handle Exceptions
    
    // Unpack flags
    wire s3_a_nan  = s3_flags[5];
    wire s3_b_nan  = s3_flags[4];
    wire s3_a_inf  = s3_flags[3];
    wire s3_b_inf  = s3_flags[2];
    wire s3_a_zero = s3_flags[1];
    wire s3_b_zero = s3_flags[0];

    reg [31:0] result_w;
    always @* begin
        if (s3_a_nan || s3_b_nan) begin
            result_w = 32'h7FC00000;                       // NaN
        end else if ((s3_a_inf && s3_b_zero) || (s3_a_zero && s3_b_inf)) begin
            result_w = 32'h7FC00000;                       // 0 * Inf = NaN
        end else if (s3_a_inf || s3_b_inf) begin
            result_w = {s3_sign, 8'hFF, 23'h0};           // Inf
        end else if (s3_a_zero || s3_b_zero) begin
            result_w = {s3_sign, 31'h0};                  // 0
        end else if (s3_exp_n[9]) begin
            result_w = {s3_sign, 31'h0};                  // exp went negative -> underflow -> 0
        end else if (s3_exp_n >= 10'd255) begin
            result_w = {s3_sign, 8'hFF, 23'h0};           // overflow -> Inf
        end else if (s3_exp_n == 10'h0) begin
            result_w = {s3_sign, 31'h0};                  // underflow -> 0
        end else begin
            result_w = {s3_sign, s3_exp_n[7:0], s3_frac_n}; // Normal pack
        end
    end

    // Final Output Register
    reg [31:0] y_reg;
    always @(posedge clk) begin
        if (en) begin
            y_reg <= result_w;
        end
    end

    assign y = y_reg;

endmodule