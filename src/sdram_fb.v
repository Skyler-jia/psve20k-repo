//======================================================================
// sdram_fb.v — 片内 SDRAM 帧缓存 + 最小读写控制逻辑（v1.2）
//
// 本版新增三件事：
//   1) 读地址跟随「读指针」而不是墙钟行号 —— 这是瀑布图不撕行的前提
//   2) 读/写窗口轮转仲裁（每窗口最多 QUOTA 个突发）—— 换向次数降低 8 倍
//   3) 性能计数器（读/写 KB、换向次数、总线占用率）—— 给 OSD 详情页
//
// 存储：亮度 8bit，4 像素打包 1 个 32bit 字
//      一行 1280px -> 320 字；一帧 320*720 = 230400 字 = 921.6KB
//      8 帧共 1,843,200 字 = 7.03MB（片内 8MB 装得下）
//
// 带宽：每行 320 写 + 320 读 = 640 字 / 1650 像素周期 = 39%
//      460800 字/帧 x 4B x 60fps = 110.6MB/s（32bit@74.25MHz 峰值 297MB/s）
//
// 时序（照抄 Gowin 官方 tb 用法）：
//   请求 wr_n/rd_n 拉低 1 拍，同时给 addr / data_len
//   写数据：命令拍即给出首字，其后逐拍递增，共 BURST 字
//   读数据：rd_valid 每拍返回 1 个字；busy_n 为高才可发下一条命令
//   addr = {bank[1:0], row[10:0], col[7:0]}，线性字地址直接对应
//======================================================================
`timescale 1ns/1ps

module sdram_fb #(
    parameter FRAME_WORDS = 230400,     // 320*720
    parameter DEPTH       = 8,          // 缓存帧数
    parameter BURST       = 16,
    parameter QUOTA       = 8,          // 每个方向连续服务的突发数
    parameter RD_DEPTH    = 8,          // 读 FIFO = 2^8 = 256 字
    parameter WR_DEPTH    = 6           // 写 FIFO = 2^6 = 64 字
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 写入侧：实时灰度（来自 img_gen）----
    input  wire        wr_de,
    input  wire [7:0]  wr_gray,
    input  wire        frame_start,     // 每帧一次

    // ---- 读出侧：延迟/切片后的灰度（给 img_proc）----
    input  wire        rd_de,
    output reg  [7:0]  rd_gray,

    // ---- 控制 ----
    input  wire [3:0]  delay_sel,       // 普通模式=帧延迟(1..7)；瀑布模式=带间帧差(1..8)
    input  wire        waterfall,       // 1 = 时间切片瀑布（8 个横带各取一帧）
    input  wire [3:0]  band_step,       // 带间帧差：1..8 = 时间瀑布；0 = 所有带同一帧（算法栅格）
    output wire        fb_ready,
    output wire        wr_overflow,
    output wire        rd_underrun,

    // ---- 性能计数器（OSD 详情页）----
    output reg  [9:0]  stat_rd_kb,      // 读 KB/帧
    output reg  [9:0]  stat_wr_kb,      // 写 KB/帧
    output reg  [9:0]  stat_turn,       // 换向次数/帧
    output reg  [7:0]  stat_busy,       // 总线占用率 %
    output reg  [15:0] bursts_frame,    // 突发次数/帧（给简版 OSD 算带宽）
    output reg  [31:0] total_bursts,    // 上电以来累计突发数（OSD 仪表盘）

    // ---- SDRC_EMB 用户接口 ----
    output reg  [20:0] sdrc_addr,
    output reg  [7:0]  sdrc_data_len,
    output reg  [31:0] sdrc_data,
    output reg  [3:0]  sdrc_dqm,
    output reg         sdrc_wr_n,
    output reg         sdrc_rd_n,
    input  wire [31:0] sdrc_data_q,
    input  wire        sdrc_init_done,
    input  wire        sdrc_busy_n,
    input  wire        sdrc_rd_valid
);

    localparam RDW = RD_DEPTH;
    localparam WRW = WR_DEPTH;
    localparam [20:0] BURST_ADDR = BURST;

    //==================================================================
    // 0. 帧相位
    //==================================================================
    reg [3:0] frame_phase;
    reg [3:0] frames_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_phase <= 4'd0;
            frames_done <= 4'd0;
        end else if (frame_start) begin
            frame_phase <= (frame_phase == DEPTH-1) ? 4'd0 : frame_phase + 1'b1;
            if (frames_done != 4'hF) frames_done <= frames_done + 1'b1;
        end
    end

    assign fb_ready = sdrc_init_done && (frames_done >= delay_sel);

    // 瀑布图：720 行分 8 带，每带 90 行，带 k 显示第 (N-k-1) 帧
    function [2:0] band_of;
        input [9:0] ly;
        begin
            if      (ly < 90)  band_of = 3'd0;
            else if (ly < 180) band_of = 3'd1;
            else if (ly < 270) band_of = 3'd2;
            else if (ly < 360) band_of = 3'd3;
            else if (ly < 450) band_of = 3'd4;
            else if (ly < 540) band_of = 3'd5;
            else if (ly < 630) band_of = 3'd6;
            else               band_of = 3'd7;
        end
    endfunction

    //==================================================================
    // 1. 写侧：4 像素 -> 1 个 32bit 字
    //==================================================================
    reg [1:0]  wr_px;
    reg [31:0] wr_pack;
    reg [31:0] wr_fifo_din;
    reg        wr_fifo_we;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_px <= 2'd0; wr_pack <= 32'd0;
            wr_fifo_we <= 1'b0; wr_fifo_din <= 32'd0;
        end else begin
            wr_fifo_we <= 1'b0;
            if (wr_de) begin
                wr_pack <= {wr_pack[23:0], wr_gray};
                if (wr_px == 2'd3) begin
                    wr_fifo_we  <= 1'b1;
                    wr_fifo_din <= {wr_pack[23:0], wr_gray};
                    wr_px       <= 2'd0;
                end else begin
                    wr_px <= wr_px + 1'b1;
                end
            end
        end
    end

    wire [31:0]  wr_dout;
    wire         wr_empty, wr_full;
    wire [WRW:0] wr_count;
    wire         w_pop;

    sync_fifo #(.DW(32), .AW(WRW)) u_wrfifo (
        .clk(clk), .rst_n(rst_n), .flush(frame_start),
        .wr_en(wr_fifo_we), .din(wr_fifo_din),
        .rd_en(w_pop), .dout(wr_dout),
        .full(wr_full), .empty(wr_empty), .count(wr_count)
    );

    assign wr_overflow = wr_fifo_we & wr_full;

    //==================================================================
    // 2. 读侧：1 个 32bit 字 -> 4 像素
    //==================================================================
    reg [1:0]   rd_px;
    wire [31:0] rd_dout;
    wire        rd_empty, rd_full;
    wire [RDW:0] rd_count;
    wire        r_pop;

    sync_fifo #(.DW(32), .AW(RDW)) u_rdfifo (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .wr_en(sdrc_rd_valid), .din(sdrc_data_q),
        .rd_en(r_pop), .dout(rd_dout),
        .full(rd_full), .empty(rd_empty), .count(rd_count)
    );

    assign r_pop = rd_de && (rd_px == 2'd0) && !rd_empty;
    assign rd_underrun = rd_de && (rd_px == 2'd0) && rd_empty;

    wire [7:0] rd_byte;
    assign rd_byte = (rd_px == 2'd0) ? rd_dout[31:24] :
                     (rd_px == 2'd1) ? rd_dout[23:16] :
                     (rd_px == 2'd2) ? rd_dout[15:8]  : rd_dout[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_px   <= 2'd0;
            rd_gray <= 8'h20;
        end else if (rd_de) begin
            rd_px   <= (rd_px == 2'd3) ? 2'd0 : rd_px + 1'b1;
            rd_gray <= fb_ready ? rd_byte : 8'h20;
        end
    end

    //==================================================================
    // 3. 读地址：跟随读指针（行 + 行内字偏移）
    //    这样无论如何都不会出现"跳字/撕行"
    //==================================================================
    reg [9:0]  rd_line;        // 0..719
    reg [9:0]  rd_wcnt;        // 0..304 步进 16
    reg        rd_started;

    wire [2:0]  band   = waterfall ? band_of(rd_line) : 3'd0;
    // 带 k 显示第 (N - k*step - 1) 帧；step 复用 delay_sel（1..8）
    // 注意只取 (band*step) mod 8，乘法结果低位即可
    wire [5:0]  bstep  = {3'b0, band} * band_step[2:0];
    wire [2:0]  bstep8 = bstep[2:0];
    wire [3:0]  fnum   = waterfall
                       ? ((frame_phase + 4'd8 - {1'b0, bstep8} - 4'd1) & 4'h7)
                       : ((frame_phase + 4'd8 - delay_sel) & 4'h7);
    wire [20:0] r_base = fnum[2:0] * 21'd230400;
    wire [20:0] r_line = {2'b0, rd_line, 8'b0} + {4'b0, rd_line, 6'b0};  // rd_line*320
    wire [20:0] r_cur  = r_base + r_line + {11'b0, rd_wcnt};

    // frame_start 那一刻 frame_phase 还是旧值，写指针要用"下一帧"相位
    wire [3:0]  nxt_phase = (frame_phase == DEPTH-1) ? 4'd0 : frame_phase + 1'b1;

    //==================================================================
    // 4. 仲裁：读/写窗口轮转（每窗口最多 QUOTA 个突发）
    //==================================================================
    reg        dir;            // 0 = 读窗口, 1 = 写窗口
    reg [3:0]  quota;
    reg        w_act, r_act;
    reg [4:0]  wn;
    reg [20:0] w_addr;
    reg [4:0]  r_rem;
    reg [5:0]  r_tmo;

    wire w_want = !w_act && sdrc_init_done && (wr_count >= BURST);
    wire r_want = !r_act && sdrc_init_done && ((rd_count + BURST) <= (1<<RDW)) && rd_started;
    wire any_gnt = sdrc_busy_n && (r_want || w_want);

    wire r_gnt = any_gnt && (dir == 1'b0) && r_want;
    wire w_gnt = any_gnt && (dir == 1'b1) && w_want;

    assign w_pop = w_gnt || (w_act && (wn < BURST));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dir <= 1'b0; quota <= QUOTA[3:0];
        end else if (frame_start) begin
            dir <= 1'b0; quota <= QUOTA[3:0];
        end else if (r_gnt || w_gnt) begin
            if (quota <= 4'd1) begin
                dir <= ~dir; quota <= QUOTA[3:0];
            end else begin
                quota <= quota - 1'b1;
            end
        end else if ((dir == 1'b0) && !r_want && w_want) begin
            dir <= 1'b1; quota <= QUOTA[3:0];        // 读没需求，立刻让给写
        end else if ((dir == 1'b1) && !w_want && r_want) begin
            dir <= 1'b0; quota <= QUOTA[3:0];        // 写没需求，立刻让给读
        end
    end

    //==================================================================
    // 5. 突发引擎
    //==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdrc_wr_n <= 1'b1; sdrc_rd_n <= 1'b1;
            sdrc_data_len <= BURST[7:0]; sdrc_dqm <= 4'h0;
            sdrc_data <= 32'd0; sdrc_addr <= 21'd0;
            w_act <= 1'b0; r_act <= 1'b0; wn <= 5'd0;
            w_addr <= 21'd0; r_rem <= 5'd0; r_tmo <= 6'd0;
            rd_line <= 10'd0; rd_wcnt <= 10'd0; rd_started <= 1'b0;
        end else begin
            sdrc_wr_n <= 1'b1;
            sdrc_rd_n <= 1'b1;

            if (frame_start) begin
                w_addr <= nxt_phase[2:0] * 21'd230400;     // 写指针回到新帧首
                if (!rd_started) begin                     // 首次就绪时对齐读指针
                    rd_line <= 10'd0; rd_wcnt <= 10'd0;
                end
            end
            if (fb_ready && !rd_started) rd_started <= 1'b1;

            // 读返回计数（带超时保护）
            if (r_rem != 5'd0) begin
                if (sdrc_rd_valid) begin
                    r_rem <= r_rem - 1'b1;
                    r_tmo <= 6'd0;
                end else if (r_tmo != 6'h3F) begin
                    r_tmo <= r_tmo + 1'b1;
                end
            end

            if (w_act) begin
                if (wn >= BURST) begin
                    if (sdrc_busy_n) begin
                        w_act  <= 1'b0;
                        w_addr <= w_addr + BURST_ADDR;
                    end
                end else begin
                    sdrc_data <= wr_dout;
                    wn        <= wn + 1'b1;
                end
            end else if (r_act) begin
                if ((r_rem == 5'd0) || (r_tmo == 6'h3F)) begin
                    r_act <= 1'b0;
                    // 读指针推进：一帧 20 个突发/行
                    if (rd_wcnt == 10'd304) begin
                        rd_wcnt <= 10'd0;
                        rd_line <= (rd_line == 10'd719) ? 10'd0 : rd_line + 1'b1;
                    end else begin
                        rd_wcnt <= rd_wcnt + 10'd16;
                    end
                end
            end else begin
                if (w_gnt) begin
                    sdrc_wr_n     <= 1'b0;
                    sdrc_addr     <= w_addr;
                    sdrc_data     <= wr_dout;      // 命令拍即给出首字
                    sdrc_data_len <= BURST[7:0];
                    sdrc_dqm      <= 4'h0;
                    w_act         <= 1'b1;
                    wn            <= 5'd1;
                end else if (r_gnt) begin
                    sdrc_rd_n     <= 1'b0;
                    sdrc_addr     <= r_cur;
                    sdrc_data_len <= BURST[7:0];
                    r_act         <= 1'b1;
                    r_rem         <= BURST[4:0];
                    r_tmo         <= 6'd0;
                end
            end
        end
    end

    //==================================================================
    // 6. 性能计数器（每帧采样一次，在垂直消隐期内更新）
    //==================================================================
    reg [15:0] rd_b, wr_b, turn_c;
    reg        dir_d;
    reg [16:0] win_cnt;
    reg [19:0] busy_cnt, busy_win;

    wire bus_busy = sdrc_rd_valid || (w_act && (wn < BURST));
    wire [26:0] busy_mul = busy_win * 7'd100;    // 下一窗口用的占用率分子

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_b <= 0; wr_b <= 0; turn_c <= 0; dir_d <= 1'b0;
            win_cnt <= 0; busy_cnt <= 0; busy_win <= 0;
            stat_rd_kb <= 0; stat_wr_kb <= 0; stat_turn <= 0;
            stat_busy <= 0; bursts_frame <= 0; total_bursts <= 32'd0;
        end else begin
            dir_d <= dir;

            if (r_gnt | w_gnt) total_bursts <= total_bursts + 1'b1;

            // 2^17 周期固定窗口测总线占用率
            if (bus_busy) busy_cnt <= busy_cnt + 1'b1;
            if (win_cnt == 17'h1FFFF) begin
                win_cnt  <= 17'd0;
                busy_win <= busy_cnt;
                busy_cnt <= {19{1'b0}} + (bus_busy ? 1'b1 : 1'b0);
            end else begin
                win_cnt <= win_cnt + 1'b1;
            end

            // 每帧采样
            if (frame_start) begin
                stat_rd_kb   <= rd_b[13:4];          // 突发 x64B /1024 = >>4
                stat_wr_kb   <= wr_b[13:4];
                stat_turn    <= turn_c[9:0];
                bursts_frame <= rd_b + wr_b;
                // BUSY% = busy_win x 100 / 131072 = (busy_win x 100) >> 17
                stat_busy    <= busy_mul[24:17];     // = busy_win*100/131072
                rd_b   <= 16'd0;
                wr_b   <= 16'd0;
                turn_c <= 16'd0;
            end else begin
                if (r_gnt) rd_b <= rd_b + 1'b1;
                if (w_gnt) wr_b <= wr_b + 1'b1;
                if (dir != dir_d) turn_c <= turn_c + 1'b1;
            end
        end
    end

endmodule
