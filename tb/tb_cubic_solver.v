// tb_cubic_solver : directed-test bench for the cubic solver.
//
// Five cases :
//   1. x^3 - 6x^2 + 11x - 6  =  (x-1)(x-2)(x-3)         3 distinct real
//   2. x^3 - 1               =  (x-1)(x^2+x+1)          1 real, 2 complex
//   3. x^3 - 3x^2 + 3x - 1   =  (x-1)^3                 triple root
//   4. x^3 - 4x^2 + 5x - 2   =  (x-1)^2 (x-2)           double + simple
//   5. a = 0                                            degenerate -> NaNs
//
// Notes 
//   * All FP32 results carry the round-to-zero bias of every elementary op and the seed-NR error of sqrt/cbrt/cos/acos. Roots are typically accurate to 3-4 decimal digits, which the lab spec accepts.
//   * Tight-D-near-zero cases (case 4) cross between the Cardano and the trig branches depending on round-off ; they print useful insight on the solver's behaviour at the discriminant boundary.
`timescale 1ns/1ps

module tb_cubic_solver;
    reg         clk;
    reg         rst_n;
    reg         start;
    reg  [31:0] a, b, c, d;
    wire        done;
    wire [31:0] x0_re, x0_im, x1_re, x1_im, x2_re, x2_im;

    cubic_solver DUT (
        .clk   (clk),
        .rst_n (rst_n),
        .start (start),
        .a     (a),
        .b     (b),
        .c     (c),
        .d     (d),
        .done  (done),
        .x0_re (x0_re), .x0_im (x0_im),
        .x1_re (x1_re), .x1_im (x1_im),
        .x2_re (x2_re), .x2_im (x2_im)
    );

    //  100 MHz clock 
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //  FP32 -> real for human-readable display 
    function real fp32_to_real;
        input [31:0] f;
        integer e;
        real    frac;
        integer i;
        real    m, sgn, scale;
        begin
            sgn  = f[31] ? -1.0 : 1.0;
            if (f[30:23] == 8'h00) begin
                fp32_to_real = 0.0;
            end else if (f[30:23] == 8'hFF) begin
                // We can't print true NaN/Inf as 'real' easily ; flag it big.
                fp32_to_real = sgn * 1.0e30;
            end else begin
                e    = $signed({1'b0, f[30:23]}) - 127;
                frac = 0.0;
                for (i = 0; i < 23; i = i + 1) begin
                    if (f[22-i]) frac = frac + (2.0 ** (-1.0 - i));
                end
                m     = 1.0 + frac;
                scale = (e >= 0) ? (2.0 ** e) : (1.0 / (2.0 ** (-e)));
                fp32_to_real = sgn * m * scale;
            end
        end
    endfunction

    function is_qnan;
        input [31:0] f;
        begin
            is_qnan = (f[30:23] == 8'hFF) && (f[22:0] != 23'h0);
        end
    endfunction

    //  Helpers 
    task print_root;
        input integer idx;
        input [31:0] re;
        input [31:0] im;
        begin
            if (is_qnan(re) || is_qnan(im))
                $display("  x%0d = NaN + NaN i             (hex %h, %h)",
                         idx, re, im);
            else
                $display("  x%0d = %12.6f + %12.6f i  (hex %h, %h)",
                         idx, fp32_to_real(re), fp32_to_real(im), re, im);
        end
    endtask

    task run_case;
        input [31:0] aa;
        input [31:0] bb;
        input [31:0] cc;
        input [31:0] dd;
        integer cycles;
        begin
            @(posedge clk);
            a     <= aa;
            b     <= bb;
            c     <= cc;
            d     <= dd;
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            // Wait for done with a generous timeout
            cycles = 0;
            while (done !== 1'b1 && cycles < 1000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (cycles >= 1000) begin
                $display("  *** TIMEOUT waiting for 'done' ***");
            end else begin
                $display("  (solved in %0d cycles)", cycles + 1);
            end
            @(negedge clk);   // sample mid-cycle while done is still high
            print_root(0, x0_re, x0_im);
            print_root(1, x1_re, x1_im);
            print_root(2, x2_re, x2_im);
            // Wait a few cycles before the next case
            repeat (3) @(posedge clk);
        end
    endtask

    // Stimulus
    initial begin
        $dumpfile("cubic_solver.vcd");
        $dumpvars(0, tb_cubic_solver);

        // Bring everything to a known state
        rst_n = 1'b0;
        start = 1'b0;
        a = 32'h0;  b = 32'h0;  c = 32'h0;  d = 32'h0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ----------------------------------------------------------------
        // Case 1 :  x^3 - 6x^2 + 11x - 6  =  (x-1)(x-2)(x-3)
        //   D < 0 : trigonometric branch.    Expected roots : 1, 2, 3.
        // ----------------------------------------------------------------
        $display("\n=== Case 1 : x^3 - 6x^2 + 11x - 6  (expect roots 1, 2, 3) ===");
        $display("  Inputs : a=1.0  b=-6.0  c=11.0  d=-6.0");
        run_case(32'h3F800000,   // +1.0
                 32'hC0C00000,   // -6.0
                 32'h41300000,   // +11.0
                 32'hC0C00000);  // -6.0

        // ----------------------------------------------------------------
        // Case 2 :  x^3 - 1  =  (x-1)(x^2 + x + 1)
        //   D > 0 : Cardano branch.
        //   Roots : 1 ;  -1/2 + (sqrt(3)/2) i ;  -1/2 - (sqrt(3)/2) i.
        // ----------------------------------------------------------------
        $display("\n=== Case 2 : x^3 - 1  (expect roots 1, -0.5 +/- 0.866 i) ===");
        $display("  Inputs : a=1.0  b=0.0   c=0.0   d=-1.0");
        run_case(32'h3F800000,   // +1.0
                 32'h00000000,   //  0
                 32'h00000000,   //  0
                 32'hBF800000);  // -1.0

        // ----------------------------------------------------------------
        // Case 3 :  x^3 - 3x^2 + 3x - 1  =  (x-1)^3
        //   D = 0 (exactly).   Expected : triple root at 1.
        // ----------------------------------------------------------------
        $display("\n=== Case 3 : (x-1)^3  (expect triple root 1) ===");
        $display("  Inputs : a=1.0  b=-3.0  c=3.0   d=-1.0");
        run_case(32'h3F800000,   // +1.0
                 32'hC0400000,   // -3.0
                 32'h40400000,   // +3.0
                 32'hBF800000);  // -1.0

        // ----------------------------------------------------------------
        // Case 4 :  x^3 - 4x^2 + 5x - 2  =  (x-1)^2 (x-2)
        //   D = 0 mathematically, but FP rounding usually pushes it just
        //   off zero so the solver picks Cardano or trig.  The double
        //   root will appear as a near-zero complex pair.
        // ----------------------------------------------------------------
        $display("\n=== Case 4 : (x-1)^2(x-2)  (expect roots 1, 1, 2) ===");
        $display("  Inputs : a=1.0  b=-4.0  c=5.0   d=-2.0");
        run_case(32'h3F800000,   // +1.0
                 32'hC0800000,   // -4.0
                 32'h40A00000,   // +5.0
                 32'hC0000000);  // -2.0

        // ----------------------------------------------------------------
        // Case 5 :  a = 0  -> degenerate (not a cubic).  Output all NaN.
        // ----------------------------------------------------------------
        $display("\n=== Case 5 : a = 0 degenerate  (expect all NaN) ===");
        $display("  Inputs : a=0.0  b=1.0   c=0.0   d=0.0");
        run_case(32'h00000000,   //  0
                 32'h3F800000,   // +1.0
                 32'h00000000,   //  0
                 32'h00000000);  //  0

        $display("\n=== All cases done ===\n");
        repeat (5) @(posedge clk);
        $finish;
    end

    // Hard timeout (microsecond scale)
    initial begin
        #200000;   // 200 us
        $display("*** SIM TIMEOUT *** ");
        $finish;
    end
endmodule
