`timescale 1ns / 1ps

module tb_ring2;

    reg         clk;
    reg         rst_n;
    reg         rep;
    wire [15:0] o;

    ring_flasher dut  (
        .clk        (clk),
        .rst_n      (rst_n),
        .repeat_sig (rep),
        .led        (o)
    );
    // Clock 4ns period
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
        // $recordfile("waves");
        // $recordvars("depth=0", tb_ring);

        // TEST 1: Power-on reset
        $display("=== TEST 1: Power-on reset ===");
        rst_n = 0;
        rep   = 0;
        #10;

        rst_n = 1;
        #4;

        // TEST 2: FSM stays in IDLE when repeat is low
        $display("=== TEST 2: IDLE with repeat=0 ===");
        wait_clks(20);
        #1;

        // TEST 3: Reset during CW phase
        $display("=== TEST 3: Reset during CW phase ===");
        rep = 1;
        wait_clks(5); 
        #1;

        rst_n = 0;
        #4; 
        #1;
        
        rep = 0;           // deassert rep FIRST
        rst_n = 1;         // THEN release reset
        #8;

        // TEST 4: Reset during ACW phase
        $display("=== TEST 4: Reset during ACW phase ===");
        rep = 1;
        wait_clks(10);
        #1;
      
        rst_n = 0;
        #4;
        #1;
        
        rep = 0;           
        rst_n = 1;         
        #8;

        // TEST 5: Repeat asserted DURING reset
        $display("=== TEST 5: Repeat active during reset ===");
        rst_n = 0;
        rep   = 1;
        #12;  
        #1;
        
        rst_n = 1;
        wait_clks(3);
        #1;
        
        // Clean up
        rep = 0;           
        #1;
        rst_n = 0;
        #8;
        rst_n = 1;
        #8;

        // TEST 6: Single-shot (repeat deasserted mid-pattern)
        $display("=== TEST 6: Single-shot - rep goes low mid-pattern ===");
        rep = 1;
        wait_clks(24);
        rep = 0;
        wait_clks(80);     
        #1;
        
        wait_clks(10);
        #1;
      
        // TEST 7: Back-to-back patterns (repeat stays high)
        $display("=== TEST 7: Back-to-back patterns (rep stays high) ===");
        rep = 1;
        wait_clks(96);
        #1;
        wait_clks(4);
        #1;
        
        wait_clks(92);
        #1;
        
        // Clean up
        rep = 0;           
        #1;
        rst_n = 0;
        #8;
        rst_n = 1;
        #8;

        // TEST 8: Rapid repeat toggling (glitch test)
        $display("=== TEST 8: Rapid repeat toggling ===");
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
        wait_clks(96);
        rep = 0;
        wait_clks(5);
        #1;

        // TEST 9: Multiple resets in a row
        $display("=== TEST 9: Multiple resets ===");
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        rst_n = 0; #4;
        rst_n = 1; #4;
        #1;

        // TEST 10: Start pattern, reset, then start again
        $display("=== TEST 10: Reset recovery - full pattern after reset ===");
        rep = 1;
        wait_clks(36);
        rst_n = 0;
        #8;
        rst_n = 1;
        wait_clks(96);
        rep = 0;
        wait_clks(5);
        #1;
        $finish;

    end

endmodule
