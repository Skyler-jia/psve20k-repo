//======================================================================
// video_timing.v — 1280x720p60 (CEA-861) 时序发生器
//   H: 1280 active + 110 front + 40 sync + 220 back = 1650
//   V:  720 active +   5 front +  5 sync +  20 back = 750
//   像素钟 74.25MHz（由 27MHz 经 TMDS_rPLL + CLKDIV/5 得到）
// 输出 x/y 为"有效像素区内"的坐标，配合 de 使用
//======================================================================
`timescale 1ns/1ps

module video_timing #(
    parameter H_TOTAL = 1650,
    parameter H_SYNC  = 40,
    parameter H_BP    = 220,
    parameter H_ACT   = 1280,
    parameter V_TOTAL = 750,
    parameter V_SYNC  = 5,
    parameter V_BP    = 20,
    parameter V_ACT   = 720,
    parameter SYNC_DLY = 5        // 与图像流水线延迟对齐
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire        de,            // 有效像素
    output wire        hs,
    output wire        vs,
    output wire [10:0] x,             // 0..1279
    output wire [9:0]  y,             // 0..719
    output wire [10:0] xd,            // 与 de 对齐的延迟坐标（给 OSD）
    output wire [9:0]  yd,
    output wire        line_start,    // 每行有效区首拍
    output wire        frame_start    // 每帧最后一个时钟
);

    localparam H_START = H_SYNC + H_BP;
    localparam V_START = V_SYNC + V_BP;

    reg [11:0] h_cnt;
    reg [11:0] v_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) h_cnt <= 12'd0;
        else if (h_cnt == H_TOTAL-1) h_cnt <= 12'd0;
        else h_cnt <= h_cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_cnt <= 12'd0;
        else if (h_cnt == H_TOTAL-1) begin
            if (v_cnt == V_TOTAL-1) v_cnt <= 12'd0;
            else v_cnt <= v_cnt + 1'b1;
        end
    end

    wire de_w    = (h_cnt >= H_START) && (h_cnt < H_START + H_ACT) &&
                   (v_cnt >= V_START) && (v_cnt < V_START + V_ACT);
    wire hs_w    = (h_cnt < H_SYNC);         // 正极性同步
    wire vs_w    = (v_cnt < V_SYNC);
    wire line_w  = (h_cnt == H_START) && (v_cnt >= V_START) && (v_cnt < V_START + V_ACT);
    wire fstart_w= (h_cnt == H_TOTAL-1) && (v_cnt == V_TOTAL-1);

    // 与图像流水线同延迟
    reg [SYNC_DLY-1:0] de_d, hs_d, vs_d, ls_d, fs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 0; hs_d <= 0; vs_d <= 0; ls_d <= 0; fs_d <= 0;
        end else begin
            de_d <= {de_d[SYNC_DLY-2:0], de_w};
            hs_d <= {hs_d[SYNC_DLY-2:0], hs_w};
            vs_d <= {vs_d[SYNC_DLY-2:0], vs_w};
            ls_d <= {ls_d[SYNC_DLY-2:0], line_w};
            fs_d <= {fs_d[SYNC_DLY-2:0], fstart_w};
        end
    end

    assign de          = de_d[SYNC_DLY-1];
    assign hs          = hs_d[SYNC_DLY-1];
    assign vs          = vs_d[SYNC_DLY-1];
    assign line_start  = ls_d[SYNC_DLY-1];
    assign frame_start = fs_d[SYNC_DLY-1];

    // 有效像素坐标（组合，直接给 img_gen 用；消隐期强制为 0 防止下溢）
    wire [11:0] hoff = h_cnt - H_START[11:0];
    wire [11:0] voff = v_cnt - V_START[11:0];
    assign x = de_w ? hoff[10:0] : 11'd0;
    assign y = de_w ? voff[9:0]  : 10'd0;

    //------------------------------------------------------------------
    // 与 de 同延迟的坐标（OSD 合成需要知道"这个像素的列号"）
    //------------------------------------------------------------------
    reg [10:0] xd_sr [0:SYNC_DLY-1];
    reg [9:0]  yd_sr [0:SYNC_DLY-1];
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < SYNC_DLY; k = k + 1) begin
                xd_sr[k] <= 11'd0;
                yd_sr[k] <= 10'd0;
            end
        end else begin
            xd_sr[0] <= x;
            yd_sr[0] <= y;
            for (k = 1; k < SYNC_DLY; k = k + 1) begin
                xd_sr[k] <= xd_sr[k-1];
                yd_sr[k] <= yd_sr[k-1];
            end
        end
    end
    assign xd = xd_sr[SYNC_DLY-1];
    assign yd = yd_sr[SYNC_DLY-1];

endmodule
