//  tb_cubic_solver : testbench for the floating point 32-bit cubic solver.
//
//  Coverage:
//    1. Basic arithmetics: fp32_add / sub / mul / div
//    2. Complex functions: fp32_sqrt / cbrt / cos / acos
//    3. Many cubic equation cases:  all three discriminant branches, triple / double roots, large & smallmagnitudes, negative & fractional a,and the degenerate a == 0 case.

//
//  Every check prints PASS/FAIL and updates global counters; a summary is
//  printed at the end. 
`timescale 1ns/1ps

module tb_cubic_solver;
    reg         clk, rst_n, start;
    reg  [31:0] a, b, c, d;
    wire        done;
    wire [31:0] x0_re, x0_im, x1_re, x1_im, x2_re, x2_im;

    cubic_solver DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a(a), .b(b), .c(c), .d(d), .done(done),
        .x0_re(x0_re), .x0_im(x0_im),
        .x1_re(x1_re), .x1_im(x1_im),
        .x2_re(x2_re), .x2_im(x2_im)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg  [31:0] ua, ub;          // operands for binary units
    reg  [31:0] ux;              // operand for unary units
    wire [31:0] r_add, r_sub, r_mul, r_div;
    wire [31:0] r_sqrt, r_cbrt, r_cos, r_acos;

    fp32_add  T_ADD  (.a(ua), .b(ub), .sub(1'b0), .y(r_add));
    fp32_add  T_SUB  (.a(ua), .b(ub), .sub(1'b1), .y(r_sub));
    fp32_mul  T_MUL  (.a(ua), .b(ub),             .y(r_mul));
    fp32_div  T_DIV  (.a(ua), .b(ub),             .y(r_div));
    fp32_sqrt T_SQRT (.a(ux),                     .y(r_sqrt));
    fp32_cbrt T_CBRT (.a(ux),                     .y(r_cbrt));
    fp32_cos  T_COS  (.a(ux),                     .y(r_cos));
    fp32_acos T_ACOS (.a(ux),                     .y(r_acos));

    integer n_pass = 0;
    integer n_fail = 0;

    function real fp2r;
        input [31:0] f;
        integer e, i;
        real frac, m, sgn, scale;
        begin
            sgn = f[31] ? -1.0 : 1.0;
            if (f[30:23] == 8'h00)      fp2r = 0.0;                 // zero / subnormal
            else if (f[30:23] == 8'hFF) fp2r = sgn * 1.0e30;        // Inf/NaN sentinel
            else begin
                e = $signed({1'b0, f[30:23]}) - 127;
                frac = 0.0;
                for (i = 0; i < 23; i = i + 1)
                    if (f[22-i]) frac = frac + (2.0 ** (-1.0 - i));
                m     = 1.0 + frac;
                scale = (e >= 0) ? (2.0 ** e) : (1.0 / (2.0 ** (-e)));
                fp2r  = sgn * m * scale;
            end
        end
    endfunction

    function is_qnan;
        input [31:0] f;
        begin is_qnan = (f[30:23] == 8'hFF) && (f[22:0] != 23'h0); end
    endfunction

    function real rabs;
        input real v; begin rabs = (v < 0.0) ? -v : v; end
    endfunction

    // comparision helper 
    task expect_val;
        input [127:0] name;     // short ASCII label
        input [31:0]  got;
        input [31:0]  exp;
        input real    atol;
        input real    rtol;
        real gr, er, err, tol;
        begin
            gr  = fp2r(got);
            er  = fp2r(exp);
            err = rabs(gr - er);
            tol = atol + rtol * rabs(er);
            if (is_qnan(got)) begin
                n_fail = n_fail + 1;
                $display("  FAIL %-0s : got NaN, expected %0.6f", name, er);
            end else if (err <= tol) begin
                n_pass = n_pass + 1;
                $display("  PASS %-0s : %0.6f  (exp %0.6f, err %0.2e)", name, gr, er, err);
            end else begin
                n_fail = n_fail + 1;
                $display("  FAIL %-0s : %0.6f  (exp %0.6f, err %0.2e > tol %0.2e)",
                         name, gr, er, err, tol);
            end
        end
    endtask

    task check_add; input [31:0] x,y,e; begin ua=x; ub=y; #1; expect_val("add ",r_add,e,1e-4,1e-4); end endtask
    task check_sub; input [31:0] x,y,e; begin ua=x; ub=y; #1; expect_val("sub ",r_sub,e,1e-4,1e-4); end endtask
    task check_mul; input [31:0] x,y,e; begin ua=x; ub=y; #1; expect_val("mul ",r_mul,e,1e-4,1e-4); end endtask
    task check_div; input [31:0] x,y,e; begin ua=x; ub=y; #1; expect_val("div ",r_div,e,1e-4,2e-4); end endtask
    task check_sqrt;input [31:0] x,e;   begin ux=x;      #1; expect_val("sqrt",r_sqrt,e,1e-4,1e-3); end endtask
    task check_cbrt;input [31:0] x,e;   begin ux=x;      #1; expect_val("cbrt",r_cbrt,e,1e-4,1e-3); end endtask
    task check_cos; input [31:0] x,e;   begin ux=x;      #1; expect_val("cos ",r_cos,e,3e-3,0.0);   end endtask
    task check_acos;input [31:0] x,e;   begin ux=x;      #1; expect_val("acos",r_acos,e,6e-3,0.0);  end endtask

    // run one cubic + check
    // matches the three (re,im) outputs against three expected roots,
    // order-independent, within abs 2e-2 + rel 2e-2.
    reg  [31:0] gre [0:2];
    reg  [31:0] gim [0:2];
    reg  [31:0] ere [0:2];
    reg  [31:0] eim [0:2];
    reg         used [0:2];

    task automatic launch;
        input [31:0] aa,bb,cc,dd;
        output reg timed_out;
        integer cyc;
        begin
            timed_out = 1'b0;
            cyc = 0;
            while (done === 1'b1 && cyc < 2000) begin @(posedge clk); cyc=cyc+1; end
            if (done === 1'b1) timed_out = 1'b1;

            @(posedge clk); a<=aa; b<=bb; c<=cc; d<=dd; start<=1'b1;
            @(posedge clk); start<=1'b0;
            cyc = 0;
            while (done !== 1'b1 && cyc < 2000) begin @(posedge clk); cyc=cyc+1; end
            if (done !== 1'b1) timed_out = 1'b1;
            @(negedge clk);
        end
    endtask

    task run_cubic;
        input [600:0] label;
        input [31:0] aa,bb,cc,dd;
        input [31:0] e0r,e0i,e1r,e1i,e2r,e2i;
        integer i,j,bj; real dr,di,d2,best,tol,eabs;
        reg ok;
        reg timed_out;
        begin
            launch(aa,bb,cc,dd, timed_out);
            if (timed_out) begin
                n_fail=n_fail+1;
                $display("  FAIL  %0s (timeout)", label);
                repeat (2) @(posedge clk);
            end else begin
            gre[0]=x0_re; gim[0]=x0_im;
            gre[1]=x1_re; gim[1]=x1_im;
            gre[2]=x2_re; gim[2]=x2_im;
            ere[0]=e0r; eim[0]=e0i; ere[1]=e1r; eim[1]=e1i; ere[2]=e2r; eim[2]=e2i;
            used[0]=0; used[1]=0; used[2]=0;
            ok = 1'b1;
            for (i=0;i<3;i=i+1) begin
                best=1.0e30; bj=-1;
                for (j=0;j<3;j=j+1) if (!used[j]) begin
                    dr = fp2r(gre[j]) - fp2r(ere[i]);
                    di = fp2r(gim[j]) - fp2r(eim[i]);
                    d2 = (dr*dr + di*di);
                    if (d2 < best) begin best=d2; bj=j; end
                end
                used[bj]=1'b1;
                eabs = (rabs(fp2r(ere[i]))*rabs(fp2r(ere[i])) + rabs(fp2r(eim[i]))*rabs(fp2r(eim[i])));
                eabs = (eabs<=0.0)?0.0:$sqrt(eabs);
                tol  = 2.0e-2 + 2.0e-2*eabs;
                if (is_qnan(gre[bj]) || is_qnan(gim[bj])) ok=1'b0;
                else if ($sqrt(best) > tol) ok=1'b0;
            end
            if (ok) begin
                n_pass=n_pass+1;
                $display("  PASS  %0s", label);
            end else begin
                n_fail=n_fail+1;
                $display("  FAIL  %0s", label);
            end
            $display("        x0=%0.5f%+0.5fi  x1=%0.5f%+0.5fi  x2=%0.5f%+0.5fi",
                     fp2r(x0_re),fp2r(x0_im),fp2r(x1_re),fp2r(x1_im),fp2r(x2_re),fp2r(x2_im));
            repeat (2) @(posedge clk);
            end
        end
    endtask

    // a == 0 : expect six NaNs
    task run_cubic_nan;
        input [600:0] label;
        input [31:0] aa,bb,cc,dd;
        reg ok;
        reg timed_out;
        begin
            launch(aa,bb,cc,dd, timed_out);
            if (timed_out) begin
                n_fail=n_fail+1;
                $display("  FAIL  %0s (timeout)", label);
                repeat (2) @(posedge clk);
            end else begin
                ok = is_qnan(x0_re)&&is_qnan(x0_im)&&is_qnan(x1_re)&&
                     is_qnan(x1_im)&&is_qnan(x2_re)&&is_qnan(x2_im);
                if (ok) begin n_pass=n_pass+1; $display("  PASS  %0s", label); end
                else    begin n_fail=n_fail+1; $display("  FAIL  %0s (expected all-NaN)", label); end
                repeat (2) @(posedge clk);
            end
        end
    endtask

    // MAIN TEST SEQUENCE
    initial begin
        $dumpfile("cubic_solver.vcd");
        $dumpvars(0, tb_cubic_solver);

        rst_n=0; start=0; a=0; b=0; c=0; d=0; ua=0; ub=0; ux=0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("\n 1. FP32 BASIC ARITHMETIC ");
        $display("-- addition --");
        check_add(32'h3F800000,32'h40000000,32'h40400000);
        check_add(32'h40600000,32'h3FA00000,32'h40980000);
        check_add(32'hC0000000,32'hC0400000,32'hC0A00000);
        check_add(32'h42C80000,32'h3F000000,32'h42C90000);
        check_add(32'h49742400,32'h3F800000,32'h49742410);
        check_add(32'hC0E00000,32'h40E00000,32'h00000000);
        check_add(32'h3DCCCCCD,32'h3E4CCCCD,32'h3E99999A);
        $display("-- subtraction --");
        check_sub(32'h40A00000,32'h40400000,32'h40000000);
        check_sub(32'h3F800000,32'h3F800000,32'h00000000);
        check_sub(32'h40200000,32'h40800000,32'hBFC00000);
        check_sub(32'hC0400000,32'hC0400000,32'h00000000);
        check_sub(32'h49742400,32'h3F800000,32'h497423F0);
        check_sub(32'h3E99999A,32'h3DCCCCCD,32'h3E4CCCCE);
        $display("-- multiplication --");
        check_mul(32'h40000000,32'h40400000,32'h40C00000);
        check_mul(32'hBFC00000,32'h40800000,32'hC0C00000);
        check_mul(32'h3F000000,32'h3F000000,32'h3E800000);
        check_mul(32'h40E00000,32'h41000000,32'h42600000);
        check_mul(32'hC0000000,32'hC0000000,32'h40800000);
        check_mul(32'h3FC00000,32'h3FC00000,32'h40100000);
        check_mul(32'h42F60000,32'h3C23D70A,32'h3F9D70A4);
        $display("-- division --");
        check_div(32'h40C00000,32'h40000000,32'h40400000);
        check_div(32'h3F800000,32'h40400000,32'h3EAAAAAB);
        check_div(32'hC1000000,32'h40000000,32'hC0800000);
        check_div(32'h41100000,32'h40800000,32'h40100000);
        check_div(32'h3F800000,32'h40E00000,32'h3E124925);
        check_div(32'h42C80000,32'h40800000,32'h41C80000);
        check_div(32'h40A00000,32'h3F000000,32'h41200000);

        $display("\n 2. FP32 COMPLEX FUNCTIONS ");
        $display("-- square root --");
        check_sqrt(32'h40800000,32'h40000000);
        check_sqrt(32'h40000000,32'h3FB504F3);
        check_sqrt(32'h41100000,32'h40400000);
        check_sqrt(32'h3E800000,32'h3F000000);
        check_sqrt(32'h49742400,32'h447A0000);
        check_sqrt(32'h3FC00000,32'h3F9CC471);
        check_sqrt(32'h41800000,32'h40800000);
        check_sqrt(32'h3C23D70A,32'h3DCCCCCD);
        $display("-- cube root --");
        check_cbrt(32'h41000000,32'h40000000);
        check_cbrt(32'h41D80000,32'h40400000);
        check_cbrt(32'hC1000000,32'hC0000000);
        check_cbrt(32'h447A0000,32'h41200000);
        check_cbrt(32'h3E000000,32'h3F000000);
        check_cbrt(32'h3F800000,32'h3F800000);
        check_cbrt(32'h42800000,32'h40800000);
        check_cbrt(32'hC1D80000,32'hC0400000);
        $display("-- cosine --");
        check_cos(32'h00000000,32'h3F800000);
        check_cos(32'h3F860A92,32'h3F000000);
        check_cos(32'h3FC90FDB,32'h00000000);
        check_cos(32'h40490FDB,32'hBF800000);
        check_cos(32'h40060A92,32'hBF000000);
        check_cos(32'h3F060A92,32'h3F5DB3D7);
        check_cos(32'h3F800000,32'h3F0A5140);
        $display("-- arccosine --");
        check_acos(32'h3F800000,32'h00000000);
        check_acos(32'h3F000000,32'h3F860A92);
        check_acos(32'h00000000,32'h3FC90FDB);
        check_acos(32'hBF800000,32'h40490FDB);
        check_acos(32'hBF000000,32'h40060A92);
        check_acos(32'h3F5DB3D0,32'h3F060A9F);
        check_acos(32'hBE800000,32'h3FE967AE);

        $display("\n========== 3. CUBIC SOLVER vs EXPECTED ROOTS ==========");
        run_cubic("(x-1)(x-2)(x-3): 3 distinct real",
            32'h3F800000,32'hC0C00000,32'h41300000,32'hC0C00000,
            32'h40400000,32'h00000000, 32'h40000000,32'h00000000, 32'h3F800000,32'h00000000);
        run_cubic("(x-1)(x-2)(x+3): 3 distinct real",
            32'h3F800000,32'h00000000,32'hC0E00000,32'h40C00000,
            32'hC0400000,32'h00000000, 32'h40000000,32'h00000000, 32'h3F800000,32'h00000000);
        run_cubic("(x+1)(x+2)(x+3): 3 negative real",
            32'h3F800000,32'h40C00000,32'h41300000,32'h40C00000,
            32'hC0400000,32'h00000000, 32'hC0000000,32'h00000000, 32'hBF800000,32'h00000000);
        run_cubic("x^3-1: 1 real + 2 complex",
            32'h3F800000,32'h00000000,32'h00000000,32'hBF800000,
            32'hBF000000,32'h3F5DB3D7, 32'hBF000000,32'hBF5DB3D7, 32'h3F800000,32'h00000000);
        run_cubic("(x-1)(x^2-x+1): 1 real + 2 complex",
            32'h3F800000,32'hC0000000,32'h40000000,32'hBF800000,
            32'h3F800000,32'h00000000, 32'h3F000000,32'h3F5DB3D7, 32'h3F000000,32'hBF5DB3D7);
        run_cubic("(x+1)(x^2+1): real -1, +/- i",
            32'h3F800000,32'h3F800000,32'h3F800000,32'h3F800000,
            32'hBF800000,32'h00000000, 32'hA6600000,32'h3F800000, 32'hA6600000,32'hBF800000);
        run_cubic("x(x^2+1): real 0, +/- i",
            32'h3F800000,32'h00000000,32'h3F800000,32'h00000000,
            32'h80000000,32'h3F800000, 32'h00000000,32'hBF800000, 32'h00000000,32'h00000000);
        run_cubic("x^3=8 (neg lead): 2, -1 +/- 1.732 i",
            32'hBF800000,32'h00000000,32'h00000000,32'h41000000,
            32'hBF800000,32'h3FDDB3D7, 32'hBF800000,32'hBFDDB3D7, 32'h40000000,32'h00000000);
        run_cubic("x^3=1e6: 100 + complex (large)",
            32'h3F800000,32'h00000000,32'h00000000,32'hC9742400,
            32'hC2480000,32'h42AD3480, 32'hC2480000,32'hC2AD3480, 32'h42C80000,32'h00000000);
        run_cubic("(x-1)^3: triple root",
            32'h3F800000,32'hC0400000,32'h40400000,32'hBF800000,
            32'h3F800037,32'h00000000, 32'h3F7FFFC9,32'h36BEEE0D, 32'h3F7FFFC9,32'hB6BEEE0D);
        run_cubic("(x-1)^2(x-2): double + simple",
            32'h3F800000,32'hC0800000,32'h40A00000,32'hC0000000,
            32'h40000000,32'h00000000, 32'h3F800000,32'h32F3524B, 32'h3F800000,32'hB2F3524B);
        run_cubic("0.5 x (x-1)(x-2): roots 0,1,2 (fractional a)",
            32'h3F000000,32'hBFC00000,32'h3F800000,32'h00000000,
            32'h40000000,32'h00000000, 32'h3F800000,32'h00000000, 32'h00000000,32'h00000000);
        run_cubic("roots 0,0.1,0.2 (small)",
            32'h3F800000,32'hBE99999A,32'h3CA3D70A,32'h00000000,
            32'h3E4CCCCF,32'h00000000, 32'h3DCCCCCB,32'h00000000, 32'h00000000,32'h00000000);
        run_cubic("2(x-1)(x-4)(x+3): scaled, roots 1,4,-3",
            32'h40000000,32'hC0800000,32'hC1B00000,32'h41C00000,
            32'hC0400000,32'h00000000, 32'h40800000,32'h00000000, 32'h3F800000,32'h00000000);
        run_cubic("SPEC EXAMPLE x^3-x^2-8x+12: roots -3,2,2 (double)",
            32'h3F800000,32'hBF800000,32'hC1000000,32'h41400000,
            32'hC0400000,32'h00000000, 32'h40000000,32'h32E35625, 32'h40000000,32'hB2E35625);
        run_cubic("(x-4)^3: triple root at 4",
            32'h3F800000,32'hC1400000,32'h42400000,32'hC2800000,
            32'h40800029,32'h380F4A9E, 32'h40800029,32'hB80F4A9E, 32'h407FFF5B,32'h00000000);
        run_cubic_nan("a=0 (degenerate, not a cubic): expect all NaN", 32'h00000000,32'h3F800000,32'hC0400000,32'h40000000);
        run_cubic_nan("a=0,b=0 (degenerate linear): expect all NaN", 32'h00000000,32'h00000000,32'h40A00000,32'h41200000);

        $display("\n==================== SUMMARY ====================");
        $display("  PASS : %0d", n_pass);
        $display("  FAIL : %0d", n_fail);
        if (n_fail == 0) $display("  RESULT: ALL TESTS PASSED");
        else             $display("  RESULT: %0d TEST(S) FAILED", n_fail);
        $display("=================================================\n");

        repeat (5) @(posedge clk);
        $finish;
    end

    // hard watchdog
    initial begin #500000; $display("*** SIM WATCHDOG TIMEOUT ***"); $finish; end

endmodule
