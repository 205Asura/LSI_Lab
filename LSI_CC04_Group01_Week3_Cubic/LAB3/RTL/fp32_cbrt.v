// fp32_cbrt : single-precision cube root (pipelined)
// Latency   : 28 cycles
//
// Algorithm : Digit Recurrence (Shift-and-Subtract)
//   - Calculates the cube root 1 bit at a time over 26 stages.
//   - Consumes ZERO multipliers (0 DSP slices), relying purely on shifts and adds.
//   - Exponent is pre-calculated via a fast constant division by 3.
//   - Generates 26 bits of mantissa allowing exact Round-to-Nearest tie-to-even.
//
// Specials : cbrt(NaN)=NaN ; cbrt(+/-0)=+/-0 ; cbrt(+/-Inf)=+/-Inf.
`timescale 1ns/1ps

module fp32_cbrt (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_QNAN  = 32'h7FC00000;

    // STAGE 0: Unpack & Pre-compute Exponent / Initial Shifts
    wire        s  = a[31];
    wire [7:0]  E  = a[30:23];
    wire [22:0] fa = a[22:0];
    
    wire a_nan  = (E == 8'hFF) && (fa != 0);
    wire a_inf  = (E == 8'hFF) && (fa == 0);
    wire a_zero = (E == 8'h00);

    // Fast Divide Exponent by 3
    // E_adj = E - 127. To keep remainders positive, we offset by +129.
    // A = (E - 127) + 129 = E + 2.
    wire [8:0]  A = {1'b0, E} + 9'd2;
    wire [18:0] A_mul = A * 10'd342;         // 342 = 1024/3. Synthesizes to simple shifts/adds
    wire [7:0]  q_A = A_mul[18:10];          // Floor(A / 3)
    wire [8:0]  q_A_3 = {1'b0, q_A} + {q_A, 1'b0}; // q_A * 3
    wire [1:0]  r = A - q_A_3;               // Remainder in {0, 1, 2}
    
    // New Exponent = (q_A - 43) + 127 = q_A + 84
    wire [7:0]  E_new = q_A + 8'd84;

    // Align mantissa based on remainder (r). 
    // Shift left by 'r' dynamically shifts the implicit 1 into the correct top 3 bits.
    wire [77:0] init_x_shift = {2'b00, 1'b1, fa, 52'd0} << r;

    // PIPELINE REGISTERS
    // Context Bypassing [11] = nan, [10] = inf, [9] = zero, [8] = sign, [7:0] = E_new
    reg [11:0] ctx_pipe [0:27]; 
    
    // Math Shift Registers
    reg [56:0] R_pipe [0:26]; // Remainder
    reg [25:0] Y_pipe [0:26]; // Partial Root Accumulator
    reg [53:0] S_pipe [0:26]; // 3*Y^2 Tracker
    reg [77:0] X_pipe [0:26]; // Shifting Input Mantissa

    integer k;
    always @(posedge clk) begin
        if (en) begin
            // Stage 0 Entry
            ctx_pipe[0] <= {a_nan, a_inf, a_zero, s, E_new};
            R_pipe[0]   <= 57'd0;
            Y_pipe[0]   <= 26'd0;
            S_pipe[0]   <= 54'd0;
            X_pipe[0]   <= init_x_shift;

            // Shift sideband context forward
            for (k=1; k<=27; k=k+1) begin
                ctx_pipe[k] <= ctx_pipe[k-1];
            end
        end
    end

    // STAGES 1 to 26: Digit Recurrence Loop
    genvar i;
    generate
        for (i=0; i<26; i=i+1) begin : gen_cbrt_stage
            wire [56:0] R_in = R_pipe[i];
            wire [25:0] Y_in = Y_pipe[i];
            wire [53:0] S_in = S_pipe[i];
            wire [77:0] X_in = X_pipe[i];

            // 1. Shift Remainder up by 3, drop in next 3 bits of X
            wire [56:0] R_next = {R_in[53:0], X_in[77:75]};
            
            // 2. Test value T = 12Y^2 + 6Y + 1
            // S_in mathematically tracks exactly 3Y^2. 
            // 12Y^2 is 4*S_in (S_in shifted left by 2).
            // 6Y is 4*Y_in + 2*Y_in (Y_in shifted left by 2 and 1).
            wire [56:0] T = {1'b0, S_in, 2'b00} + {29'd0, Y_in, 2'b00} + {30'd0, Y_in, 1'b0} + 57'd1;
            
            // 3. Compare and subtract
            wire do_sub = (R_next >= T);

            always @(posedge clk) begin
                if (en) begin
                    // Register Remainder
                    R_pipe[i+1] <= do_sub ? (R_next - T) : R_next;
                    
                    // Register Partial Root (append 1 or 0)
                    Y_pipe[i+1] <= do_sub ? {Y_in[24:0], 1'b1} : {Y_in[24:0], 1'b0};
                    
                    // Register S (3Y^2 Tracker)
                    // If sub: S_next = 3(2Y + 1)^2 = 12Y^2 + 12Y + 3 = 4S + 8Y + 4Y + 3
                    S_pipe[i+1] <= do_sub ? ({S_in[51:0], 2'b00} + {25'd0, Y_in, 3'b000} + {26'd0, Y_in, 2'b00} + 54'd3) 
                                          :  {S_in[51:0], 2'b00};
                    
                    // Shift input bits out
                    X_pipe[i+1] <= {X_in[74:0], 3'b000};
                end
            end
        end
    endgenerate

    // STAGE 27: Rounding & Final Packing
    wire [11:0] final_ctx = ctx_pipe[26];
    wire f_nan  = final_ctx[11];
    wire f_inf  = final_ctx[10];
    wire f_zero = final_ctx[9];
    wire f_s    = final_ctx[8];
    wire [7:0]  f_E = final_ctx[7:0];

    wire [25:0] final_Y = Y_pipe[26];
    wire [56:0] final_R = R_pipe[26];

    // Y is 26 bits. Y[25] = implicit 1, Y[24:2] = 23-bit mantissa.
    wire R_bit = final_Y[1];                            // Round bit
    wire S_bit = final_Y[0] | (final_R != 57'd0);       // Sticky bit
    wire G_bit = final_Y[2];                            // Guard bit

    wire round_up = R_bit & (S_bit | G_bit);            // Tie-to-even
    wire [23:0] rounded_mant = {1'b0, final_Y[24:2]} + round_up;

    // Handle potential rounding overflow (e.g. 1.111 -> 2.0)
    wire [7:0]  out_E = f_E + rounded_mant[23];
    wire [22:0] out_M = rounded_mant[23] ? 23'd0 : rounded_mant[22:0];

    reg [31:0] result;
    always @* begin
        if      (f_nan)  result = FP_QNAN;
        else if (f_zero) result = {f_s, 31'h0};
        else if (f_inf)  result = {f_s, 8'hFF, 23'h0};
        else             result = {f_s, out_E, out_M};
    end

    // Result Register (Cycle 28)
    reg [31:0] y_reg;
    always @(posedge clk) begin
        if (en) y_reg <= result;
    end
    assign y = y_reg;

endmodule