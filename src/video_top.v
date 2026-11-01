//======================================================================
// video_top.v — PSVE-20K「幻源引擎」顶层（v1.2）
//
//  img_gen(程序化动态图案) ──┬─ rgb_live/live_y ─────────────┐
//                           └─ gray ─> SDRAM 帧缓存 ─> gray_delay ─> img_proc
//                                                                      │
//  HDMI 1280x720p60 <── DVI_TX_Top <── OSD 叠加 <──────────────────────┘
//
//  显示模式（S1 短按循环 12 档）：
//    0 GRAY      1 BINARY    2 SOBEL     3 OVERLAY
//    4 LAPLACE   5 MEDIAN    6 MOTION    7 MOTIONOV    (时域帧差运动检测)
//    8 LIVE      9 FULLEDGE
//   10 WATERFAL 11 WF-SOBEL                            (时间切片瀑布图)
//
//  按键：
//    S1(pin87) 短按 = 换模式；长按 3 秒 = OSD 翻页（运行页 <-> 存储详情页）
//    S2(pin88) 短按 = 换延迟帧数；长按 0.4s 后每 0.15s 连发
//
//  ★ 若 SDRAM 尚未打通：SDRAM_BYPASS=1 全程绕开片内 SDRAM，
//    只靠 BSRAM 行缓存也能出完整画面（运动检测此时会退化为无延迟帧差）
//======================================================================
`timescale 1ns/1ps

module video_top
(
    input  wire        I_clk,           // 27MHz, pin4
    input  wire        I_key,           // S1, pin87（按下为高）
    input  wire        I_rst,           // S2, pin88（按下为高）
    output wire [4:0]  O_led,           // pin19..15
    output wire        running,         // pin20
    output wire        O_tmds_clk_p,
    output wire        O_tmds_clk_n,
    output wire [2:0]  O_tmds_data_p,
    output wire [2:0]  O_tmds_data_n,
    // 片内 SDRAM（GW2AR-18 集成 8MB，专用引脚，不写 .cst）
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);

    // ★ 使用片内 SDRAM 的完整设计：本行保持 1'b0。
    //   若 IP 还没生成、想先让画面出来，可改成 1'b1 绕开片内 SDRAM；
    //   注意这时必须把 sdram_ctrl_wrap.v（以及 IP 文件）从工程里禁用/移除，
    //   否则仍会报 "Cannot find module SDRAM_controller_top_SIP"。
    localparam SDRAM_BYPASS = 1'b0;

    //==================================================================
    // 0. 时钟与复位（PLL 配置照抄官方 HDMI 例程，勿改）
    //==================================================================
    wire serial_clk, pix_clk, pll_lock;

    TMDS_rPLL u_tmds_rpll (
        .clkin  (I_clk     ),
        .clkout (serial_clk),
        .lock   (pll_lock  )
    );

    CLKDIV u_clkdiv (
        .RESETN (pll_lock  ),
        .HCLKIN (serial_clk),
        .CLKOUT (pix_clk   ),
        .CALIB  (1'b1      )
    );
    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN    = "false";

    reg [15:0] rst_cnt;
    reg        rst_n_r;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            rst_cnt <= 16'd0;
            rst_n_r <= 1'b0;
        end else if (rst_cnt != 16'hFFFF) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_n_r <= 1'b0;
        end else begin
            rst_n_r <= 1'b1;
        end
    end
    wire rst_n = rst_n_r;

    //==================================================================
    // 1. 时序发生器
    //==================================================================
    wire        de, hs, vs;
    wire [10:0] x, xd;
    wire [9:0]  y, yd;
    wire        line_start, frame_start;

    video_timing #(.SYNC_DLY(6)) u_timing (
        .clk         (pix_clk    ),
        .rst_n       (rst_n      ),
        .de          (de         ),
        .hs          (hs         ),
        .vs          (vs         ),
        .x           (x          ),
        .y           (y          ),
        .xd          (xd         ),
        .yd          (yd         ),
        .line_start  (line_start ),
        .frame_start (frame_start)
    );

    //==================================================================
    // 2. 程序化图案发生器（图像源）
    //==================================================================
    wire [7:0] gen_r, gen_g, gen_b, gen_y;

    img_gen u_img_gen (
        .clk         (pix_clk    ),
        .rst_n       (rst_n      ),
        .frame_start (frame_start),
        .x           (x          ),
        .y           (y          ),
        .r_out       (gen_r      ),
        .g_out       (gen_g      ),
        .b_out       (gen_b      ),
        .gray_out    (gen_y      )
    );

    wire [23:0] rgb_live = {gen_r, gen_g, gen_b};

    //==================================================================
    // 3. 控制寄存器
    //==================================================================
    reg [3:0]  disp_mode;      // 12 档显示模式
    reg [3:0]  delay_sel;      // 普通模式=1..7 帧延迟；瀑布模式=1..8 带间帧差
    reg [1:0]  osd_page;       // OSD 页 0/1/2

    // 模式 -> 算法核 / 视图 / 瀑布图
    //  10 WATERFAL : 时间瀑布（8 带 = 8 个时刻，算法统一）
    //  11 ALGOGRID : 算法栅格（8 带 = 同一帧 + 8 种算法，S2 的带间帧差强制为 0）
    wire        waterfall = (disp_mode == 4'd10) || (disp_mode == 4'd11);
    wire [2:0]  algo = (disp_mode == 4'd8)  ? 3'd0 :      // LIVE    -> 灰度为底
                       (disp_mode == 4'd9)  ? 3'd2 :      // FULLEDGE-> sobel
                       (disp_mode == 4'd10) ? 3'd0 :      // 瀑布灰度
                       (disp_mode == 4'd11) ? 3'd0 :      // 算法栅格（下面按带覆盖）
                                              disp_mode[2:0];
    wire [1:0]  view = (disp_mode == 4'd8) ? 2'd2 :       // 全屏原图
                       (disp_mode == 4'd9) ? 2'd1 :       // 全屏算法
                       waterfall           ? 2'd1 :       // 瀑布：全屏算法
                                             2'd0;        // 左右分屏

    wire [3:0]  nxt_mode = (disp_mode == 4'd11) ? 4'd0 : disp_mode + 1'b1;
    wire        nxt_wf   = (nxt_mode == 4'd10) || (nxt_mode == 4'd11);

    // ---- 与像素输出对齐的坐标（xd/yd 是 SYNC_DLY=6，这里再延 LAT=4）----
    //      放在这里是因为后面按带切算法、画分隔线、OSD 都要用它
    reg [10:0] xo_sr0, xo_sr1, xo_sr2, xo_sr3;
    reg [9:0]  yo_sr0, yo_sr1, yo_sr2, yo_sr3;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            xo_sr0<=0; xo_sr1<=0; xo_sr2<=0; xo_sr3<=0;
            yo_sr0<=0; yo_sr1<=0; yo_sr2<=0; yo_sr3<=0;
        end else begin
            xo_sr0 <= xd;     yo_sr0 <= yd;
            xo_sr1 <= xo_sr0; yo_sr1 <= yo_sr0;
            xo_sr2 <= xo_sr1; yo_sr2 <= yo_sr1;
            xo_sr3 <= xo_sr2; yo_sr3 <= yo_sr2;
        end
    end

    // 720 行分 8 带，每带 90 行
    function [2:0] band_idx;
        input [9:0] ly;
        begin
            if      (ly < 90)  band_idx = 3'd0;
            else if (ly < 180) band_idx = 3'd1;
            else if (ly < 270) band_idx = 3'd2;
            else if (ly < 360) band_idx = 3'd3;
            else if (ly < 450) band_idx = 3'd4;
            else if (ly < 540) band_idx = 3'd5;
            else if (ly < 630) band_idx = 3'd6;
            else               band_idx = 3'd7;
        end
    endfunction

    // 算法栅格：带 k 用算法 k（带索引与算法编码一一对应）
    //   带 0 灰度 / 1 二值 / 2 Sobel / 3 边缘叠加 / 4 拉普拉斯 / 5 中值 / 6 运动 / 7 运动叠加
    wire [2:0] band_disp  = band_idx(yo_sr3);          // 与 rgb_out 对齐的行号分带
    wire       algo_grid  = (disp_mode == 4'd11);
    wire [2:0] algo_eff   = algo_grid ? band_disp : algo;
    wire [3:0] band_step  = algo_grid ? 4'd0 : delay_sel;
    wire       band_lbl_en = algo_grid;

    //==================================================================
    // 4. 帧缓存读通路（片内 SDRAM / 或直通降级）
    //==================================================================
    wire [7:0] fb_gray;
    wire       fb_de = de;

    wire        sdrc_init_done, sdrc_busy_n, sdrc_rd_valid, sdrc_wrd_ack, fb_ready;
    wire [31:0] sdrc_data_q;
    wire [20:0] sdrc_addr;
    wire [7:0]  sdrc_data_len;
    wire [31:0] sdrc_data;
    wire [3:0]  sdrc_dqm;
    wire        sdrc_wr_n, sdrc_rd_n;
    wire        fb_wr_ovf, fb_rd_und;
    wire [15:0] burst_cnt;
    wire [31:0] total_bursts;
    wire [9:0]  stat_rd_kb, stat_wr_kb, stat_turn;
    wire [7:0]  stat_busy;

    generate
    if (SDRAM_BYPASS) begin : g_bypass
        reg [7:0] d0,d1,d2,d3,d4,d5,d6;
        always @(posedge pix_clk) begin
            d0 <= gen_y; d1 <= d0; d2 <= d1; d3 <= d2; d4 <= d3; d5 <= d4; d6 <= d5;
        end
        assign fb_gray = d6;
        assign fb_ready = 1'b1;
        assign fb_wr_ovf = 1'b0;
        assign fb_rd_und = 1'b0;
        assign burst_cnt = 16'd0;
        assign total_bursts = 32'd0;
        assign stat_rd_kb = 10'd0;
        assign stat_wr_kb = 10'd0;
        assign stat_turn = 10'd0;
        assign stat_busy = 8'd0;
        assign sdrc_init_done = 1'b0;
        assign sdrc_busy_n = 1'b1;
        assign sdrc_rd_valid = 1'b0;
        assign sdrc_wrd_ack = 1'b0;
        assign sdrc_data_q = 32'd0;
        assign sdrc_addr = 21'd0;
        assign sdrc_data_len = 8'd16;
        assign sdrc_data = 32'd0;
        assign sdrc_dqm = 4'd0;
        assign sdrc_wr_n = 1'b1;
        assign sdrc_rd_n = 1'b1;
        assign O_sdram_clk   = 1'b0;
        assign O_sdram_cke   = 1'b0;
        assign O_sdram_cs_n  = 1'b1;
        assign O_sdram_ras_n = 1'b1;
        assign O_sdram_cas_n = 1'b1;
        assign O_sdram_wen_n = 1'b1;
        assign O_sdram_addr  = 11'd0;
        assign O_sdram_ba    = 2'd0;
        assign O_sdram_dqm   = 4'hF;
        assign IO_sdram_dq   = 32'hz;
    end else begin : g_sdram
        sdram_fb u_fb (
            .clk          (pix_clk      ),
            .rst_n        (rst_n        ),
            .wr_de        (de           ),
            .wr_gray      (gen_y        ),
            .frame_start  (frame_start  ),
            .rd_de        (de           ),
            .rd_gray      (fb_gray      ),
            .delay_sel    (delay_sel    ),
            .waterfall    (waterfall    ),
            .band_step    (band_step    ),
            .fb_ready     (fb_ready     ),
            .wr_overflow  (fb_wr_ovf    ),
            .rd_underrun  (fb_rd_und    ),
            .stat_rd_kb   (stat_rd_kb   ),
            .stat_wr_kb   (stat_wr_kb   ),
            .stat_turn    (stat_turn    ),
            .stat_busy    (stat_busy    ),
            .bursts_frame (burst_cnt    ),
            .total_bursts (total_bursts ),
            .sdrc_addr    (sdrc_addr    ),
            .sdrc_data_len(sdrc_data_len),
            .sdrc_data    (sdrc_data    ),
            .sdrc_dqm     (sdrc_dqm     ),
            .sdrc_wr_n    (sdrc_wr_n    ),
            .sdrc_rd_n    (sdrc_rd_n    ),
            .sdrc_data_q  (sdrc_data_q  ),
            .sdrc_init_done(sdrc_init_done),
            .sdrc_busy_n  (sdrc_busy_n  ),
            .sdrc_rd_valid(sdrc_rd_valid)
        );

        sdram_ctrl_wrap u_sdram_ctrl (
            .clk            (pix_clk       ),
            .rst_n          (rst_n         ),
            .sdrc_addr      (sdrc_addr     ),
            .sdrc_data_len  (sdrc_data_len ),
            .sdrc_data      (sdrc_data     ),
            .sdrc_dqm       (sdrc_dqm      ),
            .sdrc_wr_n      (sdrc_wr_n     ),
            .sdrc_rd_n      (sdrc_rd_n     ),
            .sdrc_data_q    (sdrc_data_q   ),
            .sdrc_init_done (sdrc_init_done),
            .sdrc_busy_n    (sdrc_busy_n   ),
            .sdrc_rd_valid  (sdrc_rd_valid ),
            .sdrc_wrd_ack   (sdrc_wrd_ack  ),
            .O_sdram_clk    (O_sdram_clk   ),
            .O_sdram_cke    (O_sdram_cke   ),
            .O_sdram_cs_n   (O_sdram_cs_n  ),
            .O_sdram_ras_n  (O_sdram_ras_n ),
            .O_sdram_cas_n  (O_sdram_cas_n ),
            .O_sdram_wen_n  (O_sdram_wen_n ),
            .O_sdram_addr   (O_sdram_addr  ),
            .O_sdram_ba     (O_sdram_ba    ),
            .O_sdram_dqm    (O_sdram_dqm   ),
            .IO_sdram_dq    (IO_sdram_dq   )
        );
    end
    endgenerate

    //==================================================================
    // 5. 算法流水线（Sobel / Laplace / 中值 / 运动检测）+ 分屏
    //==================================================================
    wire [23:0] rgb_out;
    wire        de_out;
    wire [9:0]  edge_k;

    img_proc u_proc (
        .clk         (pix_clk    ),
        .rst_n       (rst_n      ),
        .algo        (algo_eff   ),
        .view        (view       ),
        .thresh      (8'd128     ),
        .de_in       (fb_de      ),
        .x_in        (x          ),
        .gray_in     (fb_gray    ),
        .rgb_live    (rgb_live   ),
        .live_y      (gen_y      ),
        .frame_start (frame_start),
        .edge_k      (edge_k     ),
        .rgb_out     (rgb_out    ),
        .de_out      (de_out     )
    );

    //==================================================================
    // 6. 硬件 OSD（多页）
    //==================================================================
    wire [7:0] bw_mbps = burst_cnt[15:8];     // ≈ 突发数/帧 / 256

    // ---- 仪表盘计数器（第 2 页）----
    reg [26:0] sec_cnt;
    reg [9:0]  up_sec;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_cnt <= 27'd0;
            up_sec  <= 10'd0;
        end else if (sec_cnt == 27'd74_249_999) begin   // 74.25MHz -> 1 秒
            sec_cnt <= 27'd0;
            up_sec  <= (up_sec == 10'd999) ? 10'd0 : up_sec + 1'b1;
        end else begin
            sec_cnt <= sec_cnt + 1'b1;
        end
    end

    reg [31:0] frm_total;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n)                    frm_total <= 32'd0;
        else if (frame_start)          frm_total <= frm_total + 1'b1;
    end

    wire [9:0] frm_k = frm_total[19:10];              // 总帧数 /1024（单位 K 帧）
    wire [9:0] acc_m = total_bursts[29:20];           // 累计突发 /2^20（单位 M）

    // ---- 瀑布图带间暗分隔线（每 90 行的最后一行）----
    // 分隔线放在每带「头两行」：既分隔 8 个带，又正好遮住时间瀑布在带边界处
    // 3x3 窗口跨时间切片导致的 2 行混合伪影（算法栅格模式下所有带同帧，无伪影）
    function is_sep;
        input [9:0] ly;
        begin
            is_sep = (ly == 10'd0)   || (ly == 10'd1)   || (ly == 10'd90)  || (ly == 10'd91)  ||
                     (ly == 10'd180) || (ly == 10'd181) || (ly == 10'd270) || (ly == 10'd271) ||
                     (ly == 10'd360) || (ly == 10'd361) || (ly == 10'd450) || (ly == 10'd451) ||
                     (ly == 10'd540) || (ly == 10'd541) || (ly == 10'd630) || (ly == 10'd631);
        end
    endfunction
    wire        sep_line = waterfall && is_sep(yo_sr3);   // yo_sr3 与 rgb_out 对齐
    wire [23:0] rgb_mix  = sep_line ? 24'h101010 : rgb_out;

    wire [23:0] rgb_osd;
    wire        de_osd;

    osd u_osd (
        .clk       (pix_clk    ),
        .rst_n     (rst_n      ),
        .xd        (xo_sr3     ),
        .yd        (yo_sr3     ),
        .de        (de_out     ),
        .rgb_in    (rgb_mix    ),      // 瀑布带间分隔线已合成进去
        .page      (osd_page   ),
        .mode_idx  (disp_mode  ),
        .delay_sel (delay_sel  ),
        .wf_mode   (waterfall  ),
        .band_lbl  (band_lbl_en),
        .edge_k    (edge_k     ),
        .bw_mbps   (bw_mbps    ),
        .rd_kb     (stat_rd_kb ),
        .wr_kb     (stat_wr_kb ),
        .turn_cnt  (stat_turn  ),
        .busy_pct  (stat_busy  ),
        .up_sec    (up_sec     ),
        .frm_k     (frm_k      ),
        .acc_m     (acc_m      ),
        .rgb_out   (rgb_osd    ),
        .de_out    (de_osd     )
    );

    //==================================================================
    // 7. HDMI 输出
    //==================================================================
    DVI_TX_Top DVI_TX_Top_inst (
        .I_rst_n       (rst_n         ),
        .I_serial_clk  (serial_clk    ),
        .I_rgb_clk     (pix_clk       ),
        .I_rgb_vs      (vs            ),
        .I_rgb_hs      (hs            ),
        .I_rgb_de      (de_osd        ),
        .I_rgb_r       (rgb_osd[23:16]),
        .I_rgb_g       (rgb_osd[15:8] ),
        .I_rgb_b       (rgb_osd[7:0]  ),
        .O_tmds_clk_p  (O_tmds_clk_p  ),
        .O_tmds_clk_n  (O_tmds_clk_n  ),
        .O_tmds_data_p (O_tmds_data_p ),
        .O_tmds_data_n (O_tmds_data_n )
    );

    //==================================================================
    // 8. 按键：去抖 + (S1)短按换模式/长按3秒翻页 + (S2)长按连发
    //==================================================================
    reg [1:0]  k1_sync, k2_sync;
    reg [15:0] k1_cnt, k2_cnt;
    reg        k1_stb, k2_stb;
    reg        k1_d, k2_d;
    reg [27:0] h1;                 // S1 按住时长（3s @74.25MHz = 222.75e6）
    reg        s1_armed;           // 本次按住还没翻过页
    reg [24:0] h2, r2;             // S2 长按计时 / 连发节拍

    wire s1_edge    = k1_stb & ~k1_d;
    wire s2_edge    = k2_stb & ~k2_d;
    wire s1_hold3s  = k1_stb && (h1 >= 28'd222_750_000);
    wire s1_page    = s1_hold3s && s1_armed;
    wire s2_repeat  = (r2 == 25'd11_000_000);
    wire s2_pulse   = s2_edge | s2_repeat;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            k1_sync <= 2'd0; k2_sync <= 2'd0;
            k1_cnt  <= 16'd0; k2_cnt <= 16'd0;
            k1_stb  <= 1'b0;  k2_stb <= 1'b0;
            k1_d    <= 1'b0;  k2_d   <= 1'b0;
            h1 <= 28'd0; s1_armed <= 1'b1;
            h2 <= 25'd0; r2 <= 25'd0;
            disp_mode  <= 4'd2;               // 上电默认 SOBEL 分屏
            delay_sel  <= 4'd1;
            osd_page   <= 2'd0;
        end else begin
            k1_sync <= {k1_sync[0], I_key};
            k2_sync <= {k2_sync[0], I_rst};

            if (k1_sync[1] == k1_stb) k1_cnt <= 16'd0;
            else if (k1_cnt == 16'hFFFF) begin k1_stb <= k1_sync[1]; k1_cnt <= 16'd0; end
            else k1_cnt <= k1_cnt + 1'b1;

            if (k2_sync[1] == k2_stb) k2_cnt <= 16'd0;
            else if (k2_cnt == 16'hFFFF) begin k2_stb <= k2_sync[1]; k2_cnt <= 16'd0; end
            else k2_cnt <= k2_cnt + 1'b1;

            k1_d <= k1_stb;
            k2_d <= k2_stb;

            // ---- S1：按住计时 + 3 秒翻页（每次按住只翻一次）----
            if (k1_stb) begin
                if (h1 != 28'hFFFFFF) h1 <= h1 + 1'b1;
                if (s1_page) begin
                    osd_page <= (osd_page == 2'd2) ? 2'd0 : osd_page + 1'b1;
                    s1_armed <= 1'b0;
                end
            end else begin
                h1 <= 28'd0;
                s1_armed <= 1'b1;
            end
            if (s1_edge) begin                             // 短按：换模式
                disp_mode <= nxt_mode;
                // 从瀑布模式切回普通模式时，把帧差 8 夹回 7（8 会读到正在写的那帧）
                if (!nxt_wf && (delay_sel > 4'd7)) delay_sel <= 4'd7;
            end

            // ---- S2：按住 0.4s 后每 0.15s 连发 ----
            if (k2_stb) begin
                if (h2 != 25'h1FFFFFF) h2 <= h2 + 1'b1;
                if (h2 >= 25'd30_000_000) begin
                    if (r2 == 25'd11_000_000) r2 <= 25'd0;
                    else                      r2 <= r2 + 1'b1;
                end
            end else begin
                h2 <= 25'd0; r2 <= 25'd0;
            end
            // S2：普通模式调延迟(1..7，8 会读到正在写的帧)；瀑布模式调带间帧差(1..8)
            if (s2_pulse) begin
                if (waterfall)
                    delay_sel <= (delay_sel >= 4'd8) ? 4'd1 : delay_sel + 1'b1;
                else
                    delay_sel <= (delay_sel >= 4'd7) ? 4'd1 : delay_sel + 1'b1;
            end
        end
    end

    // LED[3:0] = 延迟档位（1..8 二进制）, LED[4] = SDRAM 初始化完成
    assign O_led = ~{sdrc_init_done, delay_sel};

    // 心跳：SDRAM 未就绪时快闪，就绪后慢闪
    reg [23:0] hb;
    always @(posedge pix_clk) hb <= hb + 1'b1;
    assign running = fb_ready ? hb[23] : hb[21];

endmodule
