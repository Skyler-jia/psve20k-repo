//======================================================================
// sdram_ctrl_wrap.v — 片内 SDRAM 控制器封装
//
// 这里只做一件事：把 Gowin IP 生成器出来的模块包一层，
// 使上层代码完全不关心 IP 的模块名。
//
// ★ 唯一需要你改的地方：下面 u_sdram 的模块名。
//   用 Gowin EDA -> Tools -> IP Core Generator ->
//   "SDRAM Controller(With embedded SDRAM)" 生成，
//   模块名填 SDRAM_controller_top_SIP（或你喜欢的名字），
//   然后把这个名字同步到这里即可。
//
//   IP 关键参数（GW2AR-18，固定值，无需手改）：
//     DATA_WIDTH = 32, BANK=2bit, ROW=11bit, COL=8bit
//     USER_ADDR_WIDTH = 21  ->  2M x 32bit = 8MB
//     地址 = {bank[1:0], row[10:0], col[7:0]}，线性字地址直接对应
//======================================================================
`timescale 1ns/1ps

module sdram_ctrl_wrap (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 用户接口 ----
    input  wire [20:0] sdrc_addr,
    input  wire [7:0]  sdrc_data_len,
    input  wire [31:0] sdrc_data,
    input  wire [3:0]  sdrc_dqm,
    input  wire        sdrc_wr_n,
    input  wire        sdrc_rd_n,
    output wire [31:0] sdrc_data_q,
    output wire        sdrc_init_done,
    output wire        sdrc_busy_n,
    output wire        sdrc_rd_valid,
    output wire        sdrc_wrd_ack,

    // ---- 片内 SDRAM 专用引脚（不要写进 .cst）----
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

    SDRAM_controller_top_SIP u_sdram
    (
        .I_sdrc_rst_n      (rst_n         ),
        .I_sdrc_clk        (clk           ),   // 用户时钟 = 像素钟 74.25MHz
        .I_sdram_clk       (clk           ),   // 与用户钟同源（官方 tb 亦如此）
        .I_sdrc_selfrefresh(1'b0          ),
        .I_sdrc_power_down (1'b0          ),
        .I_sdrc_wr_n       (sdrc_wr_n     ),
        .I_sdrc_rd_n       (sdrc_rd_n     ),
        .I_sdrc_addr       (sdrc_addr     ),
        .I_sdrc_data_len   (sdrc_data_len ),
        .I_sdrc_dqm        (sdrc_dqm      ),
        .I_sdrc_data       (sdrc_data     ),
        .O_sdrc_data       (sdrc_data_q   ),
        .O_sdrc_init_done  (sdrc_init_done),
        .O_sdrc_busy_n     (sdrc_busy_n   ),
        .O_sdrc_rd_valid   (sdrc_rd_valid ),
        .O_sdrc_wrd_ack    (sdrc_wrd_ack  ),
        .O_sdram_clk       (O_sdram_clk   ),
        .O_sdram_cke       (O_sdram_cke   ),
        .O_sdram_cs_n      (O_sdram_cs_n  ),
        .O_sdram_ras_n     (O_sdram_ras_n ),
        .O_sdram_cas_n     (O_sdram_cas_n ),
        .O_sdram_wen_n     (O_sdram_wen_n ),
        .O_sdram_addr      (O_sdram_addr  ),
        .O_sdram_ba        (O_sdram_ba    ),
        .O_sdram_dqm       (O_sdram_dqm   ),
        .IO_sdram_dq       (IO_sdram_dq   )
    );

endmodule
