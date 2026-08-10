`timescale 1ns / 1ps
// =====================================================================
//  conv_engine.v - Pipelined 3x3 Convolution Engine for Timing Closure
// =====================================================================

module conv_engine #(
    parameter INPUT_CH     = 1,     // number of input channels
    parameter OUTPUT_CH    = 8,     // number of output filters
    parameter INPUT_H      = 28,    // input image height
    parameter INPUT_W      = 28,    // input image width
    parameter OUTPUT_H     = 26,    // output height  (= INPUT_H - 2)
    parameter OUTPUT_W     = 26,    // output width   (= INPUT_W - 2)
    parameter WEIGHT_DEPTH = 72,    // OUTPUT_CH * INPUT_CH * 9
    parameter WEIGHT_AW    = 7,     // address width for weight ROM
    parameter SHIFT        = 4,     // requantization shift
    parameter IMG_AW       = 10,    // address width for input RAM
    parameter OUT_AW       = 13     // address width for output RAM
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    // Input RAM read port (1-cycle registered read)
    output reg  [IMG_AW-1:0]     img_addr,
    input  wire [7:0]            img_data,

    // Weight ROM read port (1-cycle registered read)
    output reg  [WEIGHT_AW-1:0]  w_addr,
    input  wire signed [7:0]     w_data,

    // Output RAM write port
    output reg                   co_we,
    output reg  [OUT_AW-1:0]     co_addr,
    output reg  [7:0]            co_data
);

    // -----------------------------------------------------------------
    // States
    // -----------------------------------------------------------------
    localparam S_IDLE         = 4'd0,
               S_FETCH        = 4'd1,   
               S_FETCH_WAIT   = 4'd2,   
               S_SHIFT        = 4'd3,   
               S_CHECK        = 4'd4,   
               S_WLOAD        = 4'd5,   
               S_WLOAD_WAIT   = 4'd6,   
               S_WCAP_PIPE    = 4'd7,   // Pipelining stage for MUX selection
               S_WCAP         = 4'd8,   // DSP MAC stage
               S_NEXT_CH      = 4'd9,   
               S_RELU         = 4'd10,  
               S_NEXT_FILTER  = 4'd11,  
               S_NEXT_PIX     = 4'd12,  
               S_DONE         = 4'd13;

    (* dont_touch = "true" *) reg [3:0] state;

    // -----------------------------------------------------------------
    // Counters
    // -----------------------------------------------------------------
    reg [5:0] in_y;        
    reg [5:0] in_x;        
    reg [4:0] in_c;        

    reg [5:0] oy, ox;      
    reg [4:0] f;           
    reg [4:0] c;           
    reg [3:0] k;           

    // -----------------------------------------------------------------
    // DSP Pipeline Registers
    // -----------------------------------------------------------------
    (* use_dsp = "yes" *) reg signed [31:0] acc;
    (* dont_touch = "true" *) reg signed [8:0] win_sel_reg;
    (* dont_touch = "true" *) reg signed [7:0] w_data_reg;

    // Line buffer: INPUT_CH channels * 3 rows * INPUT_W cols
    reg [7:0] lb [0:INPUT_CH-1][0:2][0:INPUT_W-1];

    // Modulo row index evaluation
    wire [5:0] in_y_mod3  = in_y % 6'd3;     
    wire [1:0] cur_wr_row = in_y_mod3[1:0];  
    wire [1:0] r_bot      = cur_wr_row;                              
    wire [1:0] r_mid      = (cur_wr_row == 2'd0) ? 2'd2 : (cur_wr_row - 2'd1);  
    wire [1:0] r_top      = (cur_wr_row == 2'd2) ? 2'd0 : (cur_wr_row + 2'd1);  

    // Dynamic multiplexer calculation for window selection
    wire [7:0] win_sel = (k == 4'd0) ? lb[c][r_top][ox    ] :
                         (k == 4'd1) ? lb[c][r_top][ox + 1] :
                         (k == 4'd2) ? lb[c][r_top][ox + 2] :
                         (k == 4'd3) ? lb[c][r_mid][ox    ] :
                         (k == 4'd4) ? lb[c][r_mid][ox + 1] :
                         (k == 4'd5) ? lb[c][r_mid][ox + 2] :
                         (k == 4'd6) ? lb[c][r_bot][ox    ] :
                         (k == 4'd7) ? lb[c][r_bot][ox + 1] :
                                       lb[c][r_bot][ox + 2] ; 

    // -----------------------------------------------------------------
    // Master FSM
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            co_we        <= 1'b0;
            in_y         <= 0;  in_x  <= 0;  in_c  <= 0;
            oy           <= 0;  ox    <= 0;  f     <= 0;  c <= 0;  k <= 0;
            acc          <= 0;
            img_addr     <= 0;
            w_addr       <= 0;
            win_sel_reg  <= 0;
            w_data_reg   <= 0;
        end else begin
            co_we <= 1'b0;
            case (state)

                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        in_y  <= 0;  in_x <= 0;  in_c <= 0;
                        oy    <= 0;  ox   <= 0;
                        f     <= 0;  c    <= 0;  k    <= 0;
                        acc   <= 0;
                        state <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    img_addr <= in_c * (INPUT_H * INPUT_W) + in_y * INPUT_W + in_x;
                    state    <= S_FETCH_WAIT;
                end

                S_FETCH_WAIT: begin
                    state <= S_SHIFT;
                end

                S_SHIFT: begin
                    lb[in_c][cur_wr_row][in_x] <= img_data;
                    if (in_c < INPUT_CH - 1) begin
                        in_c  <= in_c + 1;
                        state <= S_FETCH;
                    end else begin
                        in_c  <= 0;
                        state <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (in_y >= 2 && in_x >= 2) begin
                        oy    <= in_y - 2;
                        ox    <= in_x - 2;
                        f     <= 0;
                        c     <= 0;
                        k     <= 0;
                        acc   <= 0;
                        state <= S_WLOAD;
                    end else begin
                        if (in_x < INPUT_W - 1) begin
                            in_x  <= in_x + 1;
                            state <= S_FETCH;
                        end else begin
                            in_x <= 0;
                            if (in_y < INPUT_H - 1) begin
                                in_y  <= in_y + 1;
                                state <= S_FETCH;
                            end else begin
                                state <= S_DONE;
                            end
                        end
                    end
                end

                S_WLOAD: begin
                    w_addr <= f * (INPUT_CH * 9) + c * 9 + k;
                    state  <= S_WLOAD_WAIT;
                end

                S_WLOAD_WAIT: begin
                    state <= S_WCAP_PIPE;
                end

                // Intermediate registered stage: Isolate window logic delay from DSP adder
                S_WCAP_PIPE: begin
                    win_sel_reg <= $signed({1'b0, win_sel});
                    w_data_reg  <= w_data;
                    state       <= S_WCAP;
                end

                // Dedicated DSP MAC step (Infers DSP48E1 MREG/PREG)
                S_WCAP: begin
                    acc <= acc + (win_sel_reg * w_data_reg);
                    if (k < 8) begin
                        k     <= k + 1;
                        state <= S_WLOAD;
                    end else begin
                        k     <= 0;
                        state <= S_NEXT_CH;
                    end
                end

                S_NEXT_CH: begin
                    if (c < INPUT_CH - 1) begin
                        c     <= c + 1;
                        k     <= 0;
                        state <= S_WLOAD;
                    end else begin
                        state <= S_RELU;
                    end
                end

                S_RELU: begin
                    if (acc[31]) begin
                        co_data <= 8'd0;
                    end else if ((acc >>> SHIFT) > 32'sd255) begin
                        co_data <= 8'd255;
                    end else begin
                        co_data <= (acc >>> SHIFT);
                    end
                    co_addr <= f * (OUTPUT_H * OUTPUT_W) + oy * OUTPUT_W + ox;
                    co_we   <= 1'b1;
                    state   <= S_NEXT_FILTER;
                end

                S_NEXT_FILTER: begin
                    if (f < OUTPUT_CH - 1) begin
                        f     <= f + 1;
                        c     <= 0;
                        k     <= 0;
                        acc   <= 0;
                        state <= S_WLOAD;
                    end else begin
                        state <= S_NEXT_PIX;
                    end
                end

                S_NEXT_PIX: begin
                    if (in_x < INPUT_W - 1) begin
                        in_x  <= in_x + 1;
                        state <= S_FETCH;
                    end else begin
                        in_x <= 0;
                        if (in_y < INPUT_H - 1) begin
                            in_y  <= in_y + 1;
                            state <= S_FETCH;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    if (!start) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
