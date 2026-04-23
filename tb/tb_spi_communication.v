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

    reg  [7:0]  prev_m_output;
    reg  [7:0]  prev_s_output;

    integer errors = 0;

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

        // Helper: full transaction -> wait for M_READY to return high (with timeout)
    task master_start_and_wait;
        integer timeout;
        begin
            @(posedge REFCLK);
            #1;
            M_CNTL = CNTL_START;

            timeout = 0;
            while ((M_READY !== 1'b0) && (timeout < 40)) begin
                @(posedge REFCLK);
                timeout = timeout + 1;
            end

            if (M_READY !== 1'b0) begin
                $display("  FAIL : START timeout (M_READY never went low)");
                errors = errors + 1;
                M_CNTL = CNTL_NOP;
            end else begin
                #1;
                M_CNTL = CNTL_NOP;

                timeout = 0;
                while ((M_READY !== 1'b1) && (timeout < 80)) begin
                    @(posedge REFCLK);
                    timeout = timeout + 1;
                end

                if (M_READY !== 1'b1) begin
                    $display("  FAIL : DONE timeout (M_READY never returned high)");
                    errors = errors + 1;
                end
            end
        end
    endtask

    // Helper: START should be ignored when no slave is selected (SS = 8'hFF)
    task master_start_expect_no_start;
        integer i;
        reg started;
        begin
            started = 1'b0;

            @(posedge REFCLK);
            #1;
            M_CNTL = CNTL_START;

            for (i = 0; i < 20; i = i + 1) begin
                @(posedge REFCLK);
                if (M_READY === 1'b0)
                    started = 1'b1;
            end

            #1;
            M_CNTL = CNTL_NOP;

            if (started) begin
                $display("  FAIL : Invalid SS still allowed START");
                errors = errors + 1;
            end else begin
                $display("  PASS : Invalid SS blocked START");
            end
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

        prev_m_output = M_OUTPUT;
        prev_s_output = S_OUTPUT;

        master_cmd(CNTL_SEL, 8'd9);
        #20;
        check(dut.ss_w, 8'hFF, "SS bus");

        // With invalid SS, START must not launch any transfer.
        master_start_expect_no_start;

        #10;
        check(M_OUTPUT, prev_m_output, "Master RX unchanged");
        check(S_OUTPUT, prev_s_output, "Slave  RX unchanged");

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

    initial begin
    $recordfile ("waves");
    $recordvars ("depth=0", tb_SPI_Communication);
    end


endmodule
