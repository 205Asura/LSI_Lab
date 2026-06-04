/*
fp32_add

Algorithm:

- Stage 1: Unpacks inputs, strips hidden bits, screens for special metrics (NaN, Inf, Zero), and executes an integer magnitude comparison to arrange operands into larger (el) and smaller (es) parameters.
- Stage 2: Right-shifts the smaller mantissa to align its radix point with the larger value, then computes the raw 28-bit mantissa sum or difference.
- Stage 3: Normalizes the resulting fraction using an unrolled LZC barrel shifter loop and realigns the exponent vector.
- Stage 4: Evaluates Guard (G), Round (R), and Sticky (S) bits to enforce Round-to-Nearest (Tie-to-Even) alignment before checking for overflow or underflow boundaries and packing the final 32-bit vector.
*/


`timescale 1ns/1ps

module fp32_add (
    input  wire        clk,
    input  wire        en,       // Pipeline enable/stall
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sub,
    output wire [31:0] y
);

    // Stage 1 : Unpack, Special Cases, & Magnitude Comparison
    
    // Comb logic for Stage 1
    wire [31:0] b_eff_w = sub ? {~b[31], b[30:0]} : b;
    wire        sa_w    = a[31];
    wire [7:0]  ea_w    = a[30:23];
    wire [22:0] fa_w    = a[22:0];
    wire        sb_w    = b_eff_w[31];
    wire [7:0]  eb_w    = b_eff_w[30:23];
    wire [22:0] fb_w    = b_eff_w[22:0];

    wire a_nan_w  = (ea_w == 8'hFF) && (fa_w != 23'h0);
    wire b_nan_w  = (eb_w == 8'hFF) && (fb_w != 23'h0);
    wire a_inf_w  = (ea_w == 8'hFF) && (fa_w == 23'h0);
    wire b_inf_w  = (eb_w == 8'hFF) && (fb_w == 23'h0);
    wire a_zero_w = (ea_w == 8'h00); 
    wire b_zero_w = (eb_w == 8'h00);

    wire [23:0] ma_w = a_zero_w ? 24'h0 : {1'b1, fa_w};
    wire [23:0] mb_w = b_zero_w ? 24'h0 : {1'b1, fb_w};

    wire a_ge_w       = (ea_w > eb_w) || ((ea_w == eb_w) && (ma_w >= mb_w));
    wire [7:0]  el_w  = a_ge_w ? ea_w : eb_w;
    wire [7:0]  es_w  = a_ge_w ? eb_w : ea_w;
    wire [23:0] ml_w  = a_ge_w ? ma_w : mb_w;
    wire [23:0] ms_w  = a_ge_w ? mb_w : ma_w;
    wire        sl_w  = a_ge_w ? sa_w : sb_w;
    wire        ss_w  = a_ge_w ? sb_w : sa_w;
    
    // Stage 1 Pipeline Registers
    reg [7:0]  s1_shamt;
    reg [27:0] s1_ml_ext;
    reg [23:0] s1_ms;
    reg        s1_same_sign;
    reg        s1_sl;
    reg [7:0]  s1_el;
    reg [7:0]  s1_flags;     // packed: {a_nan, b_nan, a_inf, b_inf, a_zero, b_zero, sa, sb}
    reg [31:0] s1_a, s1_b_eff;

    always @(posedge clk) begin
        if (en) begin
            s1_shamt     <= el_w - es_w;
            s1_ml_ext    <= {1'b0, ml_w, 3'b000};
            s1_ms        <= ms_w;
            s1_same_sign <= (sl_w == ss_w);
            s1_sl        <= sl_w;
            s1_el        <= el_w;
            s1_flags     <= {a_nan_w, b_nan_w, a_inf_w, b_inf_w, a_zero_w, b_zero_w, sa_w, sb_w};
            s1_a         <= a;
            s1_b_eff     <= b_eff_w;
        end
    end

  
    // Stage 2 : Alignment Shift & Addition

    
    // Comb logic for Stage 2
    reg align_sticky_w;
    always @* begin
        if (s1_shamt <= 8'd3) 
            align_sticky_w = 1'b0;
        else if (s1_shamt >= 8'd27) 
            align_sticky_w = |s1_ms;
        else 
            align_sticky_w = |(s1_ms << (5'd27 - s1_shamt[4:0])); 
    end

    wire [27:0] s1_ms_ext = {1'b0, s1_ms, 3'b000};
    wire [27:0] ms_alig_w = (s1_shamt >= 8'd28) ? {27'h0, |s1_ms} : ((s1_ms_ext >> s1_shamt) | {27'h0, align_sticky_w});
    wire [27:0] mag_sum_w = s1_same_sign ? (s1_ml_ext + ms_alig_w) : (s1_ml_ext - ms_alig_w);

    // Stage 2 Pipeline Registers
    reg [27:0] s2_mag_sum;
    reg        s2_sl;
    reg [7:0]  s2_el;
    reg [7:0]  s2_flags;
    reg [31:0] s2_a, s2_b_eff;

    always @(posedge clk) begin
        if (en) begin
            s2_mag_sum <= mag_sum_w;
            s2_sl      <= s1_sl;
            s2_el      <= s1_el;
            s2_flags   <= s1_flags;
            s2_a       <= s1_a;
            s2_b_eff   <= s1_b_eff;
        end
    end


    // Stage 3 : Normalisation (Leading Zero Count)
 
    // Comb logic for Stage 3
    reg  [4:0]  lz_w;
    reg  [27:0] norm_m_w;
    reg  [9:0]  norm_e_w;        
    integer     i;
    reg         found_w;

    always @* begin
        lz_w      = 5'd0;
        found_w   = 1'b0;
        norm_m_w  = s2_mag_sum;
        norm_e_w  = {2'b00, s2_el};

        if (s2_mag_sum[27]) begin
            norm_m_w = s2_mag_sum >> 1;
            norm_e_w = {2'b00, s2_el} + 10'd1;
        end else if (s2_mag_sum == 28'h0) begin
            norm_m_w = 28'h0;
            norm_e_w = 10'h0;
        end else begin
            // Search for leading 1
            for (i = 26; i >= 0; i = i - 1) begin
                if (s2_mag_sum[i] && !found_w) begin
                    lz_w    = 5'd26 - i[4:0];
                    found_w = 1'b1;
                end
            end
            if ({5'b0, lz_w} >= norm_e_w) begin
                norm_m_w = 28'h0;
                norm_e_w = 10'h0;
            end else begin
                norm_m_w = s2_mag_sum << lz_w;
                norm_e_w = norm_e_w - {5'b0, lz_w};
            end
        end
    end

    // Stage 3 Pipeline Registers
    reg [27:0] s3_norm_m;
    reg [9:0]  s3_norm_e;
    reg        s3_sl;
    reg        s3_mag_sum_zero;
    reg [7:0]  s3_flags;
    reg [31:0] s3_a, s3_b_eff;

    always @(posedge clk) begin
        if (en) begin
            s3_norm_m       <= norm_m_w;
            s3_norm_e       <= norm_e_w;
            s3_sl           <= s2_sl;
            s3_mag_sum_zero <= (s2_mag_sum == 28'h0);
            s3_flags        <= s2_flags;
            s3_a            <= s2_a;
            s3_b_eff        <= s2_b_eff;
        end
    end


    // Stage 4 : Rounding & Final Packing
    
    // Unpack flags for readability
    wire a_nan_f  = s3_flags[7];
    wire b_nan_f  = s3_flags[6];
    wire a_inf_f  = s3_flags[5];
    wire b_inf_f  = s3_flags[4];
    wire a_zero_f = s3_flags[3];
    wire b_zero_f = s3_flags[2];
    wire sa_f     = s3_flags[1];
    wire sb_f     = s3_flags[0];

    // Comb logic for Stage 4
    wire G   = s3_norm_m[2];
    wire R   = s3_norm_m[1];
    wire S   = s3_norm_m[0]; 
    wire LSB = s3_norm_m[3];
    
    wire round_up = G & (R | S | LSB);
    wire [24:0] rounded_frac_ext = {2'b01, s3_norm_m[25:3]} + round_up;
    
    reg [22:0] frac_final;
    reg [9:0]  exp_final;
    
    always @* begin
        if (rounded_frac_ext[24]) begin 
            frac_final = rounded_frac_ext[23:1];
            exp_final  = s3_norm_e + 10'd1;
        end else begin
            frac_final = rounded_frac_ext[22:0];
            exp_final  = s3_norm_e;
        end
    end

    reg [31:0] result_w;
    always @* begin
        if (a_nan_f || b_nan_f) begin
            result_w = 32'h7FC00000;
        end else if (a_inf_f && b_inf_f) begin
            result_w = (sa_f == sb_f) ? {sa_f, 8'hFF, 23'h0} : 32'h7FC00000; 
        end else if (a_inf_f) begin
            result_w = s3_a;
        end else if (b_inf_f) begin
            result_w = s3_b_eff;
        end else if (a_zero_f && b_zero_f) begin
            result_w = 32'h00000000;
        end else if (a_zero_f) begin
            result_w = s3_b_eff;
        end else if (b_zero_f) begin
            result_w = s3_a;
        end else if (s3_mag_sum_zero) begin
            result_w = 32'h00000000; 
        end else if (exp_final >= 10'd255) begin
            result_w = {s3_sl, 8'hFF, 23'h0}; 
        end else if (exp_final == 10'h0) begin
            result_w = 32'h00000000; 
        end else begin
            result_w = {s3_sl, exp_final[7:0], frac_final};
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