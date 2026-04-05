`timescale 1ns / 1ps

module tb_ring;

    reg         clk;
    reg         rst_n;
    reg         rep;
    wire [15:0] o;

    top dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .repeat_sig        (rep),
        .led        (o)
    );
    // Clock 4ns perioddut
    initial clk = 0;
    always #2 clk = ~clk;

    localparam PATTERN_TIME = 384;
    task wait_clks;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    initial begin

        // TEST 1: Power-on reset
        // Verify all LEDs off and FSM in IDLE after reset
        $display("=== TEST 1: Power-on reset ===");
        rst_n = 0;
        rep   = 0;
        #10;

        rst_n = 1;
        #4;

        // ============================================================
        // TEST 2: FSM stays in IDLE when repeat is low
        // No LEDs should change for 20 clocks
        // ============================================================
        $display("=== TEST 2: IDLE with repeat=0 ===");
        wait_clks(20);
        #1;

        // ============================================================
        // TEST 3: Reset during CW phase (mid-operation)
        // Start pattern, let CW run partway, then assert reset
        // ============================================================
        $display("=== TEST 3: Reset during CW phase ===");
        rep = 1;
        wait_clks(5); 
        #1;

        rst_n = 0;
        #4; 
        #1;
        
        rst_n = 1;
        rep = 0;
        #8;

        // ============================================================
        // TEST 4: Reset during ACW phase
        // Start pattern, let CW finish (8 clks) + partway into ACW
        // ============================================================
        $display("=== TEST 4: Reset during ACW phase ===");
        rep = 1;
        wait_clks(10);  // 8 CW + 2 ACW clocks
        #1;
      
        rst_n = 0;
        #4;
        #1;
        
        rst_n = 1;
        rep = 0;
        #8;

        // ============================================================
        // TEST 5: Repeat asserted DURING reset (should be ignored)
        // Pattern should only start after reset is released
        // ============================================================
        $display("=== TEST 5: Repeat active during reset ===");
        rst_n = 0;
        rep   = 1;
        #12;  
        #1;
        

        rst_n = 1;         // release reset 
        wait_clks(3);
        #1;
        

        // Clean up: reset and stop
        rst_n = 0;
        rep = 0;
        #8;
        rst_n = 1;
        #8;

        // ============================================================
        // TEST 6: Single-shot (repeat deasserted mid-pattern)
        // Pattern should complete fully, then return to IDLE
        // ============================================================
        $display("=== TEST 6: Single-shot - rep goes low mid-pattern ===");
        rep = 1;
        wait_clks(24);    // 2 full cycles 
        rep = 0;           // deassert repeat
        // Let the remaining 6 cycles complete: 6 x 12 = 72 clocks
        wait_clks(80);     
        #1;
        
        // Confirm it stays in IDLE
        wait_clks(10);
        #1;
      

        // ============================================================
        // TEST 7: Back-to-back patterns (repeat stays high)
        // Pattern should auto-restart when it finishes
        // ============================================================
        $display("=== TEST 7: Back-to-back patterns (rep stays high) ===");
        rep = 1;
        wait_clks(96);     // full pattern = 96 clocks
        #1;
        // At this point the pattern just finished; since rep=1, it should restart
        // Check that LEDs are NOT stuck at 0 a few clocks later
        wait_clks(4);
        #1;
        

        // Let second pattern complete
        wait_clks(92);     // remaining clocks of 2nd pattern
        #1;
        
        // Clean up
        rst_n = 0;
        rep = 0;
        #8;
        rst_n = 1;
        #8;

        // ============================================================
        // TEST 8: Rapid repeat toggling (glitch test)
        // Toggle repeat on/off quickly before the FSM can finish
        // ============================================================
        $display("=== TEST 8: Rapid repeat toggling ===");
        rep = 1; #4;
        rep = 0; #4;
        rep = 1; #4;
        rep = 0; #4;
        rep = 1; #4;
        rep = 0;
        #8;
        #1;
        // Now do a proper reset and run a full clean pattern to confirm no damage
        rst_n = 0;
        #8;
        rst_n = 1;
        #4;
        rep = 1;
        wait_clks(96);
        rep = 0;
        wait_clks(5);
        #1;
        // ============================================================
        // TEST 9: Multiple resets in a row
        // ============================================================
        $display("=== TEST 9: Multiple resets ===");
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        #1;

        // ============================================================
        // TEST 10: Start pattern, reset, then start again
        // Verifies clean recovery after mid-pattern reset
        // ============================================================
        $display("=== TEST 10: Reset recovery - full pattern after reset ===");
        rep = 1;
        wait_clks(36);    // 3 cycles in
        rst_n = 0;        // reset mid-pattern
        #8;
        rst_n = 1;
        // rep is still high, so pattern should restart from scratch
        wait_clks(96);    // full pattern
        rep = 0;
        wait_clks(5);
        #1;
        $finish;

    end

endmodule