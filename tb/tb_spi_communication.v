`timescale 1ns/1ps

//=============================================================================
// Testbench for SPI_Communication
//   - Test A: full-duplex exchange between Master and Slave
//   - Test B: second back-to-back transfer (different data)
//   - Test C: "out of range" SS selection (INPUT >= 8)
//=============================================================================
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

    integer errors = 0;

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

    // Helper: issue a 1-cycle master command and return to NOP
    task master_cmd(input [1:0] cntl, input [7:0] data);
        begin
            @(posedge REFCLK);
            #1;
            M_INPUT = data;
            M_CNTL  = cntl;
            @(posedge REFCLK);
            #1;
            M_CNTL  = CNTL_NOP;
        end
    endtask

    // Helper: load a byte into the slave's tx shifter
    task slave_load(input [7:0] data);
        begin
            #1;
            S_INPUT = data;
            #1;
            S_LOAD  = 1'b1;
            #10;
            S_LOAD  = 1'b0;
        end
    endtask

    // Helper: full transaction -> wait for M_READY to return high
    task master_start_and_wait;
        begin
            @(posedge REFCLK);
            #1;
            M_CNTL = 2'b11;
            @(negedge M_READY);    // transmission started
            #1;
            M_CNTL = 2'b00;        // drop CNTL so DONE_WAIT can exit
            @(posedge M_READY);    // transmission complete
        end
    endtask

    // Helper: self-check
    task check(input [7:0] got, input [7:0] expected, input [255:0] label);
        begin
            if (got === expected)
                $display("  PASS : %0s got 0x%02h", label, got);
            else begin
                $display("  FAIL : %0s got 0x%02h, expected 0x%02h",
                         label, got, expected);
                errors = errors + 1;
            end
        end
    endtask

    localparam [1:0] CNTL_NOP   = 2'b00;
    localparam [1:0] CNTL_LOAD  = 2'b01;
    localparam [1:0] CNTL_SEL   = 2'b10;
    localparam [1:0] CNTL_START = 2'b11;

    initial begin
        $dumpfile("spi_tb.vcd");
        $dumpvars(0, tb_SPI_Communication);

        M_INPUT = 8'h00;
        M_CNTL  = CNTL_NOP;
        S_INPUT = 8'h00;
        S_LOAD  = 1'b0;

        #25;

        //---------------------------------------------------------------------
        // Test A : Master 0xA5, Slave 0x3C  (full-duplex swap)
        //---------------------------------------------------------------------
        $display("--- Test A : Master=0xA5, Slave=0x3C ---");

        slave_load(8'h3C);
        master_cmd(CNTL_LOAD, 8'hA5);
        master_cmd(CNTL_SEL,  8'd0);          // select slave 0
        master_start_and_wait;

        #10;
        check(M_OUTPUT, 8'h3C, "Master RX");
        check(S_OUTPUT, 8'hA5, "Slave  RX");

        #30;

        //---------------------------------------------------------------------
        // Test B : second transfer, different data (0x5A <-> 0xC3)
        //---------------------------------------------------------------------
        $display("--- Test B : Master=0x5A, Slave=0xC3 ---");

        slave_load(8'hC3);
        master_cmd(CNTL_LOAD, 8'h5A);
        // slave 0 already selected from Test A; reselect for clarity
        master_cmd(CNTL_SEL,  8'd0);
        master_start_and_wait;

        #10;
        check(M_OUTPUT, 8'hC3, "Master RX");
        check(S_OUTPUT, 8'h5A, "Slave  RX");

        #30;

        //---------------------------------------------------------------------
        // Test C : INPUT out of range -> SS should be 8'hFF
        //---------------------------------------------------------------------
        $display("--- Test C : SS out-of-range select (INPUT=9) ---");
        master_cmd(CNTL_SEL, 8'd9);
        #20;
        check(dut.ss_w, 8'hFF, "SS bus");

        #30;

        //---------------------------------------------------------------------
        $display("----------------------------------------");
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TEST(S) FAILED", errors);
        $display("----------------------------------------");

        $finish;
    end

endmodule
