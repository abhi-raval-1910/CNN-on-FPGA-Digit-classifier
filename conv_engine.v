`timescale 1ns / 1ps
// Computes a 3x3, 4-filter, stride-1, no-padding convolution over a 28x28
// image (-> 26x26x4 output), applies ReLU, requantizes to 8-bit, and
// writes the result to conv_out RAM.
//
// This is a SEQUENTIAL (one MAC at a time) engine, not a parallel/pipelined
// one. It is much easier to get correct as a first project. It runs in
// about 4*26*26*9 = 24,336 clock cycles (~0.24 ms at 100MHz) - plenty fast
// for a single still-image classification.
module conv_engine #(
    parameter SHIFT = 4  // requantization shift; tune based on your scale factors
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    // image RAM read port
    output reg  [9:0]  img_addr,
    input  wire [7:0]  img_data,

    // conv1 weight ROM read port
    output reg  [5:0]  w_addr,
    input  wire signed [7:0] w_data,

    // conv_out RAM write port
    output reg          co_we,
    output reg  [11:0]  co_addr,
    output reg  [7:0]   co_data
);
    localparam S_IDLE=0, S_ADDR=1, S_WAIT=2, S_MAC=3, S_NEXTK=4, S_STORE=5, S_NEXTPIX=6, S_DONE=7;
    reg [3:0] state;

    reg [1:0] f;
    reg [4:0] oy, ox;
    reg [1:0] ky, kx;
    reg signed [31:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 0; f<=0; oy<=0; ox<=0; ky<=0; kx<=0; acc<=0; co_we<=0;
        end else begin
            co_we <= 0;
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        f<=0; oy<=0; ox<=0; ky<=0; kx<=0; acc<=0;
                        state <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    img_addr <= (oy + ky) * 28 + (ox + kx);
                    w_addr   <= f * 9 + ky * 3 + kx;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    // wait for registered RAM/ROM outputs to become valid
                    state <= S_MAC;
                end

                S_MAC: begin
                    acc <= acc + ($signed({1'b0, img_data}) * w_data);
                    state <= S_NEXTK;
                end

                S_NEXTK: begin
                    if (kx == 2'd2) begin
                        kx <= 0;
                        if (ky == 2'd2) begin
                            ky <= 0;
                            state <= S_STORE;
                        end else begin
                            ky <= ky + 1;
                            state <= S_ADDR;
                        end
                    end else begin
                        kx <= kx + 1;
                        state <= S_ADDR;
                    end
                end

                S_STORE: begin
                    // ReLU
                    if (acc[31]) begin
                        co_data <= 8'd0;
                    end else if ((acc >>> SHIFT) > 255) begin
                        co_data <= 8'd255;
                    end else begin
                        co_data <= (acc >>> SHIFT);
                    end
                    co_addr <= f * 676 + oy * 26 + ox;
                    co_we   <= 1;
                    acc     <= 0;
                    state   <= S_NEXTPIX;
                end

                S_NEXTPIX: begin
                    if (ox == 5'd25) begin
                        ox <= 0;
                        if (oy == 5'd25) begin
                            oy <= 0;
                            if (f == 2'd3) state <= S_DONE;
                            else begin
                                f <= f + 1;
                                state <= S_ADDR;
                            end
                        end else begin
                            oy <= oy + 1;
                            state <= S_ADDR;
                        end
                    end else begin
                        ox <= ox + 1;
                        state <= S_ADDR;
                    end
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
