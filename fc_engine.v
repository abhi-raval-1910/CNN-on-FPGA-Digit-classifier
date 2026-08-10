`timescale 1ns / 1ps
// Fully connected layer: 676 inputs -> 10 outputs (no bias).
// Computes each of the 10 class scores sequentially (676 MACs each).
module fc_engine (
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    output reg  [9:0]  po_addr,   // pool_out read address (0..675)
    input  wire [7:0]  po_data,

    output reg  [12:0] w_addr,    // fc weight ROM address (0..6759)
    input  wire signed [7:0] w_data,

    output reg          out_valid,
    output reg  [3:0]   out_idx,
    output reg  signed [31:0] out_val
);
    localparam S_IDLE=0, S_ADDR=1, S_WAIT=2, S_MAC=3, S_NEXTIN=4, S_STORE=5, S_NEXTOUT=6, S_DONE=7;
    reg [3:0] state;

    reg [3:0] o;      // 0..9
    reg [9:0] i;      // 0..675
    reg signed [31:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; o<=0; i<=0; acc<=0; out_valid<=0;
        end else begin
            out_valid <= 0;
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        o<=0; i<=0; acc<=0;
                        state <= S_ADDR;
                    end
                end
                S_ADDR: begin
                    po_addr <= i;
                    w_addr  <= o*676 + i;
                    state <= S_WAIT;
                end
                S_WAIT: state <= S_MAC;
                S_MAC: begin
                    acc <= acc + ($signed({1'b0, po_data}) * w_data);
                    state <= S_NEXTIN;
                end
                S_NEXTIN: begin
                    if (i == 10'd675) state <= S_STORE;
                    else begin i <= i+1; state <= S_ADDR; end
                end
                S_STORE: begin
                    out_idx   <= o;
                    out_val   <= acc;
                    out_valid <= 1;
                    acc <= 0;
                    i   <= 0;
                    state <= S_NEXTOUT;
                end
                S_NEXTOUT: begin
                    if (o == 4'd9) state <= S_DONE;
                    else begin o <= o+1; state <= S_ADDR; end
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
