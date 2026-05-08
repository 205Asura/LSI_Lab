`timescale 1ns/1ps

// Testbench sequence
//
//   Test  1 : Initial / reset state
//   Test  2 : Basic loopback           (M=0xA5, S=0x3C)
//   Test  3 : Second back-to-back      (M=0x5A, S=0xC3)
//   Test  4 : Boundary data            (0x00 <-> 0xFF, both directions)
//   Test  5 : Alternating              (0xAA <-> 0x55)
//   Test  6 : All 8 valid SS selects   (verify SS bus pattern)
//   Test  7 : SEL invalid boundary     (INPUT = 8 and INPUT = 255)
//   Test  8 : START blocked when SS = 0xFF
//   Test  9 : M_READY drops on START, returns high after
//   Test 10 : M_READY held while CNTL = START is held
//   Test  11 : LOAD during transmission ignored (master)
//   Test 12 : SEL  during transmission ignored (master)
//   Test 13 : Slave LOAD during transmission ignored
//   Test 14 : NOP doesn't change state
//   Test 15 : Walking-1 patterns       (8 transfers)
//   Test 16 : Aborted transaction      (CS forced high mid-transfer)
//   Test 17 : Loopback test            (3-round cross-feed chain)

module tb_SPI_Communication;

    reg         REFCLK;
    reg  [7:0]  M_INPUT;
    reg  [1:0]  M_CNTL;
    wire [7:0]  M_OUTPUT;
    wire        M_READY;
    reg  [7:0]  S_INPUT;
    reg         S_LOAD;
    wire [7:0]  S_OUTPUT;
    wire        S_READY;

    reg  [7:0]  prev_m_output;
    reg  [7:0]  prev_s_output;
    reg  [7:0]  prev_ss;
    integer     n;

    integer errors = 0;
    integer checks = 0;

    localparam [1:0] CNTL_NOP   = 2'b00;
    localparam [1:0] CNTL_LOAD  = 2'b01;
    localparam [1:0] CNTL_SEL   = 2'b10;
    localparam [1:0] CNTL_START = 2'b11;

    SPI_Communication dut (
        .REFCLK   (REFCLK),
        .M_INPUT  (M_INPUT),
        .M_CNTL   (M_CNTL),
        .M_OUTPUT (M_OUTPUT),
        .M_READY  (M_READY),
        .S_INPUT  (S_INPUT),
        .S_LOAD   (S_LOAD),
        .S_OUTPUT (S_OUTPUT),
        .S_READY  (S_READY)
    );

    // 100 MHz REFCLK
    initial REFCLK = 0;
    always  #5 REFCLK = ~REFCLK;

    // Helper tasks 
    // Issue a 1-cycle master command then return to NOP.
    task master_cmd;
        input [1:0] cntl;
        input [7:0] data;
        begin
            @(posedge REFCLK);
            M_INPUT <= data;
            M_CNTL  <= cntl;
            @(posedge REFCLK);
            M_CNTL  <= CNTL_NOP;
        end
    endtask

    task slave_load;
        input [7:0] data;
        begin
            @(posedge REFCLK);
            S_INPUT <= data;
            S_LOAD  <= 1'b1;
            #10;
            S_LOAD  <= 1'b0;
        end
    endtask

    // Assert START, wait for M_READY to go LOW, release to NOP, wait for HIGH.
    task master_start_and_wait;
        integer timeout;
        begin
            @(posedge REFCLK);
            M_CNTL <= CNTL_START;

            timeout = 0;
            while ((M_READY !== 1'b0) && (timeout < 40)) begin
                @(posedge REFCLK);
                timeout = timeout + 1;
            end

            if (M_READY !== 1'b0) begin
                $display("  FAIL : START timeout (M_READY not low)");
                errors = errors + 1;
                M_CNTL <= CNTL_NOP;
            end else begin
                M_CNTL <= CNTL_NOP;

                timeout = 0;
                while ((M_READY !== 1'b1) && (timeout < 80)) begin
                    @(posedge REFCLK);
                    timeout = timeout + 1;
                end

                if (M_READY !== 1'b1) begin
                    $display("  FAIL : DONE timeout (M_READY not high)");
                    errors = errors + 1;
                end
            end
        end
    endtask

    // Verify that START is ignored when no slave is selected (SS = 0xFF).
    task master_start_expect_no_start;
        integer i;
        reg started;
        begin
            started = 1'b0;

            @(posedge REFCLK);
            M_CNTL <= CNTL_START;

            for (i = 0; i < 20; i = i + 1) begin
                @(posedge REFCLK);
                if (M_READY === 1'b0)
                    started = 1'b1;
            end

            M_CNTL <= CNTL_NOP;

            checks = checks + 1;
            if (started) begin
                $display("  FAIL : Invalid SS still allowed START");
                errors = errors + 1;
            end else begin
                $display("  PASS : Invalid SS blocked START");
            end
        end
    endtask

    // Counting check tasks
    task check;
        input [7:0]   got;
        input [7:0]   expected;
        input [255:0] label;
        begin
            checks = checks + 1;
            if (got === expected)
                $display("  PASS : %0s got 0x%02h", label, got);
            else begin
                $display("  FAIL : %0s got 0x%02h, expected 0x%02h",
                         label, got, expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_eq;
        input [7:0]   got;
        input [7:0]   expected;
        input [255:0] label;
        begin
            checks = checks + 1;
            if (got === expected)
                $display("  PASS : %0s = 0x%02h", label, got);
            else begin
                $display("  FAIL : %0s = 0x%02h, expected 0x%02h",
                         label, got, expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_bit;
        input         got;
        input         expected;
        input [255:0] label;
        begin
            checks = checks + 1;
            if (got === expected)
                $display("  PASS : %0s = %b", label, got);
            else begin
                $display("  FAIL : %0s got %b, expected %b",
                         label, got, expected);
                errors = errors + 1;
            end
        end
    endtask

    // Complete a master<->slave byte exchange and check both received values.
    task do_swap;
        input [7:0] m_data;
        input [7:0] s_data;
        input [3:0] slave_idx;
        begin
            master_cmd(CNTL_SEL, 8'd8);                
            slave_load(s_data);                          
            master_cmd(CNTL_LOAD, m_data);
            master_cmd(CNTL_SEL, {4'b0000, slave_idx});
            master_start_and_wait;
            #10;
            check(M_OUTPUT, s_data, "Master RX");
            check(S_OUTPUT, m_data, "Slave  RX");
        end
    endtask


    //==========================================================================
    // MAIN TEST SEQUENCE
    //==========================================================================

    initial begin
        $dumpfile("spi_tb.vcd");
        $dumpvars(0, tb_SPI_Communication);

        M_INPUT = 8'h00;
        M_CNTL  = CNTL_NOP;
        S_INPUT = 8'h00;
        S_LOAD  = 1'b0;

        #25;

        $display("");
        $display(" Test 1 : Initial / reset state");
        check_bit(M_READY, 1'b1, "M_READY at reset");
        check_bit(S_READY, 1'b1, "S_READY at reset");
        check_eq(dut.ss_w, 8'hFF, "SS bus at reset (no slave)");

        #20;

        $display("");
        $display(" Test 2 : Basic loopback (M=0xA5, S=0x3C) ");
        do_swap(8'hA5, 8'h3C, 4'd0);

        #30;

        $display("");
        $display(" Test 3 : Second transfer (M=0x5A, S=0xC3) ");
        do_swap(8'h5A, 8'hC3, 4'd0);

        #30;

        $display("");
        $display(" Test 4a : 0x00 <-> 0xFF ");
        do_swap(8'h00, 8'hFF, 4'd0);

        #30;

        $display("");
        $display(" Test 4b : 0xFF <-> 0x00 ");
        do_swap(8'hFF, 8'h00, 4'd0);

        #30;

        $display("");
        $display(" Test 5 : Alternating (M=0xAA, S=0x55) ");
        do_swap(8'hAA, 8'h55, 4'd0);

        #30;

        $display("");
        $display(" Test 6 : All 8 valid SS selects ");
        for (n = 0; n < 8; n = n + 1) begin
            master_cmd(CNTL_SEL, n[7:0]);
            #5;
            checks = checks + 1;
            if (dut.ss_w === ~(8'h01 << n[2:0]))
                $display("  PASS : SS for slave %0d = 0x%02h", n, dut.ss_w);
            else begin
                $display("  FAIL : SS for slave %0d = 0x%02h, expected 0x%02h",
                         n, dut.ss_w, ~(8'h01 << n[2:0]));
                errors = errors + 1;
            end
        end

        #20;

        $display("");
        $display(" Test 7a : SEL boundary INPUT=8 -> SS=0xFF ");
        master_cmd(CNTL_SEL, 8'd0);
        #5;
        check_eq(dut.ss_w, 8'hFE, "SS before invalid SEL");
        master_cmd(CNTL_SEL, 8'd8);
        #5;
        check_eq(dut.ss_w, 8'hFF, "SS after INPUT=8");

        $display("");
        $display(" Test 7b : SEL maximum invalid INPUT=255 ");
        master_cmd(CNTL_SEL, 8'd0);
        #5;
        check_eq(dut.ss_w, 8'hFE, "SS before invalid SEL");
        master_cmd(CNTL_SEL, 8'd255);
        #5;
        check_eq(dut.ss_w, 8'hFF, "SS after INPUT=255");

        #20;

        $display("");
        $display(" Test 8 : START blocked with SS=0xFF ");
        prev_m_output = M_OUTPUT;
        prev_s_output = S_OUTPUT;
        check_eq(dut.ss_w, 8'hFF, "SS bus");
        master_start_expect_no_start;
        #10;
        check(M_OUTPUT, prev_m_output, "Master RX unchanged");
        check(S_OUTPUT, prev_s_output, "Slave  RX unchanged");

        #20;

        // Test 9: SS=8'hFF here (from Test 8), so slave_load is safe without extra deselect.
        $display("");
        $display(" Test 9 : M_READY drops on START, returns high ");
        slave_load(8'h11);
        master_cmd(CNTL_LOAD, 8'h22);
        master_cmd(CNTL_SEL,  8'd0);
        check_bit(M_READY, 1'b1, "M_READY before START");

        @(posedge REFCLK);
        M_CNTL <= CNTL_START;
        @(posedge REFCLK);
        M_CNTL <= CNTL_NOP;
        @(posedge REFCLK);
        check_bit(M_READY, 1'b0, "M_READY LOW during transfer");

        while (M_READY !== 1'b1) @(posedge REFCLK);
        check_bit(M_READY, 1'b1, "M_READY HIGH after transfer");
        check(M_OUTPUT, 8'h11, "Master RX");
        check(S_OUTPUT, 8'h22, "Slave  RX");

        #30;

        // Tests 10-14: each begins with a deselect so that slave_load finds S_READY=1 
        $display("");
        $display(" Test 10 : M_READY held while CNTL=START is held ");
        master_cmd(CNTL_SEL, 8'd8);     
        slave_load(8'h99);
        master_cmd(CNTL_LOAD, 8'h66);
        master_cmd(CNTL_SEL,  8'd0);

        @(posedge REFCLK);
        M_CNTL <= CNTL_START;

        repeat (40) @(posedge REFCLK);
        check_bit(M_READY, 1'b0, "M_READY LOW (CNTL=START held)");

        M_CNTL <= CNTL_NOP;
        @(posedge REFCLK);
        @(posedge REFCLK);
        check_bit(M_READY, 1'b1, "M_READY HIGH after CNTL released");
        check(M_OUTPUT, 8'h99, "Master RX (held-START transfer)");
        check(S_OUTPUT, 8'h66, "Slave  RX (held-START transfer)");

        #30;

        $display("");
        $display(" Test 11 : LOAD during transmission ignored (master) ");
        master_cmd(CNTL_SEL, 8'd8);     
        slave_load(8'hF0);
        master_cmd(CNTL_LOAD, 8'h0F);
        master_cmd(CNTL_SEL,  8'd0);

        @(posedge REFCLK);
        M_CNTL <= CNTL_START;
        @(posedge REFCLK);
        M_CNTL <= CNTL_NOP;

        repeat (6) @(posedge REFCLK);

        // Attempt mid-transfer LOAD 
        M_INPUT <= 8'hCC;
        M_CNTL  <= CNTL_LOAD;
        @(posedge REFCLK);
        M_CNTL  <= CNTL_NOP;

        while (M_READY !== 1'b1) @(posedge REFCLK);
        check(S_OUTPUT, 8'h0F, "Slave  RX (orig 0x0F, not 0xCC)");
        check(M_OUTPUT, 8'hF0, "Master RX");

        #30;

        $display("");
        $display(" Test 12 : SEL during transmission ignored ");
        master_cmd(CNTL_SEL, 8'd8);    
        slave_load(8'h11);
        master_cmd(CNTL_LOAD, 8'h22);
        master_cmd(CNTL_SEL,  8'd0);   
        #1 prev_ss = dut.ss_w;
        check_eq(prev_ss, 8'hFE, "SS before transfer");

        @(posedge REFCLK);
        M_CNTL <= CNTL_START;
        @(posedge REFCLK);
        M_CNTL <= CNTL_NOP;

        repeat (6) @(posedge REFCLK);
        check_eq(dut.ss_w, 8'hFE, "SS unchanged mid-transfer");

        // Attempt to change slave selection mid transfer
        M_INPUT <= 8'd7;
        M_CNTL  <= CNTL_SEL;
        @(posedge REFCLK); 
        M_CNTL  <= CNTL_NOP;

        repeat (3) @(posedge REFCLK);
        check_eq(dut.ss_w, 8'hFE, "SS unchanged after SEL attempt");

        while (M_READY !== 1'b1) @(posedge REFCLK);
        check(M_OUTPUT, 8'h11, "Master RX (SEL was ignored)");

        #30;

        $display("");
        $display(" Test 13 : Slave LOAD during transmission ignored ---");
        master_cmd(CNTL_SEL, 8'd8);     
        slave_load(8'h33);              
        master_cmd(CNTL_LOAD, 8'h44);
        master_cmd(CNTL_SEL,  8'd0);

        @(posedge REFCLK);
        M_CNTL <= CNTL_START;
        @(posedge REFCLK);
        M_CNTL <= CNTL_NOP;

        repeat (6) @(posedge REFCLK);
        check_bit(S_READY, 1'b0, "S_READY LOW during transfer");

        // Attempt slave LOAD with new data 
        slave_load(8'h99);

        while (M_READY !== 1'b1) @(posedge REFCLK);
        check(M_OUTPUT, 8'h33, "Master RX (orig 0x33, not 0x99)");
        check(S_OUTPUT, 8'h44, "Slave  RX");

        #30;

        $display("");
        $display(" Test 14 : NOP doesn't change state ");
        master_cmd(CNTL_SEL, 8'd8);
        @(posedge REFCLK);     
        slave_load(8'h77);
        master_cmd(CNTL_LOAD, 8'h88);
        master_cmd(CNTL_SEL,  8'd5);
        #1 prev_ss = dut.ss_w;
        check_eq(prev_ss, 8'hDF, "SS for slave 5");
        repeat (5) master_cmd(CNTL_NOP, 8'hAA);
        check_eq(dut.ss_w, prev_ss, "SS preserved through NOPs");
        check_bit(M_READY, 1'b1, "M_READY still HIGH after NOPs");

        // Re-select slave 0 and transfer to confirm state
        master_cmd(CNTL_SEL, 8'd0);
        master_start_and_wait;
        #10;
        check(M_OUTPUT, 8'h77, "Master RX after NOP test");
        check(S_OUTPUT, 8'h88, "Slave  RX after NOP test");

        #30;

        $display("");
        $display(" Test 15 : Walking-1 patterns (8 transfers) ");
        for (n = 0; n < 8; n = n + 1) begin
            do_swap(8'h01 << n, 8'h80 >> n, 4'd0);
        end

        #30;

        // Test 16 : Aborted transaction
 
        $display("");
        $display(" Test 16 : Aborted transaction ");

        // Do a complete reference transfer to establish a known S_OUTPUT.
        do_swap(8'hCA, 8'hFE, 4'd0);
        #10;
        prev_s_output = S_OUTPUT;           

        master_cmd(CNTL_SEL, 8'd8);       
        slave_load(8'hBE);                  
        master_cmd(CNTL_LOAD, 8'hEF);
        master_cmd(CNTL_SEL,  8'd0);      

        // Start the transfer
        @(posedge REFCLK);
        M_CNTL <= CNTL_START;
        @(posedge REFCLK);
        M_CNTL <= CNTL_NOP;

        repeat(8) @(posedge REFCLK);
        check_bit(S_READY, 1'b0, "S_READY LOW before abort (mid-transfer)");

        // Abort: force CS HIGH on the slave

        force dut.u_slave.CS = 1'b1;
        repeat(4) @(posedge REFCLK);
        check_bit(S_READY, 1'b1, "S_READY HIGH immediately after abort");
        check(S_OUTPUT, prev_s_output, "S_OUTPUT unchanged after aborted transfer");

        while (M_READY !== 1'b1) @(posedge REFCLK);

        release dut.u_slave.CS;
        master_cmd(CNTL_SEL, 8'd8);        

        #10;
        $display("  Verify normal operation after abort:");
        do_swap(8'hA1, 8'hB2, 4'd0);
        #10;
        check(M_OUTPUT, 8'hB2, "Master RX post-abort");
        check(S_OUTPUT, 8'hA1, "Slave  RX post-abort");

        #30;

        // Test 17 : Loopback test
        $display("");
        $display("--- Test 17 : Loopback test (3-round cross-feed) ---");

        do_swap(8'hDE, 8'hAD, 4'd0);
        #10;
        check(M_OUTPUT, 8'hAD, "Loopback R1: Master RX");
        check(S_OUTPUT, 8'hDE, "Loopback R1: Slave  RX");

        do_swap(M_OUTPUT, S_OUTPUT, 4'd0);
        #10;
        check(M_OUTPUT, 8'hDE, "Loopback R2: Master RX (cross-echo)");
        check(S_OUTPUT, 8'hAD, "Loopback R2: Slave  RX (cross-echo)");

        do_swap(M_OUTPUT, S_OUTPUT, 4'd0);
        #10;
        check(M_OUTPUT, 8'hAD, "Loopback R3: Master RX (stable loop)");
        check(S_OUTPUT, 8'hDE, "Loopback R3: Slave  RX (stable loop)");

        #30;

        // ══════════════════════════════════════════════════════════════════════
        // SUMMARY
        // ══════════════════════════════════════════════════════════════════════
        $display("");
        $display("============================================");
        $display(" Test summary: %0d checks, %0d failure(s)", checks, errors);
        if (errors == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** %0d TEST(S) FAILED ***", errors);
        $display("============================================");

        $finish;
    end

    initial begin
        $recordfile("waves");
        $recordvars("depth=0", tb_SPI_Communication);
    end

endmodule