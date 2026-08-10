`timescale 1ns / 1ps
// =====================================================================
//  argmax10.v - Pipelined 10-way Argmax (3-Stage Latency)
// =====================================================================
module argmax10 (
    input  wire        clk,
    input  wire        rst,
    input  wire signed [31:0] v0, v1, v2, v3, v4, v5, v6, v7, v8, v9,
    output reg  [3:0]  best_idx
);

    // ---- Stage 1 Registers: 5 pairwise compares --------------------
    reg signed [31:0] r1_val0, r1_val1, r1_val2, r1_val3, r1_val4;
    reg        [3:0]  r1_idx0, r1_idx1, r1_idx2, r1_idx3, r1_idx4;

    always @(posedge clk) begin
        if (rst) begin
            {r1_val0, r1_idx0} <= {32'd0, 4'd0};
            {r1_val1, r1_idx1} <= {32'd0, 4'd2};
            {r1_val2, r1_idx2} <= {32'd0, 4'd4};
            {r1_val3, r1_idx3} <= {32'd0, 4'd6};
            {r1_val4, r1_idx4} <= {32'd0, 4'd8};
        end else begin
            {r1_val0, r1_idx0} <= (v0 >= v1) ? {v0, 4'd0} : {v1, 4'd1};
            {r1_val1, r1_idx1} <= (v2 >= v3) ? {v2, 4'd2} : {v3, 4'd3};
            {r1_val2, r1_idx2} <= (v4 >= v5) ? {v4, 4'd4} : {v5, 4'd5};
            {r1_val3, r1_idx3} <= (v6 >= v7) ? {v6, 4'd6} : {v7, 4'd7};
            {r1_val4, r1_idx4} <= (v8 >= v9) ? {v8, 4'd8} : {v9, 4'd9};
        end
    end

    // ---- Stage 2 Registers: 2 pairwise compares + 1 passthrough ----
    reg signed [31:0] r2_val0, r2_val1, r2_val2;
    reg        [3:0]  r2_idx0, r2_idx1, r2_idx2;

    always @(posedge clk) begin
        if (rst) begin
            {r2_val0, r2_idx0} <= {32'd0, 4'd0};
            {r2_val1, r2_idx1} <= {32'd0, 4'd0};
            {r2_val2, r2_idx2} <= {32'd0, 4'd0};
        end else begin
            {r2_val0, r2_idx0} <= (r1_val0 >= r1_val1) ? {r1_val0, r1_idx0} : {r1_val1, r1_idx1};
            {r2_val1, r2_idx1} <= (r1_val2 >= r1_val3) ? {r1_val2, r1_idx2} : {r1_val3, r1_idx3};
            r2_val2 <= r1_val4;
            r2_idx2 <= r1_idx4;
        end
    end

    // ---- Stage 3 Registers: Final compares -> output ----------------
    reg signed [31:0] win_val01;
    reg        [3:0]  win_idx01;

    always @(posedge clk) begin
        if (rst) begin
            best_idx <= 4'd0;
        end else begin
            if (r2_val0 >= r2_val1) begin
                win_val01 = r2_val0;
                win_idx01 = r2_idx0;
            end else begin
                win_val01 = r2_val1;
                win_idx01 = r2_idx1;
            end

            if (win_val01 >= r2_val2) begin
                best_idx <= win_idx01;
            end else begin
                best_idx <= r2_idx2;
            end
        end
    end

endmodule
