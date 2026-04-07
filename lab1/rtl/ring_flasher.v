module ring_flasher 
#(
    parameter INTERVAL = 16'd1 // cycles between each toggle
)
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        repeat_sig,
    output reg  [15:0] led
);

    localparam IDLE = 2'd0,
               CW   = 2'd1,
               ACW  = 2'd2;

    reg [1:0] state;
    reg [3:0] step_count;
    reg [3:0] toggle_idx;
    wire toggle;

    reg [15:0] timer;
    reg timer_run;


    // Timer
    assign toggle = (timer == 16'd1);
    always @(posedge clk) begin
        if (!rst_n) begin
            timer <= INTERVAL;
        end
        else if (timer_run) begin
            if (timer == 16'd1)
                timer <= INTERVAL;
            else
                timer <= timer - 1;
        end
        else begin
            timer <= INTERVAL;
        end
    end

    // FSM logic
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= IDLE;
            led         <= 16'b0;
            step_count  <= 4'd0;
            toggle_idx  <= 4'd0;
            timer_run   <= 1'b0;
        end
        else begin 
            case (state)

                IDLE: begin
                    if (repeat_sig && INTERVAL >= 16'd1) begin
                        timer_run   <= 1'b1;
                        state       <= CW;
                        led         <= 16'b1;
                        toggle_idx  <= 4'd1;
                        step_count  <= 4'd1;
                    end
                end


                CW: if (toggle) begin
                    led[toggle_idx] <= ~led[toggle_idx];

                    if (step_count == 4'd7) begin
                        step_count <= 4'd0;
                        state      <= ACW;
                    end
                    else begin
                        toggle_idx <= toggle_idx + 1;
                        step_count <= step_count + 1;
                    end
                end

                ACW: if (toggle) begin
                    if (step_count < 4'd4) begin
                        led[toggle_idx] <= ~led[toggle_idx];
                        step_count <= step_count + 1;
                        if (step_count < 4'd3)
                            toggle_idx <= toggle_idx - 1;
                    end
                    else if (step_count == 4'd4) begin
                        if (led != 16'd0 || repeat_sig) begin
                            state <= CW;
                            led[toggle_idx] <= ~led[toggle_idx];
                            toggle_idx <= toggle_idx + 1;
                            step_count <= 4'd1;
                        end
                        else begin
                            state <= IDLE;
                            timer_run <= 1'b0;
                        end
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
