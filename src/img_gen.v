//======================================================================
// img_gen.v — 程序化动态图案发生器（纯 RTL，无 ROM 图像、无外部输入）
//
// 4 个视觉元素叠加，保证边缘检测"有的可测"：
//   1) 旋转条纹场  proj = (dx*cos + dy*sin) >> 14   —— 由逐帧旋转的角
//      度驱动，产生大量斜向锐利边缘（转动效果肉眼可见）
//   2) 移动棋盘格  ((x[7:5]+t) ^ (y[7:5]+t))        —— 高频锐利边缘
//   3) 呼吸圆环    |(|d|^2>>9 - c| < w              —— 曲线边缘
//   4) 对角渐变    x[10:3]+y[9:3]                   —— 平滑梯度
//
// 流水线 5 级（与 video_timing 的 SYNC_DLY 对齐），4 个乘法器
// 坐标：1280x720，中心 (640,360)
//======================================================================
`timescale 1ns/1ps

module img_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,     // 每帧一次
    input  wire [10:0] x,
    input  wire [9:0]  y,
    output reg  [7:0]  r_out,
    output reg  [7:0]  g_out,
    output reg  [7:0]  b_out,
    output reg  [7:0]  gray_out     // 亮度（供帧缓存写入），比 rgb 晚 1 拍
);

    //------------------------------------------------------------------
    // 正弦查表：64 点 1/4 波，Q1.14（16384 = 1.0）
    //------------------------------------------------------------------
    function [15:0] sin_tab;
        input [5:0] k;
        begin
            case (k)
                6'd0 : sin_tab = 16'd0;     6'd1 : sin_tab = 16'd402;
                6'd2 : sin_tab = 16'd804;   6'd3 : sin_tab = 16'd1205;
                6'd4 : sin_tab = 16'd1606;  6'd5 : sin_tab = 16'd2006;
                6'd6 : sin_tab = 16'd2404;  6'd7 : sin_tab = 16'd2801;
                6'd8 : sin_tab = 16'd3196;  6'd9 : sin_tab = 16'd3590;
                6'd10: sin_tab = 16'd3981;  6'd11: sin_tab = 16'd4370;
                6'd12: sin_tab = 16'd4756;  6'd13: sin_tab = 16'd5139;
                6'd14: sin_tab = 16'd5520;  6'd15: sin_tab = 16'd5897;
                6'd16: sin_tab = 16'd6270;  6'd17: sin_tab = 16'd6639;
                6'd18: sin_tab = 16'd7005;  6'd19: sin_tab = 16'd7366;
                6'd20: sin_tab = 16'd7723;  6'd21: sin_tab = 16'd8076;
                6'd22: sin_tab = 16'd8423;  6'd23: sin_tab = 16'd8765;
                6'd24: sin_tab = 16'd9102;  6'd25: sin_tab = 16'd9434;
                6'd26: sin_tab = 16'd9760;  6'd27: sin_tab = 16'd10080;
                6'd28: sin_tab = 16'd10394; 6'd29: sin_tab = 16'd10702;
                6'd30: sin_tab = 16'd11003; 6'd31: sin_tab = 16'd11297;
                6'd32: sin_tab = 16'd11585; 6'd33: sin_tab = 16'd11866;
                6'd34: sin_tab = 16'd12140; 6'd35: sin_tab = 16'd12406;
                6'd36: sin_tab = 16'd12665; 6'd37: sin_tab = 16'd12916;
                6'd38: sin_tab = 16'd13160; 6'd39: sin_tab = 16'd13395;
                6'd40: sin_tab = 16'd13623; 6'd41: sin_tab = 16'd13842;
                6'd42: sin_tab = 16'd14053; 6'd43: sin_tab = 16'd14256;
                6'd44: sin_tab = 16'd14449; 6'd45: sin_tab = 16'd14635;
                6'd46: sin_tab = 16'd14811; 6'd47: sin_tab = 16'd14978;
                6'd48: sin_tab = 16'd15137; 6'd49: sin_tab = 16'd15286;
                6'd50: sin_tab = 16'd15426; 6'd51: sin_tab = 16'd15557;
                6'd52: sin_tab = 16'd15679; 6'd53: sin_tab = 16'd15791;
                6'd54: sin_tab = 16'd15893; 6'd55: sin_tab = 16'd15986;
                6'd56: sin_tab = 16'd16069; 6'd57: sin_tab = 16'd16143;
                6'd58: sin_tab = 16'd16207; 6'd59: sin_tab = 16'd16261;
                6'd60: sin_tab = 16'd16305; 6'd61: sin_tab = 16'd16340;
                6'd62: sin_tab = 16'd16364; 6'd63: sin_tab = 16'd16379;
                default: sin_tab = 16'd0;
            endcase
        end
    endfunction

    // 8bit 相位 -> Q1.14 有符号正弦（4 象限折叠）
    function signed [15:0] sin_q;
        input [7:0] ph;
        reg [1:0] qd;
        reg [5:0] k;
        reg [15:0] v;
        begin
            qd = ph[7:6];
            k  = ph[5:0];
            v  = qd[0] ? sin_tab(6'd63 - k) : sin_tab(k);
            sin_q = qd[1] ? -v : v;          // 16bit 二进制补码取负，正是 -sin
        end
    endfunction

    //------------------------------------------------------------------
    // 角度与旋转系数：每帧转 3/256 圈（约 1.4 秒一圈）
    //------------------------------------------------------------------
    reg [7:0] ang;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ang <= 8'd0;
        else if (frame_start) ang <= ang + 8'd3;
    end

    reg signed [15:0] cos_q, sin_q_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cos_q   <= 16'sd16384;
            sin_q_r <= 16'sd0;
        end else begin
            cos_q   <= sin_q(ang + 8'd64);   // cos(a) = sin(a+90°)
            sin_q_r <= sin_q(ang);
        end
    end

    //------------------------------------------------------------------
    // 帧计数（驱动棋盘移动、圆环呼吸）
    //------------------------------------------------------------------
    reg [7:0] frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          frame <= 8'd0;
        else if (frame_start) frame <= frame + 1'b1;
    end

    //==================================================================
    // S1：坐标差分 / 棋盘 / 渐变
    //==================================================================
    reg signed [11:0] dx1, dy1;
    reg        [10:0] adx1;
    reg        [9:0]  ady1;
    reg               chk1;
    reg        [7:0]  grad1;

    wire signed [11:0] dx_c = $signed({1'b0, x}) - 12'sd640;
    wire signed [10:0] dy_c = $signed({1'b0, y}) - 11'sd360;
    wire [10:0] adx_c = dx_c[11] ? (~dx_c[10:0] + 1'b1) : dx_c[10:0];
    wire [9:0]  ady_c = dy_c[10] ? (~dy_c[9:0]  + 1'b1) : dy_c[9:0];

    wire [2:0]  chk_x = x[7:5] + frame[2:0];
    wire [2:0]  chk_y = y[7:5] + frame[4:2];
    wire        chk_c = chk_x[0] ^ chk_x[1] ^ chk_y[0] ^ chk_y[1];

    wire [8:0]  grad_c = {1'b0, x[10:3]} + {2'b0, y[9:3]};
    wire [7:0]  grad_s = grad_c[7:0];

    always @(posedge clk) begin
        dx1   <= dx_c;
        dy1   <= dy_c;          // 有符号赋值 -> 自动符号扩展
        adx1  <= adx_c;
        ady1  <= ady_c;
        chk1  <= chk_c;
        grad1 <= grad_s;
    end

    //==================================================================
    // S2：乘法（旋转投影 2 个 + 距离平方 2 个）
    //==================================================================
    reg signed [27:0] p1, p2;
    reg        [21:0] q1, q2;
    reg               chk2;
    reg        [7:0]  grad2;

    always @(posedge clk) begin
        p1    <= dx1 * cos_q;
        p2    <= dy1 * sin_q_r;
        q1    <= adx1 * adx1;
        q2    <= ady1 * ady1;
        chk2  <= chk1;
        grad2 <= grad1;
    end

    //==================================================================
    // S3：投影值与距离
    //==================================================================
    reg signed [15:0] proj;
    reg        [21:0] rr;
    reg               chk3;
    reg        [7:0]  grad3;

    always @(posedge clk) begin
        proj  <= (p1 + p2) >>> 14;
        rr    <= q1 + q2;
        chk3  <= chk2;
        grad3 <= grad2;
    end

    //==================================================================
    // S4：图案判定
    //==================================================================
    reg stripe, ring, chk4;
    reg [7:0] grad4;

    wire [11:0] rr_s = rr[20:9];                             // 等价 >>9，0..1053
    wire [10:0] ring_c = 11'd120 + {1'b0, frame[7:0], 1'b0} + {2'b0, frame[7:0]}; // 120+3*frame
    wire [11:0] ring_d = (rr_s > {1'b0, ring_c}) ? (rr_s - {1'b0, ring_c})
                                                 : ({1'b0, ring_c} - rr_s);

    always @(posedge clk) begin
        stripe <= proj[7] ^ proj[5];
        ring   <= (ring_d < 12'd70);
        chk4   <= chk3;
        grad4  <= grad3;
    end

    //==================================================================
    // S5：配色输出（带饱和）
    //==================================================================
    wire [7:0] base = {1'b0, grad4[7:1]};                    // 压暗一点让图案更跳
    wire [8:0] r_sum = {1'b0, base} + (stripe ? 9'd120 : 9'd0) + (ring ? 9'd90 : 9'd0);
    wire [8:0] g_sum = {1'b0, base} + (chk4   ? 9'd140 : 9'd0) + (ring ? 9'd55 : 9'd0);
    wire [8:0] b_sum = {1'b0, base} + (ring   ? 9'd190 : 9'd0) + (stripe ? 9'd35 : 9'd0);

    always @(posedge clk) begin
        r_out <= r_sum[8] ? 8'hFF : r_sum[7:0];
        g_out <= g_sum[8] ? 8'hFF : g_sum[7:0];
        b_out <= b_sum[8] ? 8'hFF : b_sum[7:0];
    end

    //------------------------------------------------------------------
    // 亮度 Y = (77R + 150G + 29B)/256（系数和恰为 256，右移 8 位即可）
    // 注意：用上一拍的 r/g/b 寄存器计算，与 rgb 输出天然对齐
    //------------------------------------------------------------------
    wire [17:0] ysum = r_out * 8'd77 + g_out * 8'd150 + b_out * 8'd29;

    always @(posedge clk) begin
        gray_out <= ysum[15:8];
    end

endmodule
