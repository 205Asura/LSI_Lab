// fp32_cbrt :  single-precision cube root (combinational)
//
// Algorithm (LUT seed + NR on 1/cbrt, no division required)
//
//   x = 2^e * m,  m in [1,2).  Let  e = 3*q + r  with r in {0,1,2}.
//   Then  cbrt(x) = 2^q * cbrt(2^r * m) = 2^q * cbrt(m_arg)
//   with  m_arg = 2^r * m  in  [1, 8).
//
//   1. LUT seed  z0 ~ 1/cbrt(m_arg)  indexed by  {r, fa[22:19]}  (48 entries,
//      ~6 bits accurate).
//   2. Two NR iterations on 1/cbrt :
//
//          z_{k+1} = z_k * (4 - m_arg * z_k^3) / 3
//
//      Quadratic convergence -> well below FP32 ulp after two passes.
//   3. cbrt(m_arg) = m_arg * z2^2.
//   4. Pack with biased exponent  127 + q.
//
//   Negative inputs : cbrt is odd, so cbrt(-x) = -cbrt(x).  Handle with sign.
`timescale 1ns/1ps

module fp32_cbrt (
    input  wire [31:0] a,
    output wire [31:0] y
);
    localparam [31:0] FP_ONETHIRD = 32'h3EAAAAAB;   // 1/3
    localparam [31:0] FP_FOUR     = 32'h40800000;   // 4.0
    localparam [31:0] FP_QNAN     = 32'h7FC00000;

    // Decode (work on |a| for the magnitude, restore sign at the end)
    wire        sa = a[31];
    wire [7:0]  ea = a[30:23];
    wire [22:0] fa = a[22:0];
    wire a_nan  = (ea == 8'hFF) && (fa != 23'h0);
    wire a_inf  = (ea == 8'hFF) && (fa == 23'h0);
    wire a_zero = (ea == 8'h00);

    // ---- Compute  r = e mod 3  using the rule  ea mod 3  --------------------
    // 2^k mod 3 alternates 1,2,1,2 for k = 0,1,2,3,...
    wire [2:0] sum_even = ea[0] + ea[2] + ea[4] + ea[6];
    wire [2:0] sum_odd  = ea[1] + ea[3] + ea[5] + ea[7];
    wire [4:0] modin    = {2'b00, sum_even} + {1'b0, sum_odd, 1'b0};   // sum_even + 2*sum_odd
    reg  [1:0] ea_mod3;
    always @* begin
        case (modin)
            5'd0, 5'd3, 5'd6, 5'd9, 5'd12:  ea_mod3 = 2'd0;
            5'd1, 5'd4, 5'd7, 5'd10:        ea_mod3 = 2'd1;
            5'd2, 5'd5, 5'd8, 5'd11:        ea_mod3 = 2'd2;
            default:                        ea_mod3 = 2'd0;
        endcase
    end
    // r = (ea_mod3 + 2) mod 3       (because e = ea - 127, and -127 ≡ 2 mod 3)
    reg [1:0] r;
    always @* begin
        case (ea_mod3)
            2'd0: r = 2'd2;
            2'd1: r = 2'd0;
            2'd2: r = 2'd1;
            default: r = 2'd0;
        endcase
    end

    // ---- m_arg = 2^r * m  --------------------------------------------------
    // m has biased exp 127 (1.fa).  m_arg has biased exp 127 + r in {127,128,129}.
    wire [7:0]  earg = 8'd127 + {6'b0, r};
    wire [31:0] m_arg = {1'b0, earg, fa};

    // ---- LUT for 1/cbrt(m_arg)  -------------------------------------------
    wire [5:0] idx = {r, fa[22:19]};
    reg  [31:0] z0;
    always @* begin
        case (idx)
            // r = 0 :  m_arg in [1, 2)
            6'd00: z0 = 32'h3F800000;
            6'd01: z0 = 32'h3F7AE0ED;
            6'd02: z0 = 32'h3F7624D8;
            6'd03: z0 = 32'h3F71BF60;
            6'd04: z0 = 32'h3F6DA63C;
            6'd05: z0 = 32'h3F69D0CD;
            6'd06: z0 = 32'h3F6637C8;
            6'd07: z0 = 32'h3F62D4F3;
            6'd08: z0 = 32'h3F5FA2F8;
            6'd09: z0 = 32'h3F5C9D36;
            6'd10: z0 = 32'h3F59BFA9;
            6'd11: z0 = 32'h3F5706CA;
            6'd12: z0 = 32'h3F546F83;
            6'd13: z0 = 32'h3F51F717;
            6'd14: z0 = 32'h3F4F9B18;
            6'd15: z0 = 32'h3F4D595C;
            // r = 1 :  m_arg in [2, 4)
            6'd16: z0 = 32'h3F4B2FF5;
            6'd17: z0 = 32'h3F471F5C;
            6'd18: z0 = 32'h3F435D54;
            6'd19: z0 = 32'h3F3FE00B;
            6'd20: z0 = 32'h3F3C9F56;
            6'd21: z0 = 32'h3F399460;
            6'd22: z0 = 32'h3F36B95C;
            6'd23: z0 = 32'h3F34095B;
            6'd24: z0 = 32'h3F318020;
            6'd25: z0 = 32'h3F2F19FE;
            6'd26: z0 = 32'h3F2CD3C6;
            6'd27: z0 = 32'h3F2AAAAB;
            6'd28: z0 = 32'h3F289C39;
            6'd29: z0 = 32'h3F26A644;
            6'd30: z0 = 32'h3F24C6E0;
            6'd31: z0 = 32'h3F22FC54;
            // r = 2 :  m_arg in [4, 8)
            6'd32: z0 = 32'h3F214518;
            6'd33: z0 = 32'h3F1E0B2B;
            6'd34: z0 = 32'h3F1B0F9B;
            6'd35: z0 = 32'h3F184A9A;
            6'd36: z0 = 32'h3F15B5AF;
            6'd37: z0 = 32'h3F134B6C;
            6'd38: z0 = 32'h3F110737;
            6'd39: z0 = 32'h3F0EE526;
            6'd40: z0 = 32'h3F0CE1DA;
            6'd41: z0 = 32'h3F0AFA6A;
            6'd42: z0 = 32'h3F092C4E;
            6'd43: z0 = 32'h3F07754E;
            6'd44: z0 = 32'h3F05D377;
            6'd45: z0 = 32'h3F044510;
            6'd46: z0 = 32'h3F02C892;
            6'd47: z0 = 32'h3F015C9F;
            default: z0 = 32'h3F800000;
        endcase
    end

    // ---- NR iteration 1 :  z1 = z0 * (4 - m_arg*z0^3) / 3  -----------------
    wire [31:0] z0sq, z0cu, mz0cu, paren1, t_div3, z1;
    fp32_mul U_C0SQ (.a(z0),    .b(z0),     .y(z0sq));
    fp32_mul U_C0CU (.a(z0sq),  .b(z0),     .y(z0cu));
    fp32_mul U_C0MZ (.a(m_arg), .b(z0cu),   .y(mz0cu));
    fp32_add U_C0P  (.a(FP_FOUR), .b(mz0cu), .sub(1'b1), .y(paren1));
    fp32_mul U_C0D3 (.a(paren1),.b(FP_ONETHIRD), .y(t_div3));
    fp32_mul U_C0Z1 (.a(z0),    .b(t_div3), .y(z1));

    // ---- NR iteration 2  ---------------------------------------------------
    wire [31:0] z1sq, z1cu, mz1cu, paren2, t2_div3, z2;
    fp32_mul U_C1SQ (.a(z1),    .b(z1),     .y(z1sq));
    fp32_mul U_C1CU (.a(z1sq),  .b(z1),     .y(z1cu));
    fp32_mul U_C1MZ (.a(m_arg), .b(z1cu),   .y(mz1cu));
    fp32_add U_C1P  (.a(FP_FOUR), .b(mz1cu), .sub(1'b1), .y(paren2));
    fp32_mul U_C1D3 (.a(paren2),.b(FP_ONETHIRD), .y(t2_div3));
    fp32_mul U_C1Z2 (.a(z1),    .b(t2_div3), .y(z2));

    // ---- cbrt(m_arg) = m_arg * z2^2  ---------------------------------------
    wire [31:0] z2sq, cbrt_marg;
    fp32_mul U_Z2SQ (.a(z2),    .b(z2),     .y(z2sq));
    fp32_mul U_CBRT (.a(m_arg), .b(z2sq),   .y(cbrt_marg));

    // ---- Exponent assembly  ------------------------------------------------
    // q = (e - r) / 3  with  e = ea - 127.
    wire signed [9:0] e_unb     = $signed({2'b00, ea}) - 10'sd127;
    wire signed [9:0] e_minus_r = e_unb - {{8{1'b0}}, r};
    wire signed [9:0] q         = e_minus_r / 10'sd3;
    wire signed [9:0] new_bias  = $signed({2'b00, cbrt_marg[30:23]}) + q;

    reg [31:0] result;
    always @* begin
        if (a_nan) begin
            result = FP_QNAN;
        end else if (a_zero) begin
            result = {sa, 31'h0};
        end else if (a_inf) begin
            result = {sa, 8'hFF, 23'h0};
        end else if (new_bias <= 10'sd0) begin
            result = {sa, 31'h0};
        end else if (new_bias >= 10'sd255) begin
            result = {sa, 8'hFF, 23'h0};
        end else begin
            result = {sa, new_bias[7:0], cbrt_marg[22:0]};
        end
    end

    assign y = result;
endmodule
