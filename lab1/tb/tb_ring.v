`timescale 1ns / 1ps

module tb_ring;

    reg         clk;
    reg         rst_n;
    reg         rep;
    wire [15:0] o;

    localparam INTERVAL = 3;

    ring_flasher dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .repeat_sig (rep),
        .led        (o)
    );

    initial clk = 0;
    always #2 clk = ~clk;

    localparam CLKS_PER_CYCLE = 12 * INTERVAL;
    localparam FULL_PATTERN   = 8 * CLKS_PER_CYCLE;

    task wait_clks;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    initial begin
        $recordfile("waves");
        $recordvars("depth=0", tb_ring);

        // TEST 1: Power-on reset
        $display("=== TEST 1: Power-on reset ===");
        rst_n = 0;
        rep   = 0;
        #10;
        rst_n = 1;
        #4;

        // TEST 2: IDLE with repeat=0
        $display("=== TEST 2: IDLE with repeat=0 ===");
        wait_clks(20);
        #1;

        // TEST 3: Reset during CW phase
        $display("=== TEST 3: Reset during CW phase ===");
        rep = 1;
        wait_clks(5 * INTERVAL);
        #1;

        rst_n = 0;
        #4;
        #1;

        rst_n = 1;
        rep = 0;
        #8;

        // TEST 4: Reset during ACW phase
        $display("=== TEST 4: Reset during ACW phase ===");
        rep = 1;
        wait_clks(10 * INTERVAL);
        #1;

        rst_n = 0;
        #4;
        #1;

        rst_n = 1;
        rep = 0;
        #8;

        // TEST 5: Repeat asserted DURING reset
        $display("=== TEST 5: Repeat active during reset ===");
        rst_n = 0;
        rep   = 1;
        #12;
        #1;

        rst_n = 1;
        wait_clks(3 * INTERVAL);
        #1;

        rst_n = 0;
        rep = 0;
        #8;
        rst_n = 1;
        #8;

        // TEST 6: Single-shot
        $display("=== TEST 6: Rep goes low mid-pattern ===");
        rep = 1;
        wait_clks(2 * CLKS_PER_CYCLE);
        rep = 0;
        wait_clks(FULL_PATTERN);
        #1;

        wait_clks(10);
        #1;

        // TEST 7: Back-to-back patterns
        $display("=== TEST 7: Back-to-back patterns (rep stays high) ===");
        rep = 1;
        wait_clks(FULL_PATTERN);
        #1;
        wait_clks(4 * INTERVAL);
        #1;

        wait_clks(FULL_PATTERN);
        #1;

        rst_n = 0;
        rep = 0;
        #8;
        rst_n = 1;
        #8;

        // TEST 8: Repeat toggling
        $display("=== TEST 8: Repeat toggling ===");
        rep = 1; #4;
        rep = 0; #4;
        rep = 1; #4;
        rep = 0; #4;
        rep = 1; #4;
        rep = 0;
        #8;
        #1;
        rst_n = 0;
        #8;
        rst_n = 1;
        #4;
        rep = 1;
        wait_clks(FULL_PATTERN);
        rep = 0;
        wait_clks(5 * INTERVAL);
        #1;

        // TEST 9: Multiple resets
        $display("=== TEST 9: Multiple resets ===");
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        #1;

        // TEST 10: Reset recovery
        $display("=== TEST 10: Reset recovery - full pattern after reset ===");
        rep = 1;
        wait_clks(3 * CLKS_PER_CYCLE);
        rst_n = 0;
        #5;
        rst_n = 1;
        wait_clks(FULL_PATTERN + FULL_PATTERN);
        rep = 0;
        wait_clks(5 * INTERVAL);
        #1;
        $stop;

    end

endmodule
