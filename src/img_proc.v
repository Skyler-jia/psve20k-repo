//======================================================================
// img_proc.v — 图像算法流水线（灰度 / 二值化 / Sobel 边缘）+ 左右分屏
//
//  输入 gray_in : 来自 SDRAM 帧缓存的"延迟 N 帧"亮度流（8bit）
//  输入 rgb_live: 实时彩色原图（左半屏用作对照基准）
//
//  3 片行缓存轮转构成 3x3 窗口：
//      p1 p2 p3      <- 第 N-2 行
//      p4 p5 p6      <- 第 N-1 行
//      p7 p8 p9      <- 第 N   行（当前）
//  Sobel: Gx=(p1+2p2+p3)-(p7+2p8+p9)  Gy=(p1+2p4+p7)-(p3+2p6+p9)
//         |G| = |Gx|+|Gy|（免开方）>>3 得 8bit 边缘强度
//
//  总延迟 LAT=4，输出侧 de/x/rgb_live 全部对齐到 LAT
//======================================================================
`timescale 1ns/1ps

module img_proc #(
    parameter H_ACT = 1280,
    parameter LAT   = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  algo,          // 0..7 算法核
    input  wire [1:0]  view,          // 0=左右分屏 1=全屏算法 2=全屏原图
    input  wire [7:0]  thresh,
    // 输入：延迟帧亮度流
    input  wire        de_in,
    input  wire [10:0] x_in,
    input  wire [7:0]  gray_in,
    // 输入：实时彩色原图（与 gray_in 同拍）
    input  wire [23:0] rgb_live,
    // 输入：实时亮度（用于时域帧差运动检测，与 gray_in 同拍）
    input  wire [7:0]  live_y,
    // 统计：每帧一次，输出上一帧边缘像素数/1024（给 OSD）
    input  wire        frame_start,
    output reg  [9:0]  edge_k,
    // 输出
    output reg  [23:0] rgb_out,
    output reg         de_out
);

    //------------------------------------------------------------------
    // 行相位轮转：0->写 ram0, 1->写 ram2, 2->写 ram1
    //   相位在 de 下降 3 拍后切换（消隐期内），保证无在途读被打断
    //------------------------------------------------------------------
    reg [1:0] phase;
    reg       de_d1;
    reg [2:0] de_fall_d;

    wire de_fall = de_d1 & ~de_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase     <= 2'd0;
            de_d1     <= 1'b0;
            de_fall_d <= 3'd0;
        end else begin
            de_d1     <= de_in;
            de_fall_d <= {de_fall_d[1:0], de_fall};
            if (de_fall_d[2])
                phase <= (phase == 2'd2) ? 2'd0 : phase + 1'b1;
        end
    end

    //------------------------------------------------------------------
    // 3 片行缓存
    //------------------------------------------------------------------
    reg  we0, we1, we2;
    wire [7:0] q0, q1, q2;

    always @(*) begin
        we0 = 1'b0; we1 = 1'b0; we2 = 1'b0;
        case (phase)
            2'd0: we0 = de_in;
            2'd1: we2 = de_in;
            2'd2: we1 = de_in;
        endcase
    end

    line_ram #(.DW(8), .AW(11)) u_lb0 (
        .clk(clk), .we(we0), .waddr(x_in), .wdata(gray_in), .raddr(x_in), .rdata(q0));
    line_ram #(.DW(8), .AW(11)) u_lb1 (
        .clk(clk), .we(we1), .waddr(x_in), .wdata(gray_in), .raddr(x_in), .rdata(q1));
    line_ram #(.DW(8), .AW(11)) u_lb2 (
        .clk(clk), .we(we2), .waddr(x_in), .wdata(gray_in), .raddr(x_in), .rdata(q2));

    // 读源选择：newer = 第 N-1 行，older = 第 N-2 行
    reg [7:0] newer_q, older_q;
    always @(*) begin
        case (phase)
            2'd0: begin newer_q = q2; older_q = q1; end
            2'd1: begin newer_q = q0; older_q = q1; end
            default: begin newer_q = q2; older_q = q0; end
        endcase
    end

    //------------------------------------------------------------------
    // 延迟 1 拍对齐（行缓存输出滞后 1 拍）
    //------------------------------------------------------------------
    reg [7:0] gray_d1;
    reg       de_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gray_d1 <= 8'd0;
            de_d2   <= 1'b0;
        end else begin
            gray_d1 <= gray_in;
            de_d2   <= de_in;
        end
    end

    //------------------------------------------------------------------
    // 3x3 窗口（移位寄存器）
    //------------------------------------------------------------------
    reg [23:0] sr_cur, sr_mid, sr_old;
    always @(posedge clk) begin
        if (de_d2) begin
            sr_cur <= {sr_cur[15:0], gray_d1};
            sr_mid <= {sr_mid[15:0], newer_q};
            sr_old <= {sr_old[15:0], older_q};
        end
    end

    wire [7:0] p1 = sr_old[23:16], p2 = sr_old[15:8], p3 = sr_old[7:0];
    wire [7:0] p4 = sr_mid[23:16], p5 = sr_mid[15:8], p6 = sr_mid[7:0];
    wire [7:0] p7 = sr_cur[23:16], p8 = sr_cur[15:8], p9 = sr_cur[7:0];

    //------------------------------------------------------------------
    // Sobel
    //------------------------------------------------------------------
    wire signed [11:0] gx = ($signed({4'b0,p1}) + $signed({3'b0,p2,1'b0}) + $signed({4'b0,p3}))
                          - ($signed({4'b0,p7}) + $signed({3'b0,p8,1'b0}) + $signed({4'b0,p9}));
    wire signed [11:0] gy = ($signed({4'b0,p1}) + $signed({3'b0,p4,1'b0}) + $signed({4'b0,p7}))
                          - ($signed({4'b0,p3}) + $signed({3'b0,p6,1'b0}) + $signed({4'b0,p9}));
    wire [11:0] ax = gx[11] ? (~gx[11:0] + 1'b1) : {gx[11], gx[10:0]};
    wire [11:0] ay = gy[11] ? (~gy[11:0] + 1'b1) : {gy[11], gy[10:0]};
    wire [12:0] mag = {1'b0, ax} + {1'b0, ay};          // 0..2040
    wire [7:0]  emag = mag[10:3];                        // /8 增益 -> 0..255

    //------------------------------------------------------------------
    // Laplacian（二阶微分）：L = 4*p5 - (p2+p4+p6+p8)
    //------------------------------------------------------------------
    wire [9:0]  lsum = {2'b0, p2} + {2'b0, p4} + {2'b0, p6} + {2'b0, p8};
    wire signed [10:0] ldiff = $signed({1'b0, p5, 2'b00}) - $signed({1'b0, lsum});
    wire [10:0] lab  = ldiff[10] ? (~ldiff[10:0] + 1'b1) : {1'b0, ldiff[9:0]};
    wire [7:0]  lapa = lab[9:2];                         // /4 增益 -> 0..255

    //------------------------------------------------------------------
    // 中值滤波：30 级比较交换网络
    // 原理：冒泡排序前 4 轮把 4 个最大值推到尾部，此时前 5 个即
    //       最小的 5 个，取其中最大值 = 第 5 大 = 中值。
    // 已用 Python 穷举 9! = 362880 种排列验证为「精确中值」（非近似）
    //------------------------------------------------------------------
    reg  [7:0] mm [0:8];
    reg  [7:0] mt;
    always @(*) begin
        mt = 8'd0;                       // 防止综合器推断出 latch
        mm[0]=p1; mm[1]=p2; mm[2]=p3; mm[3]=p4; mm[4]=p5;
        mm[5]=p6; mm[6]=p7; mm[7]=p8; mm[8]=p9;
        if (mm[0]>mm[1]) begin mt=mm[0]; mm[0]=mm[1]; mm[1]=mt; end
        if (mm[1]>mm[2]) begin mt=mm[1]; mm[1]=mm[2]; mm[2]=mt; end
        if (mm[2]>mm[3]) begin mt=mm[2]; mm[2]=mm[3]; mm[3]=mt; end
        if (mm[3]>mm[4]) begin mt=mm[3]; mm[3]=mm[4]; mm[4]=mt; end
        if (mm[4]>mm[5]) begin mt=mm[4]; mm[4]=mm[5]; mm[5]=mt; end
        if (mm[5]>mm[6]) begin mt=mm[5]; mm[5]=mm[6]; mm[6]=mt; end
        if (mm[6]>mm[7]) begin mt=mm[6]; mm[6]=mm[7]; mm[7]=mt; end
        if (mm[7]>mm[8]) begin mt=mm[7]; mm[7]=mm[8]; mm[8]=mt; end
        if (mm[0]>mm[1]) begin mt=mm[0]; mm[0]=mm[1]; mm[1]=mt; end
        if (mm[1]>mm[2]) begin mt=mm[1]; mm[1]=mm[2]; mm[2]=mt; end
        if (mm[2]>mm[3]) begin mt=mm[2]; mm[2]=mm[3]; mm[3]=mt; end
        if (mm[3]>mm[4]) begin mt=mm[3]; mm[3]=mm[4]; mm[4]=mt; end
        if (mm[4]>mm[5]) begin mt=mm[4]; mm[4]=mm[5]; mm[5]=mt; end
        if (mm[5]>mm[6]) begin mt=mm[5]; mm[5]=mm[6]; mm[6]=mt; end
        if (mm[6]>mm[7]) begin mt=mm[6]; mm[6]=mm[7]; mm[7]=mt; end
        if (mm[0]>mm[1]) begin mt=mm[0]; mm[0]=mm[1]; mm[1]=mt; end
        if (mm[1]>mm[2]) begin mt=mm[1]; mm[1]=mm[2]; mm[2]=mt; end
        if (mm[2]>mm[3]) begin mt=mm[2]; mm[2]=mm[3]; mm[3]=mt; end
        if (mm[3]>mm[4]) begin mt=mm[3]; mm[3]=mm[4]; mm[4]=mt; end
        if (mm[4]>mm[5]) begin mt=mm[4]; mm[4]=mm[5]; mm[5]=mt; end
        if (mm[5]>mm[6]) begin mt=mm[5]; mm[5]=mm[6]; mm[6]=mt; end
        if (mm[0]>mm[1]) begin mt=mm[0]; mm[0]=mm[1]; mm[1]=mt; end
        if (mm[1]>mm[2]) begin mt=mm[1]; mm[1]=mm[2]; mm[2]=mt; end
        if (mm[2]>mm[3]) begin mt=mm[2]; mm[2]=mm[3]; mm[3]=mt; end
        if (mm[3]>mm[4]) begin mt=mm[3]; mm[3]=mm[4]; mm[4]=mt; end
        if (mm[4]>mm[5]) begin mt=mm[4]; mm[4]=mm[5]; mm[5]=mt; end
        if (mm[0]>mm[1]) begin mt=mm[0]; mm[0]=mm[1]; mm[1]=mt; end
        if (mm[1]>mm[2]) begin mt=mm[1]; mm[1]=mm[2]; mm[2]=mt; end
        if (mm[2]>mm[3]) begin mt=mm[2]; mm[2]=mm[3]; mm[3]=mt; end
        if (mm[3]>mm[4]) begin mt=mm[3]; mm[3]=mm[4]; mm[4]=mt; end
    end
    wire [7:0] med = mm[4];

    reg [7:0] emag_r, center_r, lapa_r, med_r;
    always @(posedge clk) begin
        emag_r   <= emag;
        center_r <= p5;
        lapa_r   <= lapa;
        med_r    <= med;
    end

    //------------------------------------------------------------------
    // 时域帧差运动检测：|当前帧亮度 - 延迟帧亮度| > 阈值
    //   ★ 不需要额外访问存储器：延迟帧本来就在读，当前帧本来就在产生
    //   延迟帧数越大 → 越只能检测"慢运动"（这是个很有演示价值的旋钮）
    //------------------------------------------------------------------
    reg [7:0] live_d1;
    always @(posedge clk) live_d1 <= live_y;

    wire [7:0] mdiff = (live_d1 > gray_d1) ? (live_d1 - gray_d1)
                                           : (gray_d1 - live_d1);
    reg  [7:0] mo_r;
    always @(posedge clk) mo_r <= (mdiff > 8'd24) ? 8'hFF : 8'h00;

    //------------------------------------------------------------------
    // 算法结果（右半屏内容，按键切换）
    //------------------------------------------------------------------
    reg [23:0] proc_px;
    always @(*) begin
        case (algo)
            3'd0: proc_px = {center_r, center_r, center_r};                    // GRAY
            3'd1: proc_px = (center_r >= thresh) ? 24'hFFFFFF : 24'h000000;    // BINARY
            3'd2: proc_px = {emag_r, emag_r, emag_r};                          // SOBEL
            3'd3: proc_px = (emag_r > 8'd48) ? 24'hFFFFFF                      // OVERLAY
                                             : {center_r, center_r, center_r};
            3'd4: proc_px = {lapa_r, lapa_r, lapa_r};                          // LAPLACE
            3'd5: proc_px = {med_r, med_r, med_r};                             // MEDIAN
            3'd6: proc_px = {mo_r, mo_r, mo_r};                                // MOTION
            3'd7: proc_px = (mo_r != 8'd0) ? 24'hFF2000                        // MOTION_OVR
                                           : {center_r, center_r, center_r};
            default: proc_px = {emag_r, emag_r, emag_r};
        endcase
    end

    //------------------------------------------------------------------
    // 边缘像素计数（每帧清零，给 OSD 当"算法真的在跑"的证据）
    //------------------------------------------------------------------
    reg        de_d3;
    reg [19:0] ecnt;
    always @(posedge clk) de_d3 <= de_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecnt   <= 20'd0;
            edge_k <= 10'd0;
        end else if (frame_start) begin
            edge_k <= (ecnt[19:10] > 10'd999) ? 10'd999 : ecnt[19:10];
            ecnt   <= 20'd0;
        end else if (de_d3 && (emag_r > 8'd48)) begin
            if (ecnt != 20'hFFFFF) ecnt <= ecnt + 1'b1;
        end
    end

    //------------------------------------------------------------------
    // 输出对齐：de / x / rgb_live 延迟 LAT
    //------------------------------------------------------------------
    reg [LAT-1:0]  de_sr;
    reg [10:0]     x_sr  [0:LAT-1];
    reg [23:0]     rgb_sr[0:LAT-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_sr <= {LAT{1'b0}};
            for (i = 0; i < LAT; i = i + 1) begin
                x_sr[i]   <= 11'd0;
                rgb_sr[i] <= 24'd0;
            end
        end else begin
            de_sr <= {de_sr[LAT-2:0], de_in};
            x_sr[0]   <= x_in;
            rgb_sr[0] <= rgb_live;
            for (i = 1; i < LAT; i = i + 1) begin
                x_sr[i]   <= x_sr[i-1];
                rgb_sr[i] <= rgb_sr[i-1];
            end
        end
    end

    wire [10:0] xa    = x_sr[LAT-1];
    wire [23:0] livea = rgb_sr[LAT-1];
    // Sobel 结果对应窗口中心列 = 当前列 - 1
    wire [10:0] xres  = (xa == 11'd0) ? 11'd0 : (xa - 11'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rgb_out <= 24'd0;
        else begin
            case (view)
                2'd1:    rgb_out <= proc_px;                          // 全屏算法
                2'd2:    rgb_out <= livea;                            // 全屏原图（基准）
                default: begin
                    if (xres < 11'd638)
                        rgb_out <= livea;                             // 左半：实时彩色原图
                    else if (xres < 11'd642)
                        rgb_out <= 24'hFFFFFF;                        // 中缝
                    else
                        rgb_out <= proc_px;                           // 右半：算法结果
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) de_out <= 1'b0;
        else        de_out <= de_sr[LAT-1];
    end

endmodule
