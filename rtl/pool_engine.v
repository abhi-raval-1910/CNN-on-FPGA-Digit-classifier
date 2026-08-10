`timescale 1ns / 1ps
// 2x2 / stride-2 max pooling over the 26x26x4 conv output -> 13x13x4.
// Reads conv_out RAM (one address at a time), writes pool_out RAM.
module pool_engine (
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    output reg  [11:0] co_addr,   // conv_out read address
    input  wire [7:0]  co_data,

    output reg          po_we,
    output reg  [9:0]   po_addr,  // 0..675
    output reg  [7:0]   po_data
);
    localparam S_IDLE=0, S_ADDR=1, S_WAIT=2, S_CMP=3, S_STORE=4, S_NEXT=5, S_DONE=6;
    reg [2:0] state;

    reg [1:0] f;
    reg [3:0] py, px;   // 0..12
    reg [1:0] d;         // which of the 4 taps (0..3): (0,0)(0,1)(1,0)(1,1)
    reg [7:0] best;

    function [11:0] conv_addr_f;
        input [1:0] ff;
        input [3:0] pyy, pxx;
        input [1:0] dd;
        reg [4:0] yy, xx;
        begin
            yy = pyy*2 + dd[1];
            xx = pxx*2 + dd[0];
            conv_addr_f = ff*676 + yy*26 + xx;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; f<=0; py<=0; px<=0; d<=0; best<=0; po_we<=0;
        end else begin
            po_we <= 0;
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        f<=0; py<=0; px<=0; d<=0; best<=0;
                        state <= S_ADDR;
                    end
                end
                S_ADDR: begin
                    co_addr <= conv_addr_f(f, py, px, d);
                    state <= S_WAIT;
                end
                S_WAIT: state <= S_CMP;
                S_CMP: begin
                    if (d == 2'd0 || co_data > best) best <= co_data;
                    if (d == 2'd3) state <= S_STORE;
                    else begin
                        d <= d + 1;
                        state <= S_ADDR;
                    end
                end
                S_STORE: begin
                    po_data <= best;
                    po_addr <= f*169 + py*13 + px;
                    po_we   <= 1;
                    d <= 0;
                    state <= S_NEXT;
                end
                S_NEXT: begin
                    if (px == 4'd12) begin
                        px <= 0;
                        if (py == 4'd12) begin
                            py <= 0;
                            if (f == 2'd3) state <= S_DONE;
                            else begin f <= f+1; state <= S_ADDR; end
                        end else begin py <= py+1; state <= S_ADDR; end
                    end else begin px <= px+1; state <= S_ADDR; end
                end
                S_DONE: begin
                    done <= 1;
                    if (!start) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
