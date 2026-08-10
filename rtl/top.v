`timescale 1ns / 1ps
module top (
    input  wire        clk,      // 100MHz onboard clock (W5)
    input  wire        btnC,     // center button = reset
    input  wire        RsRx,     // UART RX from micro-USB (B18)
    output wire [3:0]  an,
    output wire [6:0]  seg,
    output wire [15:0] led
);
    wire rst = btnC;

    // ---------------------------------------------------------------
    // UART receiver
    // ---------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx uart_inst (
        .clk(clk), .rst(rst), .rx(RsRx),
        .data_out(rx_data), .valid(rx_valid)
    );

    // Write-address counter for the image RAM. Counts 0..783.
    // Auto-restart behavior: if we're sitting in M_DONE showing a result
    // and a new byte arrives, treat it as pixel 0 of a fresh image and
    // start over automatically -- no need to press btnC between images.
    reg [9:0] img_wr_addr = 0;
    reg       loading_done = 0;

    wire new_image_byte = rx_valid && (mstate == M_DONE);
    wire [9:0] img_waddr_eff = new_image_byte ? 10'd0 : img_wr_addr;
    wire       img_we        = rx_valid && (mstate == M_LOAD || mstate == M_DONE);

    always @(posedge clk) begin
        if (rst) begin
            img_wr_addr  <= 0;
            loading_done <= 0;
        end else if (new_image_byte) begin
            img_wr_addr  <= 1;   // byte 0 just written this cycle
            loading_done <= 0;
        end else if (rx_valid && !loading_done) begin
            if (img_wr_addr == 10'd783) begin
                loading_done <= 1; // last pixel just latched
            end else begin
                img_wr_addr <= img_wr_addr + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Image RAM (784 x 8)
    // ---------------------------------------------------------------
    wire [9:0] img_rd_addr;
    wire [7:0] img_rd_data;
    dp_ram #(.DEPTH(784), .AW(10)) image_ram (
        .clk(clk),
        .we(img_we), .waddr(img_waddr_eff), .wdata(rx_data),
        .raddr(img_rd_addr), .rdata(img_rd_data)
    );

    // ---------------------------------------------------------------
    // Conv1 weight ROM (36 x 8) -- generate with python/quantize_export.py
    // ---------------------------------------------------------------
    wire [5:0] c1_w_addr;
    wire signed [7:0] c1_w_data;
    weight_rom #(.DEPTH(36), .AW(6), .FILENAME("conv1_weights.mem")) conv1_rom (
        .clk(clk), .addr(c1_w_addr), .dout(c1_w_data)
    );

    // ---------------------------------------------------------------
    // Conv-out RAM (2704 x 8) : 4 filters * 26 * 26
    // ---------------------------------------------------------------
    wire        co_we;
    wire [11:0] co_wr_addr;
    wire [7:0]  co_wr_data;
    wire [11:0] co_rd_addr;
    wire [7:0]  co_rd_data;
    dp_ram #(.DEPTH(2704), .AW(12)) conv_out_ram (
        .clk(clk),
        .we(co_we), .waddr(co_wr_addr), .wdata(co_wr_data),
        .raddr(co_rd_addr), .rdata(co_rd_data)
    );

    // ---------------------------------------------------------------
    // Pool-out RAM (676 x 8) : 4 filters * 13 * 13
    // ---------------------------------------------------------------
    wire        po_we;
    wire [9:0]  po_wr_addr;
    wire [7:0]  po_wr_data;
    wire [9:0]  po_rd_addr;
    wire [7:0]  po_rd_data;
    dp_ram #(.DEPTH(676), .AW(10)) pool_out_ram (
        .clk(clk),
        .we(po_we), .waddr(po_wr_addr), .wdata(po_wr_data),
        .raddr(po_rd_addr), .rdata(po_rd_data)
    );

    // ---------------------------------------------------------------
    // FC weight ROM (6760 x 8)
    // ---------------------------------------------------------------
    wire [12:0] fc_w_addr;
    wire signed [7:0] fc_w_data;
    weight_rom #(.DEPTH(6760), .AW(13), .FILENAME("fc_weights.mem")) fc_rom (
        .clk(clk), .addr(fc_w_addr), .dout(fc_w_data)
    );

    // ---------------------------------------------------------------
    // Compute engines
    // ---------------------------------------------------------------
    reg conv_start, pool_start, fc_start;
    wire conv_done, pool_done, fc_done;

    conv_engine #(.SHIFT(4)) u_conv (
        .clk(clk), .rst(rst), .start(conv_start), .done(conv_done),
        .img_addr(img_rd_addr), .img_data(img_rd_data),
        .w_addr(c1_w_addr), .w_data(c1_w_data),
        .co_we(co_we), .co_addr(co_wr_addr), .co_data(co_wr_data)
    );

    pool_engine u_pool (
        .clk(clk), .rst(rst), .start(pool_start), .done(pool_done),
        .co_addr(co_rd_addr), .co_data(co_rd_data),
        .po_we(po_we), .po_addr(po_wr_addr), .po_data(po_wr_data)
    );

    wire fc_out_valid;
    wire [3:0] fc_out_idx;
    wire signed [31:0] fc_out_val;

    fc_engine u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .done(fc_done),
        .po_addr(po_rd_addr), .po_data(po_rd_data),
        .w_addr(fc_w_addr), .w_data(fc_w_data),
        .out_valid(fc_out_valid), .out_idx(fc_out_idx), .out_val(fc_out_val)
    );

    // Latch the 10 class scores as they stream out of fc_engine
    reg signed [31:0] scores [0:9];
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 10; k = k + 1) scores[k] <= 0;
        end else if (fc_out_valid) begin
            scores[fc_out_idx] <= fc_out_val;
        end
    end

    wire [3:0] predicted_digit;
    argmax10 u_argmax (
        .v0(scores[0]), .v1(scores[1]), .v2(scores[2]), .v3(scores[3]), .v4(scores[4]),
        .v5(scores[5]), .v6(scores[6]), .v7(scores[7]), .v8(scores[8]), .v9(scores[9]),
        .best_idx(predicted_digit)
    );

    // ---------------------------------------------------------------
    // Master FSM: LOAD -> CONV -> POOL -> FC -> DONE
    // ---------------------------------------------------------------
    localparam M_IDLE=0, M_LOAD=1, M_CONV=2, M_CONV_W=3, M_POOL=4, M_POOL_W=5,
               M_FC=6, M_FC_W=7, M_DONE=8;
    reg [3:0] mstate;
    reg [3:0] latched_digit;
    reg       result_ready;

    always @(posedge clk) begin
        if (rst) begin
            mstate <= M_LOAD;
            conv_start <= 0; pool_start <= 0; fc_start <= 0;
            latched_digit <= 0; result_ready <= 0;
        end else begin
            case (mstate)
                M_LOAD: begin
                    result_ready <= 0;
                    if (loading_done) mstate <= M_CONV;
                end
                M_CONV: begin
                    conv_start <= 1;
                    mstate <= M_CONV_W;
                end
                M_CONV_W: begin
                    if (conv_done) begin
                        conv_start <= 0;
                        mstate <= M_POOL;
                    end
                end
                M_POOL: begin
                    pool_start <= 1;
                    mstate <= M_POOL_W;
                end
                M_POOL_W: begin
                    if (pool_done) begin
                        pool_start <= 0;
                        mstate <= M_FC;
                    end
                end
                M_FC: begin
                    fc_start <= 1;
                    mstate <= M_FC_W;
                end
                M_FC_W: begin
                    if (fc_done) begin
                        fc_start <= 0;
                        mstate <= M_DONE;
                    end
                end
                M_DONE: begin
                    latched_digit <= predicted_digit;
                    result_ready  <= 1;
                    // Auto-restart: as soon as the PC starts sending a new
                    // image (first byte arrives), drop back into M_LOAD.
                    // img_wr_addr/loading_done are already being reset to
                    // capture this same byte as pixel 0 (see above).
                    if (rx_valid) begin
                        mstate       <= M_LOAD;
                        result_ready <= 0;
                    end
                end
                default: mstate <= M_LOAD;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Output
    // ---------------------------------------------------------------
    display_7seg u_disp (.clk(clk), .digit_in(latched_digit), .an(an), .seg(seg));

    assign led[3:0]   = latched_digit;
    assign led[4]     = result_ready;
    assign led[5]     = loading_done;
    assign led[15:6]  = img_wr_addr[9:0]; // debug: watch pixels arrive while loading

endmodule
