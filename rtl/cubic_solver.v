// cubic_solver : solves   a*x^3 + b*x^2 + c*x + d = 0   
// Interface
//   start        :  pulse 1 cycle to launch a new solve
//   a, b, c, d   :  coefficients.
//   done         :  asserted for one cycle when x0/x1/x2 are valid.
//   x0..x2       :  three roots, each as (real, imag) pair.
//
// Algorithm
//   Normalise :  ba = b/a, ca = c/a, da = d/a.    (a == 0 -> all NaN.)
//   Depress   :  x = t - ba/3   ->   t^3 + p*t + q = 0
//                   p = ca - ba^2/3
//                   q = (2*ba^3)/27 - (ba*ca)/3 + da
//   Discriminant   D = q^2/4 + p^3/27
//        D > 0  : Cardano  -> 1 real, 2 complex
//        D < 0  : trig     -> 3 distinct real
//        D = 0  : closed   -> double + simple real (or triple)
//   Un-shift  : x_k = t_k - ba/3.
//
// Design module:
//   Multi-cycle FSM with one shared instance of each unit. Each state drives the FP-unit input mux for one operation, then captures the combinational result into a register at the next clock edge.  

`timescale 1ns/1ps

module cubic_solver (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire [31:0] d,
    output reg         done,
    output reg  [31:0] x0_re,
    output reg  [31:0] x0_im,
    output reg  [31:0] x1_re,
    output reg  [31:0] x1_im,
    output reg  [31:0] x2_re,
    output reg  [31:0] x2_im
);
    //  FP32 constants 
    localparam [31:0] FP_ZERO     = 32'h00000000;
    localparam [31:0] FP_QNAN     = 32'h7FC00000;
    localparam [31:0] FP_HALF     = 32'h3F000000;   // 0.5
    localparam [31:0] FP_QUARTER  = 32'h3E800000;   // 0.25
    localparam [31:0] FP_TWO      = 32'h40000000;   // 2.0
    localparam [31:0] FP_THREE    = 32'h40400000;   // 3.0
    localparam [31:0] FP_ONE_3    = 32'h3EAAAAAB;   // 1/3
    localparam [31:0] FP_ONE_27   = 32'h3D17B426;   // 1/27
    localparam [31:0] FP_TWO_27   = 32'h3D97B426;   // 2/27
    localparam [31:0] FP_SQRT3_2  = 32'h3F5DB3D7;   // sqrt(3)/2
    localparam [31:0] FP_2PI_3    = 32'h40060A92;   // 2*pi/3

    //  States 
    localparam [5:0]
        ST_IDLE       = 6'd0,
        ST_CHECK_A    = 6'd1,
        ST_BA         = 6'd2,
        ST_CA         = 6'd3,
        ST_DA         = 6'd4,
        ST_BA2        = 6'd5,
        ST_BA3        = 6'd6,
        ST_BACA       = 6'd7,
        ST_BA_D3      = 6'd8,    // shift = ba/3
        ST_BA2_D3     = 6'd9,
        ST_BA3_2_27   = 6'd10,
        ST_BACA_D3    = 6'd11,
        ST_P          = 6'd12,
        ST_QPART      = 6'd13,   // q1 = ba3*2/27 - ba_ca/3
        ST_Q          = 6'd14,   // q  = q1 + da
        ST_P2         = 6'd15,
        ST_P3         = 6'd16,
        ST_QSQ        = 6'd17,
        ST_P3_D27     = 6'd18,
        ST_QSQ_D4     = 6'd19,
        ST_D_COMP     = 6'd20,
        ST_BRANCH     = 6'd21,
        // Cardano (D > 0)
        ST_C_SQRTD    = 6'd22,
        ST_C_QH       = 6'd23,
        ST_C_AARG     = 6'd24,
        ST_C_BARG     = 6'd25,
        ST_C_U        = 6'd26,
        ST_C_V        = 6'd27,
        ST_C_UV       = 6'd28,   // root0_re = u + v
        ST_C_HUV      = 6'd29,   // complex_re = -(uv)/2
        ST_C_UMV      = 6'd30,
        ST_C_IMAG     = 6'd31,
        ST_C_PACK     = 6'd32,
        // Trig  (D < 0)
        ST_T_NEGP3    = 6'd33,
        ST_T_SQRTNP3  = 6'd34,
        ST_T_M        = 6'd35,
        ST_T_PM       = 6'd36,
        ST_T_3Q       = 6'd37,
        ST_T_ARG      = 6'd38,
        ST_T_THETA    = 6'd39,
        ST_T_THETA3   = 6'd40,
        ST_T_COS0     = 6'd41,
        ST_T_T0       = 6'd42,
        ST_T_ARG1     = 6'd43,
        ST_T_COS1     = 6'd44,
        ST_T_T1       = 6'd45,
        ST_T_ARG2     = 6'd46,
        ST_T_COS2     = 6'd47,
        ST_T_T2       = 6'd48,
        // D = 0
        ST_Z_NQH      = 6'd49,
        ST_Z_R        = 6'd50,
        ST_Z_SIMPLE   = 6'd51,
        ST_Z_PACK     = 6'd52,
        // Common tail
        ST_UNSHIFT0   = 6'd53,
        ST_UNSHIFT1   = 6'd54,
        ST_UNSHIFT2   = 6'd55,
        ST_DONE       = 6'd56,
        ST_NAN_OUT    = 6'd57;

    reg [5:0]  state;
    reg [6:0]  wait_cnt;                      
    
    // Pipeline latency trackers
    wire       add_done  = (wait_cnt == 7'd4);  
    wire       mul_done  = (wait_cnt == 7'd4);  
    wire       cbrt_done = (wait_cnt == 7'd28); 
    wire       div_done  = (wait_cnt == 7'd49); 
    wire       cos_done  = (wait_cnt == 7'd40); 
    wire       sqrt_done = (wait_cnt == 7'd28); // UPDATED: Sqrt requires 28 clk delays
    wire       acos_done = (wait_cnt == 7'd68); 

    //  coefficients 
    reg [31:0] a_r, b_r, c_r, d_r;

    // Intermediate results 
    reg [31:0] ba, ca, da;
    reg [31:0] ba2, ba3, ba_ca;
    reg [31:0] shift_v;          
    reg [31:0] ba2_d3, ba3_2_27, ba_ca_d3;
    reg [31:0] p_v, q_v;         
    reg [31:0] p2_v, p3_v, qsq;
    reg [31:0] p3_d27, qsq_d4, D_v;

    reg [31:0] sqrtD, qh, A_arg, B_arg, u_v, v_v;
    reg [31:0] complex_re, u_minus_v, imag_v;

    // Trig regs
    reg [31:0] negp3, sqrt_negp3, m_v, pm_v, three_q;
    reg [31:0] theta_arg, theta_v, theta3;
    reg [31:0] cos0_v, cos1_v, cos2_v;
    reg [31:0] arg1_v, arg2_v;

    // D = 0 regs
    reg [31:0] nqh, r_z, simple_root;

    //  root storage
    reg [31:0] root0_re, root0_im;
    reg [31:0] root1_re, root1_im;
    reg [31:0] root2_re, root2_im;

    //  FP unit signals 
    reg  [31:0] mul_a, mul_b;
    reg  [31:0] div_a, div_b;
    reg  [31:0] add_a, add_b;
    reg         add_sub;
    reg  [31:0] sqrt_in, cbrt_in, cos_in, acos_in;

    wire [31:0] mul_y, div_y, add_y, sqrt_y, cbrt_y, cos_y, acos_y;

    // Pipelined CBRT
    fp32_cbrt U_CBRT (
        .clk(clk),
        .en(1'b1),
        .a(cbrt_in),
        .y(cbrt_y)
    );
    
    // Pipelined ACOS
    fp32_acos U_ACOS (
        .clk(clk),
        .en(1'b1),
        .a(acos_in),
        .y(acos_y)
    );

    // Pipelined Sqrt
    fp32_sqrt U_SQRT (
        .clk(clk),
        .en(1'b1),
        .a(sqrt_in),
        .y(sqrt_y)
    );

    // Pipelined Cosine
    fp32_cos U_COS (
        .clk(clk),
        .en(1'b1),
        .a(cos_in),  
        .y(cos_y)
    );

    // Pipelined Multiplier
    fp32_mul U_MUL (
        .clk(clk),
        .en(1'b1),
        .a(mul_a),
        .b(mul_b),
        .y(mul_y)
    );

    // Pipelined Division
    fp32_div U_DIV (
        .clk(clk),
        .en(1'b1), 
        .a(div_a),
        .b(div_b),
        .y(div_y)
    );

    // Pipelined Adder
    fp32_add U_ADD (
        .clk(clk),
        .en(1'b1),
        .a(add_a),
        .b(add_b),
        .sub(add_sub),
        .y(add_y)
    );

    // Branch decoding (combinational on D_v) 
    wire D_zero = (D_v[30:0] == 31'b0);
    wire D_pos  = !D_v[31] && !D_zero;

    // a == 0 detection
    wire a_is_zero = (a_r[30:23] == 8'h00);
    wire a_is_specials = (a_r[30:23] == 8'hFF);

    // Datapath input mux : drive FP units based on current state
    always @* begin
        // safe defaults
        mul_a   = FP_ZERO;  mul_b   = FP_ZERO;
        div_a   = FP_ZERO;  div_b   = 32'h3F800000;   // /1 
        add_a   = FP_ZERO;  add_b   = FP_ZERO;
        add_sub = 1'b0;
        sqrt_in = FP_ZERO;
        cbrt_in = FP_ZERO;
        cos_in  = FP_ZERO;
        acos_in = FP_ZERO;

        case (state)
            //  Normalization (b/a, c/a, d/a) 
            ST_BA: begin div_a = b_r; div_b = a_r; end
            ST_CA: begin div_a = c_r; div_b = a_r; end
            ST_DA: begin div_a = d_r; div_b = a_r; end

            // Coefficients of depressed cubic 
            ST_BA2:      begin mul_a = ba;       mul_b = ba;       end
            ST_BA3:      begin mul_a = ba2;      mul_b = ba;       end
            ST_BACA:     begin mul_a = ba;       mul_b = ca;       end
            ST_BA_D3:    begin mul_a = ba;       mul_b = FP_ONE_3; end
            ST_BA2_D3:   begin mul_a = ba2;      mul_b = FP_ONE_3; end
            ST_BA3_2_27: begin mul_a = ba3;      mul_b = FP_TWO_27;end
            ST_BACA_D3:  begin mul_a = ba_ca;    mul_b = FP_ONE_3; end

            ST_P:        begin add_a = ca;       add_b = ba2_d3;   add_sub = 1'b1; end
            ST_QPART:    begin add_a = ba3_2_27; add_b = ba_ca_d3; add_sub = 1'b1; end
            ST_Q:        begin add_a = q_v;      add_b = da;       add_sub = 1'b0; end

            // Discriminant
            ST_P2:       begin mul_a = p_v;  mul_b = p_v;       end
            ST_P3:       begin mul_a = p2_v; mul_b = p_v;       end
            ST_QSQ:      begin mul_a = q_v;  mul_b = q_v;       end
            ST_P3_D27:   begin mul_a = p3_v; mul_b = FP_ONE_27; end
            ST_QSQ_D4:   begin mul_a = qsq;  mul_b = FP_QUARTER;end
            ST_D_COMP:   begin add_a = qsq_d4; add_b = p3_d27;  add_sub = 1'b0; end

            //  (D > 0) 
            ST_C_SQRTD:  begin sqrt_in = D_v;                                end
            ST_C_QH:     begin mul_a   = q_v;   mul_b = FP_HALF;             end
            ST_C_AARG:   begin add_a   = sqrtD; add_b = qh; add_sub = 1'b1;  end 
            ST_C_BARG:   begin add_a   = sqrtD; add_b = qh; add_sub = 1'b0;  end 
            ST_C_U:      begin cbrt_in = A_arg;                              end
            ST_C_V:      begin cbrt_in = B_arg;                              end
            ST_C_UV:     begin add_a   = u_v;   add_b = v_v; add_sub = 1'b0; end
            ST_C_HUV:    begin mul_a   = root0_re; mul_b = FP_HALF;          end 
            ST_C_UMV:    begin add_a   = u_v;   add_b = v_v; add_sub = 1'b1; end
            ST_C_IMAG:   begin mul_a   = u_minus_v; mul_b = FP_SQRT3_2;      end

            //   (D < 0) 
            //   negp3 = -p/3   
            ST_T_NEGP3:    begin mul_a = {~p_v[31], p_v[30:0]}; mul_b = FP_ONE_3; end
            ST_T_SQRTNP3:  begin sqrt_in = negp3;                                  end
            ST_T_M:        begin mul_a = sqrt_negp3; mul_b = FP_TWO;               end
            ST_T_PM:       begin mul_a = p_v;        mul_b = m_v;                  end
            ST_T_3Q:       begin mul_a = q_v;        mul_b = FP_THREE;             end
            ST_T_ARG:      begin div_a = three_q;    div_b = pm_v;                 end
            ST_T_THETA:    begin acos_in = theta_arg;                               end
            ST_T_THETA3:   begin mul_a = theta_v;    mul_b = FP_ONE_3;             end
            ST_T_COS0:     begin cos_in = theta3;                                   end
            ST_T_T0:       begin mul_a = m_v;        mul_b = cos0_v;               end
            ST_T_ARG1:     begin add_a = theta3;     add_b = FP_2PI_3; add_sub = 1'b1; end
            ST_T_COS1:     begin cos_in = arg1_v;                                   end
            ST_T_T1:       begin mul_a = m_v;        mul_b = cos1_v;               end
            ST_T_ARG2:     begin add_a = theta3;     add_b = FP_2PI_3; add_sub = 1'b0; end
            ST_T_COS2:     begin cos_in = arg2_v;                                   end
            ST_T_T2:       begin mul_a = m_v;        mul_b = cos2_v;               end

            // D = 0
            //   nqh = -q/2  
            ST_Z_NQH:    begin mul_a = {~q_v[31], q_v[30:0]}; mul_b = FP_HALF; end
            ST_Z_R:      begin cbrt_in = nqh;                                  end
            ST_Z_SIMPLE: begin mul_a   = r_z; mul_b = FP_TWO;                  end

            //  Un-shift 
            ST_UNSHIFT0: begin add_a = root0_re; add_b = shift_v; add_sub = 1'b1; end
            ST_UNSHIFT1: begin add_a = root1_re; add_b = shift_v; add_sub = 1'b1; end
            ST_UNSHIFT2: begin add_a = root2_re; add_b = shift_v; add_sub = 1'b1; end

            default: ;   
        endcase
    end

    // Sequential : state transitions and result capture
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            wait_cnt <= 7'd0;
            done     <= 1'b0;
            x0_re <= FP_ZERO; x0_im <= FP_ZERO;
            x1_re <= FP_ZERO; x1_im <= FP_ZERO;
            x2_re <= FP_ZERO; x2_im <= FP_ZERO;
            a_r   <= FP_ZERO; b_r   <= FP_ZERO;
            c_r   <= FP_ZERO; d_r   <= FP_ZERO;
            ba <= FP_ZERO; ca <= FP_ZERO; da <= FP_ZERO;
            ba2 <= FP_ZERO; ba3 <= FP_ZERO; ba_ca <= FP_ZERO;
            shift_v <= FP_ZERO;
            ba2_d3 <= FP_ZERO; ba3_2_27 <= FP_ZERO; ba_ca_d3 <= FP_ZERO;
            p_v <= FP_ZERO; q_v <= FP_ZERO;
            p2_v <= FP_ZERO; p3_v <= FP_ZERO; qsq <= FP_ZERO;
            p3_d27 <= FP_ZERO; qsq_d4 <= FP_ZERO; D_v <= FP_ZERO;
            sqrtD <= FP_ZERO; qh <= FP_ZERO;
            A_arg <= FP_ZERO; B_arg <= FP_ZERO;
            u_v <= FP_ZERO; v_v <= FP_ZERO;
            complex_re <= FP_ZERO; u_minus_v <= FP_ZERO; imag_v <= FP_ZERO;
            negp3 <= FP_ZERO; sqrt_negp3 <= FP_ZERO; m_v <= FP_ZERO;
            pm_v <= FP_ZERO; three_q <= FP_ZERO;
            theta_arg <= FP_ZERO; theta_v <= FP_ZERO; theta3 <= FP_ZERO;
            cos0_v <= FP_ZERO; cos1_v <= FP_ZERO; cos2_v <= FP_ZERO;
            arg1_v <= FP_ZERO; arg2_v <= FP_ZERO;
            nqh <= FP_ZERO; r_z <= FP_ZERO; simple_root <= FP_ZERO;
            root0_re <= FP_ZERO; root0_im <= FP_ZERO;
            root1_re <= FP_ZERO; root1_im <= FP_ZERO;
            root2_re <= FP_ZERO; root2_im <= FP_ZERO;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    wait_cnt <= 7'd0;
                    if (start) begin
                        a_r   <= a;
                        b_r   <= b;
                        c_r   <= c;
                        d_r   <= d;
                        state <= ST_CHECK_A;
                    end
                end

                ST_CHECK_A: begin
                    if (a_is_zero || a_is_specials) state <= ST_NAN_OUT;
                    else                            state <= ST_BA;
                end

                //  Normalization (DIVIDER -> 61 waits) 
                ST_BA: begin if (div_done) begin ba <= div_y; state <= ST_CA; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_CA: begin if (div_done) begin ca <= div_y; state <= ST_DA; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_DA: begin if (div_done) begin da <= div_y; state <= ST_BA2; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end

                //  Powers and products of normalised coeffs (MULTIPLIER -> 4 waits)
                ST_BA2:      begin if (mul_done) begin ba2      <= mul_y; state <= ST_BA3;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BA3:      begin if (mul_done) begin ba3      <= mul_y; state <= ST_BACA;     wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BACA:     begin if (mul_done) begin ba_ca    <= mul_y; state <= ST_BA_D3;    wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BA_D3:    begin if (mul_done) begin shift_v  <= mul_y; state <= ST_BA2_D3;   wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BA2_D3:   begin if (mul_done) begin ba2_d3   <= mul_y; state <= ST_BA3_2_27; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BA3_2_27: begin if (mul_done) begin ba3_2_27 <= mul_y; state <= ST_BACA_D3;  wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_BACA_D3:  begin if (mul_done) begin ba_ca_d3 <= mul_y; state <= ST_P;        wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end

                //  p, q (ADDER -> 4 waits)
                ST_P:     begin if (add_done) begin p_v <= add_y; state <= ST_QPART; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_QPART: begin if (add_done) begin q_v <= add_y; state <= ST_Q;     wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_Q:     begin if (add_done) begin q_v <= add_y; state <= ST_P2;    wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end

                //  Discriminant (MULTIPLIER -> 4 waits)
                ST_P2:      begin if (mul_done) begin p2_v   <= mul_y; state <= ST_P3;     wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_P3:      begin if (mul_done) begin p3_v   <= mul_y; state <= ST_QSQ;    wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_QSQ:     begin if (mul_done) begin qsq    <= mul_y; state <= ST_P3_D27; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_P3_D27:  begin if (mul_done) begin p3_d27 <= mul_y; state <= ST_QSQ_D4; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_QSQ_D4:  begin if (mul_done) begin qsq_d4 <= mul_y; state <= ST_D_COMP; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_D_COMP:  begin if (add_done) begin D_v    <= add_y; state <= ST_BRANCH; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end

                // Branch on sign of D 
                ST_BRANCH: begin
                    if (D_zero)     state <= ST_Z_NQH;
                    else if (D_pos) state <= ST_C_SQRTD;
                    else            state <= ST_T_NEGP3;
                end

                //   (D > 0  -> 1 real + 2 complex)
                ST_C_SQRTD: begin if (sqrt_done) begin sqrtD <= sqrt_y; state <= ST_C_QH; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_C_QH:    begin if (mul_done) begin qh <= mul_y; state <= ST_C_AARG; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                ST_C_AARG:  begin if (add_done) begin A_arg <= add_y; state <= ST_C_BARG; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_C_BARG:  begin if (add_done) begin B_arg <= {~add_y[31], add_y[30:0]}; state <= ST_C_U; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                // Pipelined CBRT -> 28 waits
                ST_C_U:     begin if (cbrt_done) begin u_v <= cbrt_y; state <= ST_C_V; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_C_V:     begin if (cbrt_done) begin v_v <= cbrt_y; state <= ST_C_UV; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                ST_C_UV: begin 
                    if (add_done) begin 
                        root0_re <= add_y; 
                        root0_im <= FP_ZERO; 
                        state <= ST_C_HUV; 
                        wait_cnt <= 7'd0; 
                    end else wait_cnt <= wait_cnt + 1; 
                end
                
                ST_C_HUV: begin 
                    if (mul_done) begin 
                        complex_re <= {~mul_y[31], mul_y[30:0]}; 
                        state <= ST_C_UMV; 
                        wait_cnt <= 7'd0; 
                    end else wait_cnt <= wait_cnt + 1; 
                end
                
                ST_C_UMV:  begin if (add_done) begin u_minus_v <= add_y; state <= ST_C_IMAG; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_C_IMAG: begin if (mul_done) begin imag_v    <= mul_y; state <= ST_C_PACK; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_C_PACK: begin
                    root1_re <= complex_re;
                    root1_im <= imag_v;
                    root2_re <= complex_re;
                    root2_im <= {~imag_v[31], imag_v[30:0]};   // -imag
                    state    <= ST_UNSHIFT0;
                end

                //  (D < 0  -> 3  real)
                ST_T_NEGP3:   begin if (mul_done) begin negp3 <= mul_y; state <= ST_T_SQRTNP3; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_SQRTNP3: begin if (sqrt_done) begin sqrt_negp3 <= sqrt_y; state <= ST_T_M; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_M:       begin if (mul_done) begin m_v   <= mul_y; state <= ST_T_PM;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_PM:      begin if (mul_done) begin pm_v  <= mul_y; state <= ST_T_3Q;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_3Q:      begin if (mul_done) begin three_q <= mul_y; state <= ST_T_ARG;   wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                ST_T_ARG:     begin if (div_done) begin theta_arg <= div_y; state <= ST_T_THETA; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                ST_T_THETA:   begin if (acos_done) begin theta_v <= acos_y; state <= ST_T_THETA3; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_THETA3:  begin if (mul_done) begin theta3 <= mul_y; state <= ST_T_COS0; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                
                ST_T_COS0:    begin if (cos_done) begin cos0_v     <= cos_y;  state <= ST_T_T0;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_T0: begin 
                    if (mul_done) begin 
                        root0_re <= mul_y; 
                        root0_im <= FP_ZERO; 
                        state <= ST_T_ARG1; 
                        wait_cnt <= 7'd0; 
                    end else wait_cnt <= wait_cnt + 1; 
                end
                
                ST_T_ARG1:    begin if (add_done) begin arg1_v <= add_y; state <= ST_T_COS1; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_COS1:    begin if (cos_done) begin cos1_v     <= cos_y;  state <= ST_T_T1;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_T1: begin 
                    if (mul_done) begin 
                        root1_re <= mul_y; 
                        root1_im <= FP_ZERO; 
                        state <= ST_T_ARG2; 
                        wait_cnt <= 7'd0; 
                    end else wait_cnt <= wait_cnt + 1; 
                end
                
                ST_T_ARG2:    begin if (add_done) begin arg2_v <= add_y; state <= ST_T_COS2; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_COS2:    begin if (cos_done) begin cos2_v     <= cos_y;  state <= ST_T_T2;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_T_T2: begin 
                    if (mul_done) begin 
                        root2_re <= mul_y; 
                        root2_im <= FP_ZERO; 
                        state <= ST_UNSHIFT0; 
                        wait_cnt <= 7'd0; 
                    end else wait_cnt <= wait_cnt + 1; 
                end

                // D = 0  (multiple roots)
                ST_Z_NQH:    begin if (mul_done) begin nqh         <= mul_y; state <= ST_Z_R;      wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_Z_R:      begin if (cbrt_done) begin r_z <= cbrt_y; state <= ST_Z_SIMPLE; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_Z_SIMPLE: begin if (mul_done) begin simple_root <= mul_y; state <= ST_Z_PACK;   wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_Z_PACK: begin
                    // simple = 2*r,  double = -r
                    root0_re <= simple_root;
                    root0_im <= FP_ZERO;
                    root1_re <= {~r_z[31], r_z[30:0]};
                    root1_im <= FP_ZERO;
                    root2_re <= {~r_z[31], r_z[30:0]};
                    root2_im <= FP_ZERO;
                    state    <= ST_UNSHIFT0;
                end

                // Un-shift :  x_k = root_k - shift  (= root_k - ba/3)
                ST_UNSHIFT0: begin if (add_done) begin x0_re <= add_y; x0_im <= root0_im; state <= ST_UNSHIFT1; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_UNSHIFT1: begin if (add_done) begin x1_re <= add_y; x1_im <= root1_im; state <= ST_UNSHIFT2; wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end
                ST_UNSHIFT2: begin if (add_done) begin x2_re <= add_y; x2_im <= root2_im; state <= ST_DONE;     wait_cnt <= 7'd0; end else wait_cnt <= wait_cnt + 1; end

                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                // a == 0 :  output six NaN
                ST_NAN_OUT: begin
                    x0_re <= FP_QNAN; x0_im <= FP_QNAN;
                    x1_re <= FP_QNAN; x1_im <= FP_QNAN;
                    x2_re <= FP_QNAN; x2_im <= FP_QNAN;
                    state <= ST_DONE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule