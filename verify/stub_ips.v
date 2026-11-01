//======================================================================
// stub_ips.v — 仅用于「不依赖 IP 的语法/综合检查」与仿真
//   ★ 绝对不要把本文件加入正式工程（会与真实 IP 冲突）
//   正式工程请添加：
//     - 官方例程里的 src/gowin_rpll/TMDS_rPLL.v
//     - 官方例程里的 src/dvi_tx/dvi_tx.v（内含 DVI_TX_Top）
//     - IP Core Generator 生成的 SDRAM Controller(With embedded SDRAM)
//======================================================================
`timescale 1ns/1ps

module DVI_TX_Top (
    input  wire       I_rst_n,
    input  wire       I_serial_clk,
    input  wire       I_rgb_clk,
    input  wire       I_rgb_vs,
    input  wire       I_rgb_hs,
    input  wire       I_rgb_de,
    input  wire [7:0] I_rgb_r,
    input  wire [7:0] I_rgb_g,
    input  wire [7:0] I_rgb_b,
    output wire       O_tmds_clk_p,
    output wire       O_tmds_clk_n,
    output wire [2:0] O_tmds_data_p,
    output wire [2:0] O_tmds_data_n
);
    // 注意：桩必须让"每一个数据位"都影响输出，否则综合器会把上游整条
    //       数据通路当作死逻辑优化掉（资源报告会失真）
    wire r7 = ^I_rgb_r;
    wire g7 = ^I_rgb_g;
    wire b7 = ^I_rgb_b;
    assign O_tmds_clk_p  = I_rgb_clk | I_rgb_de;
    assign O_tmds_clk_n  = ~(I_rgb_clk & I_rgb_hs);
    assign O_tmds_data_p = {r7, g7, b7};
    assign O_tmds_data_n = ~{r7, g7, b7};
endmodule

module SDRAM_controller_top_SIP (
    input  wire        I_sdrc_rst_n,
    input  wire        I_sdrc_clk,
    input  wire        I_sdram_clk,
    input  wire        I_sdrc_selfrefresh,
    input  wire        I_sdrc_power_down,
    input  wire        I_sdrc_wr_n,
    input  wire        I_sdrc_rd_n,
    input  wire [20:0] I_sdrc_addr,
    input  wire [7:0]  I_sdrc_data_len,
    input  wire [3:0]  I_sdrc_dqm,
    input  wire [31:0] I_sdrc_data,
    output wire [31:0] O_sdrc_data,
    output wire        O_sdrc_init_done,
    output wire        O_sdrc_busy_n,
    output wire        O_sdrc_rd_valid,
    output wire        O_sdrc_wrd_ack,
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
    // 让地址/数据/请求都参与输出，避免上游 FSM 与 FIFO 被优化掉
    assign O_sdrc_data      = I_sdrc_data ^ {11'b0, I_sdrc_addr};
    assign O_sdrc_init_done = 1'b1;

    reg busy_r, rdv_r;
    always @(posedge I_sdrc_clk) begin
        busy_r <= ~I_sdrc_wr_n;
        rdv_r  <= ~I_sdrc_rd_n;
    end
    assign O_sdrc_busy_n  = busy_r;
    assign O_sdrc_rd_valid = rdv_r;
    assign O_sdrc_wrd_ack  = busy_r;
    assign O_sdram_clk      = I_sdram_clk;
    assign O_sdram_cke      = 1'b1;
    assign O_sdram_cs_n     = 1'b1;
    assign O_sdram_ras_n    = 1'b1;
    assign O_sdram_cas_n    = 1'b1;
    assign O_sdram_wen_n    = 1'b1;
    assign O_sdram_addr     = 11'd0;
    assign O_sdram_ba       = 2'd0;
    assign O_sdram_dqm      = 4'h0;
    assign IO_sdram_dq      = 32'hzzzz_zzzz;
endmodule
