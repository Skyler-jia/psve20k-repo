//======================================================================
// osd.v — 硬件字符 OSD v1.2（多页 + 性能计数器）
//
//  由像素逻辑直接叠加，不是软件字幕。SC=2 时字符放大 2 倍（演示更易读）
//
//  第 0 页（运行页）：
//     MODE:SOBEL                  P0
//     DLY:3 ECNT:412
//     BW:112MB/S
//
//  第 1 页（存储详情页，长按 S1 三秒翻过来）：
//     SDRAM STAT                  P1
//     RD:900KB WB:900KB
//     TO:048 BU:039%
//
//  ★ ECNT 会随图案旋转实时跳动，BW/RD/WB/TO/BU 来自 SDRAM 仲裁器计数器，
//    放视频或录屏伪造不出"随负载变化"的数字。
//
//  字库由 work/gen_font.py 从系统字体渲染生成，地址 = {ascii[5:0], row[3:0]}
//======================================================================
`timescale 1ns/1ps

module osd #(
    parameter SC = 2                 // 1 = 原尺寸 8x16；2 = 放大一倍
)(
    input  wire        clk,
    input  wire        rst_n,
    // 像素流（xd/yd 必须与 rgb_in/de 对齐）
    input  wire [10:0] xd,
    input  wire [9:0]  yd,
    input  wire        de,
    input  wire [23:0] rgb_in,
    // 显示值
    input  wire [1:0]  page,          // 0=运行页 1=存储详情页 2=仪表盘
    input  wire [3:0]  mode_idx,      // 12 种显示模式
    input  wire [3:0]  delay_sel,     // 延迟帧数 / 瀑布带间帧差
    input  wire        wf_mode,       // 1 = 当前处于瀑布模式（DLY 标签变 STP）
    input  wire        band_lbl,      // 1 = 在每条带右侧标注算法名（算法栅格模式）
    input  wire [9:0]  edge_k,        // 边缘像素数/1024
    input  wire [7:0]  bw_mbps,       // 带宽 MB/s
    input  wire [9:0]  rd_kb,         // 读 KB/帧
    input  wire [9:0]  wr_kb,         // 写 KB/帧
    input  wire [9:0]  turn_cnt,      // 换向次数/帧
    input  wire [7:0]  busy_pct,      // 总线占用率 %
    input  wire [9:0]  up_sec,        // 运行时长（秒，0..999）
    input  wire [9:0]  frm_k,         // 总帧数 /1024
    input  wire [9:0]  acc_m,         // 累计突发数 /2^20
    // 输出
    output reg  [23:0] rgb_out,
    output reg         de_out
);

    localparam OX0 = 11'd16;
    localparam OY0 = 10'd16;
    localparam [10:0] OW = 26 * 8 * SC;      // 26 列
    localparam [9:0]  OH =  3 * 16 * SC;     // 3 行
    localparam CW_SH = (SC == 2) ? 4 : 3;    // 单元格宽度移位
    localparam CH_SH = (SC == 2) ? 5 : 4;    // 行高移位
    localparam SZ_SH = (SC == 2) ? 1 : 0;    // 字符内像素放大

    //------------------------------------------------------------------
    // 1. 二进制 -> 3 位 BCD（double-dabble，组合逻辑）
    //------------------------------------------------------------------
    function [11:0] bin2bcd3;
        input [9:0] v;
        integer i;
        reg [11:0] b;
        begin
            b = 12'd0;
            for (i = 9; i >= 0; i = i - 1) begin
                if (b[3:0]  >= 4'd5) b[3:0]  = b[3:0]  + 4'd3;
                if (b[7:4]  >= 4'd5) b[7:4]  = b[7:4]  + 4'd3;
                if (b[11:8] >= 4'd5) b[11:8] = b[11:8] + 4'd3;
                b = {b[10:0], v[i]};
            end
            bin2bcd3 = b;
        end
    endfunction

    wire [11:0] bcd_e = bin2bcd3(edge_k);
    wire [11:0] bcd_b = bin2bcd3({2'b00, bw_mbps});
    wire [11:0] bcd_r = bin2bcd3(rd_kb);
    wire [11:0] bcd_w = bin2bcd3(wr_kb);
    wire [11:0] bcd_t = bin2bcd3(turn_cnt);
    wire [11:0] bcd_u = bin2bcd3({2'b00, busy_pct});
    wire [11:0] bcd_s = bin2bcd3(up_sec);
    wire [11:0] bcd_f = bin2bcd3(frm_k);
    wire [11:0] bcd_a = bin2bcd3(acc_m);

    //------------------------------------------------------------------
    // 2. 模式名字符串
    //------------------------------------------------------------------
    function [63:0] mode_name;
        input [3:0] m;
        begin
            case (m)
                4'd0 : mode_name = "GRAY    ";
                4'd1 : mode_name = "BINARY  ";
                4'd2 : mode_name = "SOBEL   ";
                4'd3 : mode_name = "OVERLAY ";
                4'd4 : mode_name = "LAPLACE ";
                4'd5 : mode_name = "MEDIAN  ";
                4'd6 : mode_name = "MOTION  ";
                4'd7 : mode_name = "MOTIONOV";
                4'd8 : mode_name = "LIVE    ";
                4'd9 : mode_name = "FULLEDGE";
                4'd10: mode_name = "WATERFAL";
                default: mode_name = "ALGOGRID";
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // 3. 字符查表
    //------------------------------------------------------------------
    function [7:0] char_at;
        input [3:0] row;
        input [4:0] col;
        reg [7:0]  ch;
        reg [63:0] nm;
        begin
            nm = mode_name(mode_idx);
            ch = 8'h20;
            if (page == 2'd0) begin
                // ---------------- 运行页 ----------------
                if (row == 4'd0) begin
                    case (col)
                        5'd0: ch = "M"; 5'd1: ch = "O"; 5'd2: ch = "D"; 5'd3: ch = "E";
                        5'd4: ch = ":";
                        5'd6:  ch = nm[63:56]; 5'd7:  ch = nm[55:48];
                        5'd8:  ch = nm[47:40]; 5'd9:  ch = nm[39:32];
                        5'd10: ch = nm[31:24]; 5'd11: ch = nm[23:16];
                        5'd12: ch = nm[15:8];  5'd13: ch = nm[7:0];
                        5'd23: ch = "P";       5'd24: ch = "0";
                        default: ch = 8'h20;
                    endcase
                end else if (row == 4'd1) begin
                    case (col)
                        5'd0: ch = wf_mode ? "S" : "D";
                        5'd1: ch = wf_mode ? "T" : "L";
                        5'd2: ch = wf_mode ? "P" : "Y";
                        5'd3: ch = ":";
                        5'd4: ch = 8'h30 + {4'b0, delay_sel};
                        5'd6: ch = "E"; 5'd7: ch = "C"; 5'd8: ch = "N"; 5'd9: ch = "T";
                        5'd10: ch = ":";
                        5'd11: ch = 8'h30 + {4'b0, bcd_e[11:8]};
                        5'd12: ch = 8'h30 + {4'b0, bcd_e[7:4]};
                        5'd13: ch = 8'h30 + {4'b0, bcd_e[3:0]};
                        default: ch = 8'h20;
                    endcase
                end else begin
                    case (col)
                        5'd0: ch = "B"; 5'd1: ch = "W"; 5'd2: ch = ":";
                        5'd3: ch = 8'h30 + {4'b0, bcd_b[11:8]};
                        5'd4: ch = 8'h30 + {4'b0, bcd_b[7:4]};
                        5'd5: ch = 8'h30 + {4'b0, bcd_b[3:0]};
                        5'd6: ch = "M"; 5'd7: ch = "B"; 5'd8: ch = "/"; 5'd9: ch = "S";
                        default: ch = 8'h20;
                    endcase
                end
            end else if (page == 2'd1) begin
                // ---------------- 存储详情页 ----------------
                if (row == 4'd0) begin
                    case (col)
                        5'd0: ch = "S"; 5'd1: ch = "D"; 5'd2: ch = "R"; 5'd3: ch = "A";
                        5'd4: ch = "M"; 5'd6: ch = "S"; 5'd7: ch = "T"; 5'd8: ch = "A";
                        5'd9: ch = "T";
                        5'd23: ch = "P"; 5'd24: ch = "1";
                        default: ch = 8'h20;
                    endcase
                end else if (row == 4'd1) begin
                    case (col)
                        5'd0: ch = "R"; 5'd1: ch = "D"; 5'd2: ch = ":";
                        5'd3: ch = 8'h30 + {4'b0, bcd_r[11:8]};
                        5'd4: ch = 8'h30 + {4'b0, bcd_r[7:4]};
                        5'd5: ch = 8'h30 + {4'b0, bcd_r[3:0]};
                        5'd6: ch = "K"; 5'd7: ch = "B";
                        5'd9: ch = "W"; 5'd10: ch = "B"; 5'd11: ch = ":";
                        5'd12: ch = 8'h30 + {4'b0, bcd_w[11:8]};
                        5'd13: ch = 8'h30 + {4'b0, bcd_w[7:4]};
                        5'd14: ch = 8'h30 + {4'b0, bcd_w[3:0]};
                        5'd15: ch = "K"; 5'd16: ch = "B";
                        default: ch = 8'h20;
                    endcase
                end else begin
                    case (col)
                        5'd0: ch = "T"; 5'd1: ch = "O"; 5'd2: ch = ":";
                        5'd3: ch = 8'h30 + {4'b0, bcd_t[11:8]};
                        5'd4: ch = 8'h30 + {4'b0, bcd_t[7:4]};
                        5'd5: ch = 8'h30 + {4'b0, bcd_t[3:0]};
                        5'd7: ch = "B"; 5'd8: ch = "U"; 5'd9: ch = ":";
                        5'd10: ch = 8'h30 + {4'b0, bcd_u[11:8]};
                        5'd11: ch = 8'h30 + {4'b0, bcd_u[7:4]};
                        5'd12: ch = 8'h30 + {4'b0, bcd_u[3:0]};
                        5'd13: ch = "%";
                        default: ch = 8'h20;
                    endcase
                end
            end else begin
                // ---------------- 仪表盘页 ----------------
                if (row == 4'd0) begin
                    case (col)
                        5'd0: ch = "R"; 5'd1: ch = "U"; 5'd2: ch = "N";
                        5'd4: ch = "D"; 5'd5: ch = "A"; 5'd6: ch = "S"; 5'd7: ch = "H";
                        5'd8: ch = "B"; 5'd9: ch = "O"; 5'd10: ch = "A"; 5'd11: ch = "R";
                        5'd12: ch = "D";
                        5'd23: ch = "P"; 5'd24: ch = "2";
                        default: ch = 8'h20;
                    endcase
                end else if (row == 4'd1) begin
                    case (col)
                        5'd0: ch = "U"; 5'd1: ch = "P"; 5'd2: ch = ":";
                        5'd3: ch = 8'h30 + {4'b0, bcd_s[11:8]};
                        5'd4: ch = 8'h30 + {4'b0, bcd_s[7:4]};
                        5'd5: ch = 8'h30 + {4'b0, bcd_s[3:0]};
                        5'd6: ch = "S";
                        5'd8: ch = "F"; 5'd9: ch = "R"; 5'd10: ch = "M"; 5'd11: ch = ":";
                        5'd12: ch = 8'h30 + {4'b0, bcd_f[11:8]};
                        5'd13: ch = 8'h30 + {4'b0, bcd_f[7:4]};
                        5'd14: ch = 8'h30 + {4'b0, bcd_f[3:0]};
                        5'd15: ch = "K";
                        default: ch = 8'h20;
                    endcase
                end else begin
                    case (col)
                        5'd0: ch = "A"; 5'd1: ch = "C"; 5'd2: ch = "C"; 5'd3: ch = ":";
                        5'd4: ch = 8'h30 + {4'b0, bcd_a[11:8]};
                        5'd5: ch = 8'h30 + {4'b0, bcd_a[7:4]};
                        5'd6: ch = 8'h30 + {4'b0, bcd_a[3:0]};
                        5'd7: ch = "M";
                        5'd9: ch = "B"; 5'd10: ch = "U"; 5'd11: ch = "R";
                        5'd12: ch = "S"; 5'd13: ch = "T"; 5'd14: ch = "S";
                        default: ch = 8'h20;
                    endcase
                end
            end
            char_at = ch;
        end
    endfunction

    //------------------------------------------------------------------
    // 4. 像素位置 -> 字符坐标
    //------------------------------------------------------------------
    wire        in_osd = (xd >= OX0) && (xd < OX0 + OW) && (yd >= OY0) && (yd < OY0 + OH);
    wire [10:0] ox     = xd - OX0;
    wire [9:0]  oy     = yd - OY0;
    wire [10:0] colw   = ox >> CW_SH;
    wire [9:0]  roww   = oy >> CH_SH;
    wire [4:0]  col    = colw[4:0];                      // 0..25
    wire [3:0]  row    = roww[3:0];                      // 0..2
    wire [3:0]  grow   = (oy >> SZ_SH) & 4'hF;           // 字符内行 0..15
    wire [2:0]  bitx   = (ox >> SZ_SH) & 3'h7;           // 字符内列 0..7
    wire [7:0]  chaddr = char_at(row, col);

    //------------------------------------------------------------------
    // 4b. 带标签：每条带右端标注算法名（只在算法栅格模式）
    //     区域 x ∈ [1152,1280)，y ∈ [90k+4, 90k+4+16*SC)
    //     放右端是为了与左上角主 OSD 的 x 区间完全不重叠，
    //     这样两者可以分时复用同一个字库 ROM，省一个 BSRAM
    //------------------------------------------------------------------
    wire [2:0] lbl_band = (yd < 90)  ? 3'd0 : (yd < 180) ? 3'd1 :
                          (yd < 270) ? 3'd2 : (yd < 360) ? 3'd3 :
                          (yd < 450) ? 3'd4 : (yd < 540) ? 3'd5 :
                          (yd < 630) ? 3'd6 : 3'd7;
    // 带起始行 = band*90 = (band<<6)+(band<<4)+(band<<3)+(band<<1)
    wire [9:0] band_off = {1'b0, lbl_band, 6'b0} + {3'b0, lbl_band, 4'b0}
                        + {4'b0, lbl_band, 3'b0} + {6'b0, lbl_band, 1'b0};
    wire [9:0] lbl_roff = yd - band_off;
    localparam [10:0] LBX0 = 11'd1152;

    wire lbl_in = band_lbl
                && (xd >= LBX0) && (xd < LBX0 + 8*8*SC)
                && (lbl_roff >= 10'd4) && (lbl_roff < 10'd4 + 16*SC);
    wire [10:0] lbl_colw = (xd - LBX0) >> CW_SH;
    wire [9:0]  lbl_roww = (lbl_roff - 10'd4) >> SZ_SH;
    wire [4:0]  lbl_col  = lbl_colw[4:0];
    wire [3:0]  lbl_row  = lbl_roww[3:0];
    wire [2:0] lbl_bit = ((xd - LBX0) >> SZ_SH) & 3'h7;

    wire [63:0] lbl_str = mode_name({1'b0, lbl_band});
    wire [7:0]  lbl_ch  = lbl_str[(7 - lbl_col) * 8 +: 8];

    //------------------------------------------------------------------
    // 5. 字库 ROM（同步读 1 拍）
    //------------------------------------------------------------------
    reg [7:0] rom [0:1023];
    initial begin
// 自动生成：8x16 点阵字库，地址 = {ascii[5:0], row[3:0]}，bit7 为最左像素
// 由 work/gen_font.py 生成，勿手改
        rom[   0] = 8'h00; rom[   1] = 8'h00; rom[   2] = 8'h00; rom[   3] = 8'h00; rom[   4] = 8'h00; rom[   5] = 8'h00; rom[   6] = 8'h00; rom[   7] = 8'h00;
        rom[   8] = 8'h00; rom[   9] = 8'h00; rom[  10] = 8'h00; rom[  11] = 8'h00; rom[  12] = 8'h00; rom[  13] = 8'h00; rom[  14] = 8'h00; rom[  15] = 8'h00;
        rom[  16] = 8'h00; rom[  17] = 8'h00; rom[  18] = 8'h00; rom[  19] = 8'h18; rom[  20] = 8'h38; rom[  21] = 8'h2C; rom[  22] = 8'h24; rom[  23] = 8'h64;
        rom[  24] = 8'h66; rom[  25] = 8'h7E; rom[  26] = 8'hC2; rom[  27] = 8'hC3; rom[  28] = 8'h00; rom[  29] = 8'h00; rom[  30] = 8'h00; rom[  31] = 8'h00;
        rom[  32] = 8'h00; rom[  33] = 8'h00; rom[  34] = 8'h00; rom[  35] = 8'h7C; rom[  36] = 8'h46; rom[  37] = 8'h46; rom[  38] = 8'h44; rom[  39] = 8'h7C;
        rom[  40] = 8'h46; rom[  41] = 8'h42; rom[  42] = 8'h46; rom[  43] = 8'h7C; rom[  44] = 8'h00; rom[  45] = 8'h00; rom[  46] = 8'h00; rom[  47] = 8'h00;
        rom[  48] = 8'h00; rom[  49] = 8'h00; rom[  50] = 8'h00; rom[  51] = 8'h1C; rom[  52] = 8'h62; rom[  53] = 8'h40; rom[  54] = 8'h40; rom[  55] = 8'h40;
        rom[  56] = 8'h40; rom[  57] = 8'h40; rom[  58] = 8'h62; rom[  59] = 8'h3C; rom[  60] = 8'h00; rom[  61] = 8'h00; rom[  62] = 8'h00; rom[  63] = 8'h00;
        rom[  64] = 8'h00; rom[  65] = 8'h00; rom[  66] = 8'h00; rom[  67] = 8'h78; rom[  68] = 8'h46; rom[  69] = 8'h42; rom[  70] = 8'h42; rom[  71] = 8'h42;
        rom[  72] = 8'h42; rom[  73] = 8'h46; rom[  74] = 8'h44; rom[  75] = 8'h78; rom[  76] = 8'h00; rom[  77] = 8'h00; rom[  78] = 8'h00; rom[  79] = 8'h00;
        rom[  80] = 8'h00; rom[  81] = 8'h00; rom[  82] = 8'h00; rom[  83] = 8'h7E; rom[  84] = 8'h60; rom[  85] = 8'h60; rom[  86] = 8'h60; rom[  87] = 8'h7C;
        rom[  88] = 8'h60; rom[  89] = 8'h60; rom[  90] = 8'h60; rom[  91] = 8'h7E; rom[  92] = 8'h00; rom[  93] = 8'h00; rom[  94] = 8'h00; rom[  95] = 8'h00;
        rom[  96] = 8'h00; rom[  97] = 8'h00; rom[  98] = 8'h00; rom[  99] = 8'h7E; rom[ 100] = 8'h60; rom[ 101] = 8'h60; rom[ 102] = 8'h60; rom[ 103] = 8'h7C;
        rom[ 104] = 8'h60; rom[ 105] = 8'h60; rom[ 106] = 8'h60; rom[ 107] = 8'h60; rom[ 108] = 8'h00; rom[ 109] = 8'h00; rom[ 110] = 8'h00; rom[ 111] = 8'h00;
        rom[ 112] = 8'h00; rom[ 113] = 8'h00; rom[ 114] = 8'h00; rom[ 115] = 8'h1C; rom[ 116] = 8'h62; rom[ 117] = 8'h40; rom[ 118] = 8'hC0; rom[ 119] = 8'hCE;
        rom[ 120] = 8'hC2; rom[ 121] = 8'h42; rom[ 122] = 8'h62; rom[ 123] = 8'h3E; rom[ 124] = 8'h00; rom[ 125] = 8'h00; rom[ 126] = 8'h00; rom[ 127] = 8'h00;
        rom[ 128] = 8'h00; rom[ 129] = 8'h00; rom[ 130] = 8'h00; rom[ 131] = 8'h42; rom[ 132] = 8'h42; rom[ 133] = 8'h42; rom[ 134] = 8'h42; rom[ 135] = 8'h7E;
        rom[ 136] = 8'h42; rom[ 137] = 8'h42; rom[ 138] = 8'h42; rom[ 139] = 8'h42; rom[ 140] = 8'h00; rom[ 141] = 8'h00; rom[ 142] = 8'h00; rom[ 143] = 8'h00;
        rom[ 144] = 8'h00; rom[ 145] = 8'h00; rom[ 146] = 8'h00; rom[ 147] = 8'h7E; rom[ 148] = 8'h18; rom[ 149] = 8'h18; rom[ 150] = 8'h18; rom[ 151] = 8'h18;
        rom[ 152] = 8'h18; rom[ 153] = 8'h18; rom[ 154] = 8'h18; rom[ 155] = 8'h7E; rom[ 156] = 8'h00; rom[ 157] = 8'h00; rom[ 158] = 8'h00; rom[ 159] = 8'h00;
        rom[ 160] = 8'h00; rom[ 161] = 8'h00; rom[ 162] = 8'h00; rom[ 163] = 8'h7C; rom[ 164] = 8'h04; rom[ 165] = 8'h04; rom[ 166] = 8'h04; rom[ 167] = 8'h04;
        rom[ 168] = 8'h04; rom[ 169] = 8'h04; rom[ 170] = 8'h4C; rom[ 171] = 8'h38; rom[ 172] = 8'h00; rom[ 173] = 8'h00; rom[ 174] = 8'h00; rom[ 175] = 8'h00;
        rom[ 176] = 8'h00; rom[ 177] = 8'h00; rom[ 178] = 8'h00; rom[ 179] = 8'h46; rom[ 180] = 8'h4C; rom[ 181] = 8'h48; rom[ 182] = 8'h50; rom[ 183] = 8'h70;
        rom[ 184] = 8'h50; rom[ 185] = 8'h48; rom[ 186] = 8'h4C; rom[ 187] = 8'h46; rom[ 188] = 8'h00; rom[ 189] = 8'h00; rom[ 190] = 8'h00; rom[ 191] = 8'h00;
        rom[ 192] = 8'h00; rom[ 193] = 8'h00; rom[ 194] = 8'h00; rom[ 195] = 8'h20; rom[ 196] = 8'h20; rom[ 197] = 8'h20; rom[ 198] = 8'h20; rom[ 199] = 8'h20;
        rom[ 200] = 8'h20; rom[ 201] = 8'h20; rom[ 202] = 8'h20; rom[ 203] = 8'h3E; rom[ 204] = 8'h00; rom[ 205] = 8'h00; rom[ 206] = 8'h00; rom[ 207] = 8'h00;
        rom[ 208] = 8'h00; rom[ 209] = 8'h00; rom[ 210] = 8'h00; rom[ 211] = 8'h46; rom[ 212] = 8'h66; rom[ 213] = 8'h62; rom[ 214] = 8'h6A; rom[ 215] = 8'hDA;
        rom[ 216] = 8'hD2; rom[ 217] = 8'hC2; rom[ 218] = 8'hC2; rom[ 219] = 8'hC2; rom[ 220] = 8'h00; rom[ 221] = 8'h00; rom[ 222] = 8'h00; rom[ 223] = 8'h00;
        rom[ 224] = 8'h00; rom[ 225] = 8'h00; rom[ 226] = 8'h00; rom[ 227] = 8'h62; rom[ 228] = 8'h62; rom[ 229] = 8'h72; rom[ 230] = 8'h52; rom[ 231] = 8'h52;
        rom[ 232] = 8'h4A; rom[ 233] = 8'h4A; rom[ 234] = 8'h46; rom[ 235] = 8'h46; rom[ 236] = 8'h00; rom[ 237] = 8'h00; rom[ 238] = 8'h00; rom[ 239] = 8'h00;
        rom[ 240] = 8'h00; rom[ 241] = 8'h00; rom[ 242] = 8'h00; rom[ 243] = 8'h3C; rom[ 244] = 8'h66; rom[ 245] = 8'h42; rom[ 246] = 8'hC2; rom[ 247] = 8'hC2;
        rom[ 248] = 8'hC2; rom[ 249] = 8'h42; rom[ 250] = 8'h66; rom[ 251] = 8'h3C; rom[ 252] = 8'h00; rom[ 253] = 8'h00; rom[ 254] = 8'h00; rom[ 255] = 8'h00;
        rom[ 256] = 8'h00; rom[ 257] = 8'h00; rom[ 258] = 8'h00; rom[ 259] = 8'h7C; rom[ 260] = 8'h46; rom[ 261] = 8'h42; rom[ 262] = 8'h42; rom[ 263] = 8'h44;
        rom[ 264] = 8'h78; rom[ 265] = 8'h40; rom[ 266] = 8'h40; rom[ 267] = 8'h40; rom[ 268] = 8'h00; rom[ 269] = 8'h00; rom[ 270] = 8'h00; rom[ 271] = 8'h00;
        rom[ 272] = 8'h00; rom[ 273] = 8'h00; rom[ 274] = 8'h00; rom[ 275] = 8'h3C; rom[ 276] = 8'h66; rom[ 277] = 8'h42; rom[ 278] = 8'hC2; rom[ 279] = 8'hC2;
        rom[ 280] = 8'hC2; rom[ 281] = 8'h42; rom[ 282] = 8'h66; rom[ 283] = 8'h3C; rom[ 284] = 8'h18; rom[ 285] = 8'h0E; rom[ 286] = 8'h00; rom[ 287] = 8'h00;
        rom[ 288] = 8'h00; rom[ 289] = 8'h00; rom[ 290] = 8'h00; rom[ 291] = 8'h7C; rom[ 292] = 8'h44; rom[ 293] = 8'h46; rom[ 294] = 8'h44; rom[ 295] = 8'h78;
        rom[ 296] = 8'h4C; rom[ 297] = 8'h44; rom[ 298] = 8'h46; rom[ 299] = 8'h42; rom[ 300] = 8'h00; rom[ 301] = 8'h00; rom[ 302] = 8'h00; rom[ 303] = 8'h00;
        rom[ 304] = 8'h00; rom[ 305] = 8'h00; rom[ 306] = 8'h00; rom[ 307] = 8'h3C; rom[ 308] = 8'h60; rom[ 309] = 8'h40; rom[ 310] = 8'h60; rom[ 311] = 8'h38;
        rom[ 312] = 8'h06; rom[ 313] = 8'h06; rom[ 314] = 8'h06; rom[ 315] = 8'h7C; rom[ 316] = 8'h00; rom[ 317] = 8'h00; rom[ 318] = 8'h00; rom[ 319] = 8'h00;
        rom[ 320] = 8'h00; rom[ 321] = 8'h00; rom[ 322] = 8'h00; rom[ 323] = 8'h7E; rom[ 324] = 8'h18; rom[ 325] = 8'h18; rom[ 326] = 8'h18; rom[ 327] = 8'h18;
        rom[ 328] = 8'h18; rom[ 329] = 8'h18; rom[ 330] = 8'h18; rom[ 331] = 8'h18; rom[ 332] = 8'h00; rom[ 333] = 8'h00; rom[ 334] = 8'h00; rom[ 335] = 8'h00;
        rom[ 336] = 8'h00; rom[ 337] = 8'h00; rom[ 338] = 8'h00; rom[ 339] = 8'h42; rom[ 340] = 8'h42; rom[ 341] = 8'h42; rom[ 342] = 8'h42; rom[ 343] = 8'h42;
        rom[ 344] = 8'h42; rom[ 345] = 8'h42; rom[ 346] = 8'h66; rom[ 347] = 8'h3C; rom[ 348] = 8'h00; rom[ 349] = 8'h00; rom[ 350] = 8'h00; rom[ 351] = 8'h00;
        rom[ 352] = 8'h00; rom[ 353] = 8'h00; rom[ 354] = 8'h00; rom[ 355] = 8'hC3; rom[ 356] = 8'hC2; rom[ 357] = 8'h42; rom[ 358] = 8'h66; rom[ 359] = 8'h64;
        rom[ 360] = 8'h24; rom[ 361] = 8'h3C; rom[ 362] = 8'h38; rom[ 363] = 8'h18; rom[ 364] = 8'h00; rom[ 365] = 8'h00; rom[ 366] = 8'h00; rom[ 367] = 8'h00;
        rom[ 368] = 8'h00; rom[ 369] = 8'h00; rom[ 370] = 8'h00; rom[ 371] = 8'hC2; rom[ 372] = 8'hC2; rom[ 373] = 8'hC2; rom[ 374] = 8'hD2; rom[ 375] = 8'h5A;
        rom[ 376] = 8'h5A; rom[ 377] = 8'h6A; rom[ 378] = 8'h66; rom[ 379] = 8'h66; rom[ 380] = 8'h00; rom[ 381] = 8'h00; rom[ 382] = 8'h00; rom[ 383] = 8'h00;
        rom[ 384] = 8'h00; rom[ 385] = 8'h00; rom[ 386] = 8'h00; rom[ 387] = 8'h42; rom[ 388] = 8'h64; rom[ 389] = 8'h2C; rom[ 390] = 8'h38; rom[ 391] = 8'h18;
        rom[ 392] = 8'h38; rom[ 393] = 8'h2C; rom[ 394] = 8'h66; rom[ 395] = 8'hC2; rom[ 396] = 8'h00; rom[ 397] = 8'h00; rom[ 398] = 8'h00; rom[ 399] = 8'h00;
        rom[ 400] = 8'h00; rom[ 401] = 8'h00; rom[ 402] = 8'h00; rom[ 403] = 8'hC2; rom[ 404] = 8'h46; rom[ 405] = 8'h64; rom[ 406] = 8'h2C; rom[ 407] = 8'h38;
        rom[ 408] = 8'h18; rom[ 409] = 8'h18; rom[ 410] = 8'h18; rom[ 411] = 8'h18; rom[ 412] = 8'h00; rom[ 413] = 8'h00; rom[ 414] = 8'h00; rom[ 415] = 8'h00;
        rom[ 416] = 8'h00; rom[ 417] = 8'h00; rom[ 418] = 8'h00; rom[ 419] = 8'h7E; rom[ 420] = 8'h04; rom[ 421] = 8'h0C; rom[ 422] = 8'h08; rom[ 423] = 8'h10;
        rom[ 424] = 8'h10; rom[ 425] = 8'h20; rom[ 426] = 8'h60; rom[ 427] = 8'h7E; rom[ 428] = 8'h00; rom[ 429] = 8'h00; rom[ 430] = 8'h00; rom[ 431] = 8'h00;
        rom[ 512] = 8'h00; rom[ 513] = 8'h00; rom[ 514] = 8'h00; rom[ 515] = 8'h00; rom[ 516] = 8'h00; rom[ 517] = 8'h00; rom[ 518] = 8'h00; rom[ 519] = 8'h00;
        rom[ 520] = 8'h00; rom[ 521] = 8'h00; rom[ 522] = 8'h00; rom[ 523] = 8'h00; rom[ 524] = 8'h00; rom[ 525] = 8'h00; rom[ 526] = 8'h00; rom[ 527] = 8'h00;
        rom[ 528] = 8'h00; rom[ 529] = 8'h00; rom[ 530] = 8'h00; rom[ 531] = 8'h00; rom[ 532] = 8'h00; rom[ 533] = 8'h00; rom[ 534] = 8'h00; rom[ 535] = 8'h00;
        rom[ 536] = 8'h00; rom[ 537] = 8'h00; rom[ 538] = 8'h00; rom[ 539] = 8'h00; rom[ 540] = 8'h00; rom[ 541] = 8'h00; rom[ 542] = 8'h00; rom[ 543] = 8'h00;
        rom[ 544] = 8'h00; rom[ 545] = 8'h00; rom[ 546] = 8'h00; rom[ 547] = 8'h00; rom[ 548] = 8'h00; rom[ 549] = 8'h00; rom[ 550] = 8'h00; rom[ 551] = 8'h00;
        rom[ 552] = 8'h00; rom[ 553] = 8'h00; rom[ 554] = 8'h00; rom[ 555] = 8'h00; rom[ 556] = 8'h00; rom[ 557] = 8'h00; rom[ 558] = 8'h00; rom[ 559] = 8'h00;
        rom[ 560] = 8'h00; rom[ 561] = 8'h00; rom[ 562] = 8'h00; rom[ 563] = 8'h00; rom[ 564] = 8'h00; rom[ 565] = 8'h00; rom[ 566] = 8'h00; rom[ 567] = 8'h00;
        rom[ 568] = 8'h00; rom[ 569] = 8'h00; rom[ 570] = 8'h00; rom[ 571] = 8'h00; rom[ 572] = 8'h00; rom[ 573] = 8'h00; rom[ 574] = 8'h00; rom[ 575] = 8'h00;
        rom[ 576] = 8'h00; rom[ 577] = 8'h00; rom[ 578] = 8'h00; rom[ 579] = 8'h00; rom[ 580] = 8'h00; rom[ 581] = 8'h00; rom[ 582] = 8'h00; rom[ 583] = 8'h00;
        rom[ 584] = 8'h00; rom[ 585] = 8'h00; rom[ 586] = 8'h00; rom[ 587] = 8'h00; rom[ 588] = 8'h00; rom[ 589] = 8'h00; rom[ 590] = 8'h00; rom[ 591] = 8'h00;
        rom[ 592] = 8'h00; rom[ 593] = 8'h00; rom[ 594] = 8'h62; rom[ 595] = 8'hD6; rom[ 596] = 8'hD4; rom[ 597] = 8'h68; rom[ 598] = 8'h08; rom[ 599] = 8'h10;
        rom[ 600] = 8'h3E; rom[ 601] = 8'h2A; rom[ 602] = 8'h4A; rom[ 603] = 8'hCE; rom[ 604] = 8'h00; rom[ 605] = 8'h00; rom[ 606] = 8'h00; rom[ 607] = 8'h00;
        rom[ 608] = 8'h00; rom[ 609] = 8'h00; rom[ 610] = 8'h00; rom[ 611] = 8'h00; rom[ 612] = 8'h00; rom[ 613] = 8'h00; rom[ 614] = 8'h00; rom[ 615] = 8'h00;
        rom[ 616] = 8'h00; rom[ 617] = 8'h00; rom[ 618] = 8'h00; rom[ 619] = 8'h00; rom[ 620] = 8'h00; rom[ 621] = 8'h00; rom[ 622] = 8'h00; rom[ 623] = 8'h00;
        rom[ 624] = 8'h00; rom[ 625] = 8'h00; rom[ 626] = 8'h00; rom[ 627] = 8'h00; rom[ 628] = 8'h00; rom[ 629] = 8'h00; rom[ 630] = 8'h00; rom[ 631] = 8'h00;
        rom[ 632] = 8'h00; rom[ 633] = 8'h00; rom[ 634] = 8'h00; rom[ 635] = 8'h00; rom[ 636] = 8'h00; rom[ 637] = 8'h00; rom[ 638] = 8'h00; rom[ 639] = 8'h00;
        rom[ 640] = 8'h00; rom[ 641] = 8'h00; rom[ 642] = 8'h00; rom[ 643] = 8'h00; rom[ 644] = 8'h00; rom[ 645] = 8'h00; rom[ 646] = 8'h00; rom[ 647] = 8'h00;
        rom[ 648] = 8'h00; rom[ 649] = 8'h00; rom[ 650] = 8'h00; rom[ 651] = 8'h00; rom[ 652] = 8'h00; rom[ 653] = 8'h00; rom[ 654] = 8'h00; rom[ 655] = 8'h00;
        rom[ 656] = 8'h00; rom[ 657] = 8'h00; rom[ 658] = 8'h00; rom[ 659] = 8'h00; rom[ 660] = 8'h00; rom[ 661] = 8'h00; rom[ 662] = 8'h00; rom[ 663] = 8'h00;
        rom[ 664] = 8'h00; rom[ 665] = 8'h00; rom[ 666] = 8'h00; rom[ 667] = 8'h00; rom[ 668] = 8'h00; rom[ 669] = 8'h00; rom[ 670] = 8'h00; rom[ 671] = 8'h00;
        rom[ 672] = 8'h00; rom[ 673] = 8'h00; rom[ 674] = 8'h00; rom[ 675] = 8'h00; rom[ 676] = 8'h00; rom[ 677] = 8'h00; rom[ 678] = 8'h00; rom[ 679] = 8'h00;
        rom[ 680] = 8'h00; rom[ 681] = 8'h00; rom[ 682] = 8'h00; rom[ 683] = 8'h00; rom[ 684] = 8'h00; rom[ 685] = 8'h00; rom[ 686] = 8'h00; rom[ 687] = 8'h00;
        rom[ 688] = 8'h00; rom[ 689] = 8'h00; rom[ 690] = 8'h00; rom[ 691] = 8'h00; rom[ 692] = 8'h00; rom[ 693] = 8'h18; rom[ 694] = 8'h18; rom[ 695] = 8'h18;
        rom[ 696] = 8'h7E; rom[ 697] = 8'h18; rom[ 698] = 8'h18; rom[ 699] = 8'h18; rom[ 700] = 8'h00; rom[ 701] = 8'h00; rom[ 702] = 8'h00; rom[ 703] = 8'h00;
        rom[ 704] = 8'h00; rom[ 705] = 8'h00; rom[ 706] = 8'h00; rom[ 707] = 8'h00; rom[ 708] = 8'h00; rom[ 709] = 8'h00; rom[ 710] = 8'h00; rom[ 711] = 8'h00;
        rom[ 712] = 8'h00; rom[ 713] = 8'h00; rom[ 714] = 8'h00; rom[ 715] = 8'h00; rom[ 716] = 8'h00; rom[ 717] = 8'h00; rom[ 718] = 8'h00; rom[ 719] = 8'h00;
        rom[ 720] = 8'h00; rom[ 721] = 8'h00; rom[ 722] = 8'h00; rom[ 723] = 8'h00; rom[ 724] = 8'h00; rom[ 725] = 8'h00; rom[ 726] = 8'h00; rom[ 727] = 8'h00;
        rom[ 728] = 8'h3C; rom[ 729] = 8'h00; rom[ 730] = 8'h00; rom[ 731] = 8'h00; rom[ 732] = 8'h00; rom[ 733] = 8'h00; rom[ 734] = 8'h00; rom[ 735] = 8'h00;
        rom[ 736] = 8'h00; rom[ 737] = 8'h00; rom[ 738] = 8'h00; rom[ 739] = 8'h00; rom[ 740] = 8'h00; rom[ 741] = 8'h00; rom[ 742] = 8'h00; rom[ 743] = 8'h00;
        rom[ 744] = 8'h00; rom[ 745] = 8'h00; rom[ 746] = 8'h18; rom[ 747] = 8'h18; rom[ 748] = 8'h00; rom[ 749] = 8'h00; rom[ 750] = 8'h00; rom[ 751] = 8'h00;
        rom[ 752] = 8'h00; rom[ 753] = 8'h00; rom[ 754] = 8'h04; rom[ 755] = 8'h04; rom[ 756] = 8'h0C; rom[ 757] = 8'h08; rom[ 758] = 8'h18; rom[ 759] = 8'h10;
        rom[ 760] = 8'h10; rom[ 761] = 8'h20; rom[ 762] = 8'h20; rom[ 763] = 8'h60; rom[ 764] = 8'h40; rom[ 765] = 8'h00; rom[ 766] = 8'h00; rom[ 767] = 8'h00;
        rom[ 768] = 8'h00; rom[ 769] = 8'h00; rom[ 770] = 8'h00; rom[ 771] = 8'h3C; rom[ 772] = 8'h66; rom[ 773] = 8'h46; rom[ 774] = 8'h46; rom[ 775] = 8'h5A;
        rom[ 776] = 8'h62; rom[ 777] = 8'h42; rom[ 778] = 8'h64; rom[ 779] = 8'h3C; rom[ 780] = 8'h00; rom[ 781] = 8'h00; rom[ 782] = 8'h00; rom[ 783] = 8'h00;
        rom[ 784] = 8'h00; rom[ 785] = 8'h00; rom[ 786] = 8'h00; rom[ 787] = 8'h18; rom[ 788] = 8'h38; rom[ 789] = 8'h58; rom[ 790] = 8'h18; rom[ 791] = 8'h18;
        rom[ 792] = 8'h18; rom[ 793] = 8'h18; rom[ 794] = 8'h18; rom[ 795] = 8'h7E; rom[ 796] = 8'h00; rom[ 797] = 8'h00; rom[ 798] = 8'h00; rom[ 799] = 8'h00;
        rom[ 800] = 8'h00; rom[ 801] = 8'h00; rom[ 802] = 8'h00; rom[ 803] = 8'h38; rom[ 804] = 8'h44; rom[ 805] = 8'h04; rom[ 806] = 8'h04; rom[ 807] = 8'h0C;
        rom[ 808] = 8'h18; rom[ 809] = 8'h30; rom[ 810] = 8'h60; rom[ 811] = 8'h7E; rom[ 812] = 8'h00; rom[ 813] = 8'h00; rom[ 814] = 8'h00; rom[ 815] = 8'h00;
        rom[ 816] = 8'h00; rom[ 817] = 8'h00; rom[ 818] = 8'h00; rom[ 819] = 8'h78; rom[ 820] = 8'h04; rom[ 821] = 8'h04; rom[ 822] = 8'h0C; rom[ 823] = 8'h38;
        rom[ 824] = 8'h06; rom[ 825] = 8'h06; rom[ 826] = 8'h04; rom[ 827] = 8'h78; rom[ 828] = 8'h00; rom[ 829] = 8'h00; rom[ 830] = 8'h00; rom[ 831] = 8'h00;
        rom[ 832] = 8'h00; rom[ 833] = 8'h00; rom[ 834] = 8'h00; rom[ 835] = 8'h0C; rom[ 836] = 8'h1C; rom[ 837] = 8'h34; rom[ 838] = 8'h24; rom[ 839] = 8'h64;
        rom[ 840] = 8'h44; rom[ 841] = 8'hFE; rom[ 842] = 8'h04; rom[ 843] = 8'h04; rom[ 844] = 8'h00; rom[ 845] = 8'h00; rom[ 846] = 8'h00; rom[ 847] = 8'h00;
        rom[ 848] = 8'h00; rom[ 849] = 8'h00; rom[ 850] = 8'h00; rom[ 851] = 8'h7C; rom[ 852] = 8'h60; rom[ 853] = 8'h60; rom[ 854] = 8'h60; rom[ 855] = 8'h7C;
        rom[ 856] = 8'h06; rom[ 857] = 8'h06; rom[ 858] = 8'h04; rom[ 859] = 8'h78; rom[ 860] = 8'h00; rom[ 861] = 8'h00; rom[ 862] = 8'h00; rom[ 863] = 8'h00;
        rom[ 864] = 8'h00; rom[ 865] = 8'h00; rom[ 866] = 8'h00; rom[ 867] = 8'h1C; rom[ 868] = 8'h30; rom[ 869] = 8'h60; rom[ 870] = 8'h7C; rom[ 871] = 8'h66;
        rom[ 872] = 8'h42; rom[ 873] = 8'h42; rom[ 874] = 8'h66; rom[ 875] = 8'h3C; rom[ 876] = 8'h00; rom[ 877] = 8'h00; rom[ 878] = 8'h00; rom[ 879] = 8'h00;
        rom[ 880] = 8'h00; rom[ 881] = 8'h00; rom[ 882] = 8'h00; rom[ 883] = 8'h7E; rom[ 884] = 8'h06; rom[ 885] = 8'h04; rom[ 886] = 8'h0C; rom[ 887] = 8'h08;
        rom[ 888] = 8'h18; rom[ 889] = 8'h10; rom[ 890] = 8'h30; rom[ 891] = 8'h20; rom[ 892] = 8'h00; rom[ 893] = 8'h00; rom[ 894] = 8'h00; rom[ 895] = 8'h00;
        rom[ 896] = 8'h00; rom[ 897] = 8'h00; rom[ 898] = 8'h00; rom[ 899] = 8'h3C; rom[ 900] = 8'h66; rom[ 901] = 8'h46; rom[ 902] = 8'h64; rom[ 903] = 8'h3C;
        rom[ 904] = 8'h64; rom[ 905] = 8'h46; rom[ 906] = 8'h66; rom[ 907] = 8'h3C; rom[ 908] = 8'h00; rom[ 909] = 8'h00; rom[ 910] = 8'h00; rom[ 911] = 8'h00;
        rom[ 912] = 8'h00; rom[ 913] = 8'h00; rom[ 914] = 8'h00; rom[ 915] = 8'h3C; rom[ 916] = 8'h64; rom[ 917] = 8'h46; rom[ 918] = 8'h42; rom[ 919] = 8'h66;
        rom[ 920] = 8'h3E; rom[ 921] = 8'h04; rom[ 922] = 8'h0C; rom[ 923] = 8'h78; rom[ 924] = 8'h00; rom[ 925] = 8'h00; rom[ 926] = 8'h00; rom[ 927] = 8'h00;
        rom[ 928] = 8'h00; rom[ 929] = 8'h00; rom[ 930] = 8'h00; rom[ 931] = 8'h00; rom[ 932] = 8'h00; rom[ 933] = 8'h18; rom[ 934] = 8'h18; rom[ 935] = 8'h00;
        rom[ 936] = 8'h00; rom[ 937] = 8'h00; rom[ 938] = 8'h18; rom[ 939] = 8'h18; rom[ 940] = 8'h00; rom[ 941] = 8'h00; rom[ 942] = 8'h00; rom[ 943] = 8'h00;
        rom[ 944] = 8'h00; rom[ 945] = 8'h00; rom[ 946] = 8'h00; rom[ 947] = 8'h00; rom[ 948] = 8'h00; rom[ 949] = 8'h00; rom[ 950] = 8'h00; rom[ 951] = 8'h00;
        rom[ 952] = 8'h00; rom[ 953] = 8'h00; rom[ 954] = 8'h00; rom[ 955] = 8'h00; rom[ 956] = 8'h00; rom[ 957] = 8'h00; rom[ 958] = 8'h00; rom[ 959] = 8'h00;
        rom[ 960] = 8'h00; rom[ 961] = 8'h00; rom[ 962] = 8'h00; rom[ 963] = 8'h00; rom[ 964] = 8'h00; rom[ 965] = 8'h00; rom[ 966] = 8'h00; rom[ 967] = 8'h00;
        rom[ 968] = 8'h00; rom[ 969] = 8'h00; rom[ 970] = 8'h00; rom[ 971] = 8'h00; rom[ 972] = 8'h00; rom[ 973] = 8'h00; rom[ 974] = 8'h00; rom[ 975] = 8'h00;
        rom[ 976] = 8'h00; rom[ 977] = 8'h00; rom[ 978] = 8'h00; rom[ 979] = 8'h00; rom[ 980] = 8'h00; rom[ 981] = 8'h00; rom[ 982] = 8'h00; rom[ 983] = 8'h00;
        rom[ 984] = 8'h00; rom[ 985] = 8'h00; rom[ 986] = 8'h00; rom[ 987] = 8'h00; rom[ 988] = 8'h00; rom[ 989] = 8'h00; rom[ 990] = 8'h00; rom[ 991] = 8'h00;
        rom[ 992] = 8'h00; rom[ 993] = 8'h00; rom[ 994] = 8'h00; rom[ 995] = 8'h00; rom[ 996] = 8'h00; rom[ 997] = 8'h00; rom[ 998] = 8'h00; rom[ 999] = 8'h00;
        rom[1000] = 8'h00; rom[1001] = 8'h00; rom[1002] = 8'h00; rom[1003] = 8'h00; rom[1004] = 8'h00; rom[1005] = 8'h00; rom[1006] = 8'h00; rom[1007] = 8'h00;
        rom[1008] = 8'h00; rom[1009] = 8'h00; rom[1010] = 8'h00; rom[1011] = 8'h00; rom[1012] = 8'h00; rom[1013] = 8'h00; rom[1014] = 8'h00; rom[1015] = 8'h00;
        rom[1016] = 8'h00; rom[1017] = 8'h00; rom[1018] = 8'h00; rom[1019] = 8'h00; rom[1020] = 8'h00; rom[1021] = 8'h00; rom[1022] = 8'h00; rom[1023] = 8'h00;
// 表项数 = 944 (最大地址 1023)
    end

    // 主 OSD 与带标签分时复用同一 ROM（两者 x 区间不重叠）
    wire [9:0] rom_addr = lbl_in ? {lbl_ch[5:0], lbl_row} : {chaddr[5:0], grow};

    reg [7:0] glyph;
    always @(posedge clk) glyph <= rom[rom_addr];

    //------------------------------------------------------------------
    // 6. 合成（延迟 1 拍与 ROM 对齐）
    //------------------------------------------------------------------
    reg        in_osd_d;
    reg        lbl_in_d;
    reg [2:0]  bitx_d;
    reg [2:0]  lbl_bit_d;
    reg [23:0] rgb_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_osd_d <= 1'b0;
            lbl_in_d <= 1'b0;
            bitx_d   <= 3'd0;
            lbl_bit_d<= 3'd0;
            rgb_d    <= 24'd0;
            de_out   <= 1'b0;
        end else begin
            in_osd_d <= in_osd;
            lbl_in_d <= lbl_in;
            bitx_d   <= bitx;
            lbl_bit_d<= lbl_bit;
            rgb_d    <= rgb_in;
            de_out   <= de;
        end
    end

    wire pix_on = lbl_in_d ? glyph[7 - lbl_bit_d] : glyph[7 - bitx_d];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      rgb_out <= 24'd0;
        else if (in_osd_d || lbl_in_d)
            rgb_out <= pix_on ? 24'h00FF80      // 亮绿字
                              : 24'h001008;     // 近黑底
        else
            rgb_out <= rgb_d;
    end

endmodule
