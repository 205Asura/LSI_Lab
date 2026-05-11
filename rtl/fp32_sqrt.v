// fp32_sqrt :  single-precision square root (combinational)
//
// Algorithm (LUT seed + NR on 1/sqrt, no division required)
//
//   x = 2^e * m,  m in [1,2).  e = ea - 127.
//
//   * If e is even : sqrt(x) = 2^(e/2) * sqrt(m)
//   * If e is odd  : sqrt(x) = 2^((e-1)/2) * sqrt(2*m)
//
//   Let  m_arg = m       (e even)  in [1,2)
//        m_arg = 2*m     (e odd )  in [2,4)
//
//   1. Look up an initial estimate  z0 ~ 1/sqrt(m_arg)  from a 32-entry table
//      indexed by {e_is_odd, fa[22:19]}  -> ~6-bit accurate seed.
//   2. Two NR iterations on  z = 1/sqrt(m_arg) :
//
//          z_{k+1} = z_k * (1.5 - 0.5 * m_arg * z_k^2)
//
//      Quadratic convergence : 6 -> 12 -> 24 bits (saturates at FP32 precision).
//   3. sqrt(m_arg) = m_arg * z2.
//   4. Pack result with biased exponent  127 + (e>>1) , taking the mantissa
//      from the m_arg * z2 product.
//
// Specials :  sqrt(NaN)=NaN ; sqrt(<0)=NaN ; sqrt(+0)=+0 ; sqrt(+Inf)=+Inf.
`timescale 1ns/1ps

module fp32_sqrt (
    input  wire [31:0] a,
    output wire [31:0] y
);
    // Constants
    localparam [31:0] FP_HALF = 32'h3F000000;   // 0.5
    localparam [31:0] FP_ONE5 = 32'h3FC00000;   // 1.5
    localparam [31:0] FP_QNAN = 32'h7FC00000;

    // Decode
    wire        sa = a[31];
    wire [7:0]  ea = a[30:23];
    wire [22:0] fa = a[22:0];
    wire a_nan  = (ea == 8'hFF) && (fa != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa == 23'h0);
    wire a_zero = (ea == 8'h00);
    wire a_neg  = sa && !a_zero;                          // sqrt(-x) = NaN, sqrt(-0)=+0

    // True (unbiased) exponent e = ea - 127.  e is odd iff ea is even (bias 127 is odd).
    wire e_is_odd = ~ea[0];

    // Build m_arg :
    //   e_is_odd = 0 -> m_arg = 1.fa  (biased exp 127 -> in [1,2))
    //   e_is_odd = 1 -> m_arg = 2.fa  (biased exp 128 -> in [2,4))
    wire [31:0] m_arg = {1'b0, e_is_odd ? 8'd128 : 8'd127, fa};

    // LUT for 1/sqrt(m_arg) 
    wire [4:0] idx = {e_is_odd, fa[22:19]};
    reg  [31:0] z0;
    always @* begin
        case (idx)
            5'd00: z0 = 32'h3F800000; // 1/sqrt(1.0000)
            5'd01: z0 = 32'h3F785B42; // 1/sqrt(1.0625)
            5'd02: z0 = 32'h3F715BEF; // 1/sqrt(1.1250)
            5'd03: z0 = 32'h3F6AEBF5; // 1/sqrt(1.1875)
            5'd04: z0 = 32'h3F64F92E; // 1/sqrt(1.2500)
            5'd05: z0 = 32'h3F5F7483; // 1/sqrt(1.3125)
            5'd06: z0 = 32'h3F5A514A; // 1/sqrt(1.3750)
            5'd07: z0 = 32'h3F5584CD; // 1/sqrt(1.4375)
            5'd08: z0 = 32'h3F5105EC; // 1/sqrt(1.5000)
            5'd09: z0 = 32'h3F4CCCCD; // 1/sqrt(1.5625)
            5'd10: z0 = 32'h3F48D2AB; // 1/sqrt(1.6250)
            5'd11: z0 = 32'h3F4511A3; // 1/sqrt(1.6875)
            5'd12: z0 = 32'h3F41848F; // 1/sqrt(1.7500)
            5'd13: z0 = 32'h3F3E26EB; // 1/sqrt(1.8125)
            5'd14: z0 = 32'h3F3AF4BA; // 1/sqrt(1.8750)
            5'd15: z0 = 32'h3F37EA74; // 1/sqrt(1.9375)
            5'd16: z0 = 32'h3F3504F3; // 1/sqrt(2.0000)
            5'd17: z0 = 32'h3F2F9D53; // 1/sqrt(2.1250)
            5'd18: z0 = 32'h3F2AAAAB; // 1/sqrt(2.2500)
            5'd19: z0 = 32'h3F261D5F; // 1/sqrt(2.3750)
            5'd20: z0 = 32'h3F21E89B; // 1/sqrt(2.5000)
            5'd21: z0 = 32'h3F1E01B3; // 1/sqrt(2.6250)
            5'd22: z0 = 32'h3F1A5FB2; // 1/sqrt(2.7500)
            5'd23: z0 = 32'h3F16FB06; // 1/sqrt(2.8750)
            5'd24: z0 = 32'h3F13CD3A; // 1/sqrt(3.0000)
            5'd25: z0 = 32'h3F10D0C3; // 1/sqrt(3.1250)
            5'd26: z0 = 32'h3F0E00D5; // 1/sqrt(3.2500)
            5'd27: z0 = 32'h3F0B5948; // 1/sqrt(3.3750)
            5'd28: z0 = 32'h3F08D677; // 1/sqrt(3.5000)
            5'd29: z0 = 32'h3F067532; // 1/sqrt(3.6250)
            5'd30: z0 = 32'h3F0432A5; // 1/sqrt(3.7500)
            5'd31: z0 = 32'h3F020C52; // 1/sqrt(3.8750)
            default: z0 = 32'h3F800000;
        endcase
    end

    //  NR iteration 1 :  z1 = z0 * (1.5 - 0.5 * m_arg * z0^2)  
    wire [31:0] z0sq, half_m, half_m_z0sq, paren1, z1;
    fp32_mul U_S0SQ (.a(z0),     .b(z0),         .y(z0sq));
    fp32_mul U_S0HM (.a(m_arg),  .b(FP_HALF),    .y(half_m));
    fp32_mul U_S0P  (.a(half_m), .b(z0sq),       .y(half_m_z0sq));
    fp32_add U_S0PA (.a(FP_ONE5),.b(half_m_z0sq),.sub(1'b1),.y(paren1));
    fp32_mul U_S0Z1 (.a(z0),     .b(paren1),     .y(z1));

    //  NR iteration 2  
    wire [31:0] z1sq, half_m_z1sq, paren2, z2;
    fp32_mul U_S1SQ (.a(z1),     .b(z1),         .y(z1sq));
    fp32_mul U_S1P  (.a(half_m), .b(z1sq),       .y(half_m_z1sq));
    fp32_add U_S1PA (.a(FP_ONE5),.b(half_m_z1sq),.sub(1'b1),.y(paren2));
    fp32_mul U_S1Z2 (.a(z1),     .b(paren2),     .y(z2));

    //  sqrt(m_arg) = m_arg * z2  
    wire [31:0] sqrt_marg;
    fp32_mul U_FIN  (.a(m_arg),  .b(z2),         .y(sqrt_marg));

    // Exponent   
    // sqrt_marg lives roughly in [1, 2) (the m_arg=4 boundary case rounds to 2).
    // Its biased exponent is ~127.  We need final biased exp = 127 + (e>>1)
    //   where e = ea - 127.  Equivalently  ea_out = sqrt_marg_exp + (ea-127)/2
    //   for ea even, or  (ea-128)/2 for ea odd (e_is_odd=1).
    wire signed [9:0] e_unb       = $signed({2'b00, ea}) - 10'sd127;
    wire signed [9:0] e_half      = e_is_odd ? ((e_unb - 10'sd1) >>> 1) : (e_unb >>> 1);
    wire signed [9:0] new_exp_t   = $signed({2'b00, sqrt_marg[30:23]}) + e_half - 10'sd127;
    // new_exp_t is the *adjustment* to the biased exponent of sqrt_marg.
    wire signed [9:0] new_biased  = $signed({2'b00, sqrt_marg[30:23]}) + e_half;

    reg [31:0] result;
    always @* begin
        if (a_nan || a_neg) begin
            result = FP_QNAN;
        end else if (a_zero) begin
            result = {sa, 31'h0};                          // sqrt(+0) = +0, sqrt(-0)=NaN handled above
        end else if (a_inf) begin
            result = {1'b0, 8'hFF, 23'h0};
        end else if (new_biased <= 10'sd0) begin
            result = 32'h00000000;
        end else if (new_biased >= 10'sd255) begin
            result = {1'b0, 8'hFF, 23'h0};
        end else begin
            result = {1'b0, new_biased[7:0], sqrt_marg[22:0]};
        end
    end

    assign y = result;
endmodule
