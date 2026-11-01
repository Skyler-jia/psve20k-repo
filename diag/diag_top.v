//======================================================================
// diag_top.v — SDRAM 诊断固件（只看 LED，不看屏幕）
//
// 流程：等 init_done → 往地址 0 写 16 个字（0xA5A50000+序号）
//       → 读回 16 个字并比对 → 结果上 LED
//
// LED 含义（LED 低电平点亮：O_led = ~status）
//   LED0 = init_done          （初始化 FSM 完成）
//   LED1..3 = 错误字数[2:0]    （0 = 全对）
//   LED4 = 测试完成 done
//
// 判读：
//   只有 LED0 亮            -> 卡在读命令阶段
//   LED0 + LED4 亮          -> ★ 读写全对，控制器没问题（问题在 sdram_fb 对接）
//   LED0 + LED4 + 若干错误灯 -> 能读回但数据错（时序/相位/模式寄存器）
//   全灭                    -> PLL 没锁或复位没出来
//======================================================================
`timescale 1ns/1ps

module diag_top (
    input  wire        I_clk,
    input  wire        I_key,
    input  wire        I_rst,
    output wire [4:0]  O_led,
    output wire        running,
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

    //------------------------------------------------------------------ 时钟
    wire serial_clk, clk, pll_lock;
    TMDS_rPLL u_pll (.clkin(I_clk), .clkout(serial_clk), .lock(pll_lock));
    CLKDIV u_clkdiv (          // 名字必须与 psve20k.sdc 里的 u_clkdiv/CLKOUT 对应
        .RESETN (pll_lock ),
        .HCLKIN (serial_clk),
        .CLKOUT (clk      ),
        .CALIB  (1'b1     )
    );
    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN    = "false";

    reg [15:0] rst_cnt;
    reg        rst_n_r;
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin rst_cnt <= 16'd0; rst_n_r <= 1'b0; end
        else if (rst_cnt != 16'hFFFF) begin rst_cnt <= rst_cnt + 1'b1; rst_n_r <= 1'b0; end
        else rst_n_r <= 1'b1;
    end
    wire rst_n = rst_n_r;

    //------------------------------------------------------------------ 控制器
    reg  [20:0] a_addr;
    reg  [7:0]  a_len;
    reg  [31:0] a_wdat;
    reg  [3:0]  a_dqm;
    reg         a_wr_n, a_rd_n;
    wire [31:0] a_rdat;
    wire        init_done, busy_n, rd_valid, wrd_ack;

    sdram_ctrl_my u_ctrl (
        .clk            (clk        ),
        .rst_n          (rst_n      ),
        .sdrc_addr      (a_addr     ),
        .sdrc_data_len  (a_len      ),
        .sdrc_data      (a_wdat     ),
        .sdrc_dqm       (a_dqm      ),
        .sdrc_wr_n      (a_wr_n     ),
        .sdrc_rd_n      (a_rd_n     ),
        .sdrc_data_q    (a_rdat     ),
        .sdrc_init_done (init_done  ),
        .sdrc_busy_n    (busy_n     ),
        .sdrc_rd_valid  (rd_valid   ),
        .sdrc_wrd_ack   (wrd_ack    ),
        .O_sdram_clk    (O_sdram_clk),
        .O_sdram_cke    (O_sdram_cke),
        .O_sdram_cs_n   (O_sdram_cs_n),
        .O_sdram_ras_n  (O_sdram_ras_n),
        .O_sdram_cas_n  (O_sdram_cas_n),
        .O_sdram_wen_n  (O_sdram_wen_n),
        .O_sdram_addr   (O_sdram_addr),
        .O_sdram_ba     (O_sdram_ba  ),
        .O_sdram_dqm    (O_sdram_dqm ),
        .IO_sdram_dq    (IO_sdram_dq )
    );

    //------------------------------------------------------------------ 测试 FSM
    localparam T_WAIT = 3'd0, T_WCMD = 3'd1, T_WDAT = 3'd2,
               T_BUSY = 3'd3, T_RCMD = 3'd4, T_RDAT = 3'd5, T_DONE = 3'd6;

    reg [2:0]  st;
    reg [4:0]  i;
    reg [15:0] err;
    reg        done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= T_WAIT; i <= 5'd0; err <= 16'd0; done <= 1'b0;
            a_addr <= 21'd0; a_len <= 8'd16; a_wdat <= 32'd0; a_dqm <= 4'd0;
            a_wr_n <= 1'b1; a_rd_n <= 1'b1;
        end else begin
            a_wr_n <= 1'b1;
            a_rd_n <= 1'b1;
            case (st)
                T_WAIT: begin
                    if (init_done) begin
                        a_addr <= 21'd0;
                        a_len  <= 8'd16;
                        a_wdat <= 32'hA5A5_0000;     // word0 随命令拍
                        a_wr_n <= 1'b0;
                        i      <= 5'd1;
                        st     <= T_WCMD;
                    end
                end
                T_WCMD: begin                          // 连续送 word1..word15
                    a_wdat <= 32'hA5A5_0000 + {27'd0, i};
                    if (i == 5'd15) st <= T_BUSY;
                    else i <= i + 1'b1;
                end
                T_WDAT: begin                          // 保留（不使用）
                    st <= T_BUSY;
                end
                T_BUSY: begin
                    if (busy_n) begin
                        a_addr <= 21'd0;
                        a_len  <= 8'd16;
                        a_rd_n <= 1'b0;               // 读命令
                        i      <= 5'd0;
                        st     <= T_RCMD;
                    end
                end
                T_RCMD: begin
                    st <= T_RDAT;
                end
                T_RDAT: begin
                    if (rd_valid) begin
                        if (a_rdat !== (32'hA5A5_0000 + {27'd0, i}))
                            err <= err + 1'b1;
                        if (i == 5'd15) begin
                            st   <= T_DONE;
                            done <= 1'b1;
                        end else i <= i + 1'b1;
                    end
                end
                T_DONE: begin
                    done <= 1'b1;
                end
                default: st <= T_WAIT;
            endcase
        end
    end

    //------------------------------------------------------------------ LED
    // 只有一颗灯（pin20）用「闪烁次数」编码结果，位置无关、不会看错：
    //   done=0（卡住）        -> 一直连闪 9 次 再停，重复
    //   done=1, err=0         -> 闪 1 次，停，重复     （读写全对）
    //   done=1, err=1..8      -> 闪 err+1 次
    //   done=1, err>8         -> 闪 9 次
    // 亮/灭各约 150ms，轮与轮之间停约 600ms。
    localparam [24:0] HP = 25'd11_100_000;      // 150ms @74.25MHz
    reg [24:0] tm;
    reg        on;
    reg [3:0]  cnt;
    reg [2:0]  gap;
    wire [3:0] nbl = (!done) ? 4'd9 :
                     (err == 16'd0) ? 4'd1 :
                     (err > 16'd8)  ? 4'd9 : (err[3:0] + 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tm <= 25'd0; on <= 1'b0; cnt <= 4'd0; gap <= 3'd0;
        end else if (tm == HP - 1'b1) begin
            tm <= 25'd0;
            if (on) begin
                on <= 1'b0;
                if (cnt >= (nbl - 1'b1)) begin
                    cnt <= 4'd0;
                    gap <= 3'd4;                    // 本轮结束，长停顿
                end else cnt <= cnt + 1'b1;
            end else if (gap != 3'd0) begin
                gap <= gap - 1'b1;
            end else begin
                on <= 1'b1;
            end
        end else tm <= tm + 1'b1;
    end

    assign running = on;
    assign O_led   = ~{4'b0000, init_done};         // LED0 = init_done，其余常灭

endmodule
