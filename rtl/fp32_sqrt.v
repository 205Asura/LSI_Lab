// fp32_sqrt : single-precision square root (pipelined)
// Latency   : 28 cycles
//
// Algorithm : Digit Recurrence (Shift-and-Subtract)
//   - Calculates the square root 1 bit at a time over 26 stages.
//   - Consumes ZERO multipliers (0 DSP slices), relying purely on shifts and adds.
//   - Exponent is pre-calculated via a fast right-shift.
//   - Generates 26 bits of mantissa allowing exact Round-to-Nearest tie-to-even.
//
// Specials : sqrt(NaN)=NaN ; sqrt(x<0)=NaN ; sqrt(+/-0)=+/-0 ; sqrt(+Inf)=+Inf.
`timescale 1ns/1ps

module fp32_sqrt (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    // Unpack & Pre-compute Exponent / Initial Shifts
    wire        s  = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    
    wire a_nan  = (E == 8'hFF) && (fa != 0);
    wire a_inf  = (E == 8'hFF) && (fa == 0);
    wire a_zero = (E == 8'h00);
    wire a_neg  = s && !a_zero;

    // Fast Square Root Exponent
    // E_new = floor((E - 127) / 2) + 127. 
    // In hardware, this simplifies perfectly to: (E + 127) >> 1
    // (Padded to 9 bits to prevent overflow for inputs >= 4.0)
    wire [7:0] E_new = ({1'b0, E} + 9'd127) >> 1;

    // Align mantissa based on exponent parity.
    // If E is even (e.g., e is odd), we shift left by 1 to multiply the radicand by 2.
    wire shift = ~E[0];
    
    // Radicand is aligned into a 52-bit shift register.
    wire [51:0] init_x_shift = {1'b0, 1'b1, fa, 27'd0} << shift;

    // Context Bypassing [12] = nan, [11] = neg, [10] = inf, [9] = zero, [8] = sign, [7:0] = E_new
    reg [12:0] ctx_pipe [0:27]; 
    
    // Math Shift Registers
    reg [27:0] R_pipe [0:26]; // Remainder
    reg [25:0] Y_pipe [0:26]; // Partial Root Accumulator
    reg [51:0] X_pipe [0:26]; // Shifting Input Mantissa

    integer k;
    always @(posedge clk) begin
        if (en) begin
            // Stage 0 Entry
            ctx_pipe[0] <= {a_nan, a_neg, a_inf, a_zero, s, E_new};
            R_pipe[0]   <= 28'd0;
            Y_pipe[0]   <= 26'd0;
            X_pipe[0]   <= init_x_shift;

            // Shift sideband context forward
            for (k=1; k<=27; k=k+1) begin
                ctx_pipe[k] <= ctx_pipe[k-1];
            end
        end
    end

    // Digit Recurrence Loop
    genvar i;
    generate
        for (i=0; i<26; i=i+1) begin : gen_sqrt_stage
            wire [27:0] R_in = R_pipe[i];
            wire [25:0] Y_in = Y_pipe[i];
            wire [51:0] X_in = X_pipe[i];

            // Shift Remainder up by 2, drop in next 2 bits of X
            wire [27:0] R_next = {R_in[25:0], X_in[51:50]};
            
            // Test value T = 4Y + 1
            // Formed effortlessly by shifting Y left by 2 and appending 01
            wire [27:0] T = {Y_in, 2'b01};
            
            // Compare and subtract
            wire do_sub = (R_next >= T);

            always @(posedge clk) begin
                if (en) begin
                    // Register Remainder
                    R_pipe[i+1] <= do_sub ? (R_next - T) : R_next;
                    
                    // Register Partial Root (append 1 or 0)
                    Y_pipe[i+1] <= do_sub ? {Y_in[24:0], 1'b1} : {Y_in[24:0], 1'b0};
                    
                    // Shift input bits out
                    X_pipe[i+1] <= {X_in[49:0], 2'b00};
                end
            end
        end
    endgenerate

    // Rounding & Final Packing
    wire [12:0] final_ctx = ctx_pipe[26];
    wire f_nan  = final_ctx[12];
    wire f_neg  = final_ctx[11];
    wire f_inf  = final_ctx[10];
    wire f_zero = final_ctx[9];
    wire f_s    = final_ctx[8];
    wire [7:0]  f_E = final_ctx[7:0];

    wire [25:0] final_Y = Y_pipe[26];
    wire [27:0] final_R = R_pipe[26];

    // Y is 26 bits. Y[25] = implicit 1, Y[24:2] = 23-bit mantissa.
    wire G_bit = final_Y[1];                            // Guard bit
    wire R_bit = final_Y[0];                            // Round bit
    wire S_bit = (final_R != 28'd0);                    // Sticky bit
    wire LSB   = final_Y[2];                            // Least Significant Bit of Mantissa

    wire round_up = G_bit & (R_bit | S_bit | LSB);      // Tie-to-even Rounding
    wire [23:0] rounded_mant = {1'b0, final_Y[24:2]} + round_up;

    // Handle potential rounding overflow
    wire [7:0]  out_E = f_E + rounded_mant[23];
    wire [22:0] out_M = rounded_mant[23] ? 23'd0 : rounded_mant[22:0];

    reg [31:0] result;
    always @* begin
        if      (f_nan || f_neg) result = FP_QNAN;
        else if (f_zero)         result = {f_s, 31'h0};
        else if (f_inf)          result = {f_s, 8'hFF, 23'h0};
        else                     result = {f_s, out_E, out_M};
    end

    // Result Register
    reg [31:0] y_reg;
    always @(posedge clk) begin
        if (en) y_reg <= result;
    end
    assign y = y_reg;

endmodule