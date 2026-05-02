`timescale 1ps/1ps

// SPI Communication Module - 1-register (circular shift) version
// Design choices:
//   - Bit order : MSB first
//   - CPOL      : 0  (SCLK idle LOW)
//   - CPHA      : 0  (sample on SCLK rising edge, shift on falling edge)
//   - SS / CS   : active LOW  (spec example: INPUT=3 -> SS=8'b1111_0111)
//   - SCLK rate : REFCLK / 2  (1 byte = 16 REFCLK cycles, 8 SCLK cycles)
//   - All non-SPI-transmission logic is posedge-triggered on REFCLK.

module SPI_Communication_1reg (
    input  wire        REFCLK,
    // Master control
    input  wire [7:0]  M_INPUT,
    input  wire [1:0]  M_CNTL,
    output wire [7:0]  M_OUTPUT,
    output wire        M_READY,
    // Slave control
    input  wire [7:0]  S_INPUT,
    input  wire        S_LOAD,
    output wire [7:0]  S_OUTPUT,
    output wire        S_READY
);

    // Internal SPI bus
    wire        mosi_w;
    wire        miso_w;
    wire        sclk_w;
    wire [7:0]  ss_w;

    SPI_Master u_master (
        .REFCLK (REFCLK),
        .INPUT  (M_INPUT),
        .CNTL   (M_CNTL),
        .OUTPUT (M_OUTPUT),
        .READY  (M_READY),
        .MOSI   (mosi_w),
        .MISO   (miso_w),
        .SCLK   (sclk_w),
        .SS     (ss_w)
    );

    SPI_Slave u_slave (
        .INPUT  (S_INPUT),
        .LOAD   (S_LOAD),
        .OUTPUT (S_OUTPUT),
        .READY  (S_READY),
        .MOSI   (mosi_w),
        .MISO   (miso_w),
        .SCLK   (sclk_w),
        .CS     (ss_w[0])
    );

endmodule


// SPI Master (1-register, circular-shift)
module SPI_Master (
    input  wire        REFCLK,
    input  wire [7:0]  INPUT,
    input  wire [1:0]  CNTL,
    output reg  [7:0]  OUTPUT,
    output wire        READY,
    output wire        MOSI,
    input  wire        MISO,
    output wire        SCLK,
    output reg  [7:0]  SS
);

    // CNTL
    localparam [1:0] CNTL_NOP   = 2'b00;
    localparam [1:0] CNTL_LOAD  = 2'b01;
    localparam [1:0] CNTL_SEL   = 2'b10;
    localparam [1:0] CNTL_START = 2'b11;

    // FSM states
    localparam [1:0] S_IDLE      = 2'b00;
    localparam [1:0] S_TRANSMIT  = 2'b01;
    localparam [1:0] S_DONE_WAIT = 2'b10;

    reg [1:0] state;
    reg [7:0] data_reg;
    reg [3:0] bit_count;
    reg       sclk_reg = 0;
    reg       miso_sample;

    // outputs
    assign MOSI  = data_reg[7];           // always MSB (circular shift)
    assign SCLK  = sclk_reg;
    assign READY = (state == S_IDLE);     // low during TRANSMIT and DONE_WAIT

    initial begin
        state     = S_IDLE;
        data_reg  = 8'h00;
        OUTPUT    = 8'h00;
        SS        = 8'hFF;
        bit_count = 4'd0;
        sclk_reg  = 1'b0;
    end

    always @(posedge REFCLK) begin
        case (state)
            S_IDLE: begin
                case (CNTL)
                    CNTL_NOP: ;

                    CNTL_LOAD: begin
                        data_reg <= INPUT;
                    end

                    CNTL_SEL: begin
                        if (INPUT < 8'd8)
                            SS <= ~(8'h01 << INPUT[2:0]);
                        else
                            SS <= 8'hFF;
                    end

                    CNTL_START: begin
                        if (SS != 8'hFF) begin
                            state     <= S_TRANSMIT;
                            bit_count <= 4'd0;
                            sclk_reg  <= 1'b0;
                        end
                    end
                endcase
            end

            S_TRANSMIT: begin
                sclk_reg <= ~sclk_reg;
            
                if (!sclk_reg) begin
                    miso_sample <= MISO;
                end

                else if (sclk_reg) begin
                    data_reg <= {data_reg[6:0], miso_sample};
                    if (bit_count == 4'd7) begin
                        OUTPUT <= {data_reg[6:0], miso_sample};
                        bit_count <= 4'd0;
                        state <= S_DONE_WAIT;
                    end
                    else
                        bit_count <= bit_count + 1;
                end
            end

            S_DONE_WAIT: begin
                if (CNTL != CNTL_START) begin
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end

    

endmodule


// SPI Slave (1-register, circular-shift)
module SPI_Slave (
    input  wire [7:0]  INPUT,
    input  wire        LOAD,
    output reg  [7:0]  OUTPUT,
    output wire        READY,
    input  wire        MOSI,
    output wire        MISO,
    input  wire        SCLK,
    input  wire        CS
);

    reg [7:0] data_reg;
    reg [3:0] bit_count;
    reg       transmitting;
    reg       mosi_sample;

    // outputs
    assign MISO  = data_reg[7];           // always MSB (circular shift)
    assign READY = !transmitting;

    initial begin
        data_reg     = 8'h00;
        OUTPUT       = 8'h00;
        bit_count    = 4'd0;
        transmitting = 1'b0;
        mosi_sample = 1'b0;
    end


    always @(posedge LOAD) begin
        if (!transmitting) begin
            data_reg <= INPUT;
        end
    end
    
    always @(posedge SCLK) begin
        if (!CS) begin
            mosi_sample <= MOSI;
        end
    end

    always @(negedge SCLK or posedge CS) begin
        if (CS) begin
            bit_count    = 4'd0;
            transmitting = 1'b0;
        end
        else
        if (!CS) begin
            data_reg <= {data_reg[6:0], mosi_sample};
            if (bit_count < 4'd7) begin
                bit_count <= bit_count + 1;
                if (!transmitting) 
                    transmitting <= 1'b1;
            end
            else
            if (bit_count == 4'd7) begin
                OUTPUT <= {data_reg[6:0], mosi_sample};
                bit_count <= 4'd0;
                transmitting <= 1'b0;
            end
        end
    end

endmodule