//======================================================================
// sdram_test.v — SDRAM 上电自检（上板第一件事就靠它）
//
// 手法：向 0..1023 每个字写入自识别数据 {addr[15:0], ~addr[15:0]}，
//       再回读比对。任何地址/突发/握手配置错误都会暴露成 err_cnt。
//       注意：本 IP 的 wr_n/rd_n/data_len 语义若与实测不符，最典型的
//       表现就是 err_cnt 恒不为 0 —— 此时按 README 的排查表调
//       WR_SKEW / BURST 即可。
//======================================================================
`timescale 1ns/1ps

module sdram_test #(
    parameter N_WORDS = 1024,
    parameter BURST   = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg  [15:0] err_cnt,

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

    localparam S_IDLE  = 3'd0,
               S_WCMD  = 3'd1,
               S_WDATA = 3'd2,
               S_WWAIT = 3'd3,
               S_RCMD  = 3'd4,
               S_RDATA = 3'd5,
               S_DONE  = 3'd6;

    reg [2:0]  st;
    reg [10:0] idx;          // 以 BURST 为步进
    reg [4:0]  bc;
    reg [4:0]  rrem;

    wire [15:0] a16 = {5'b0, idx};
    wire [31:0] wr_word = {a16, ~a16};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; idx <= 11'd0; bc <= 5'd0; rrem <= 5'd0;
            done <= 1'b0; err_cnt <= 16'd0;
            sdrc_wr_n <= 1'b1; sdrc_rd_n <= 1'b1;
            sdrc_data_len <= BURST[7:0]; sdrc_dqm <= 4'h0;
            sdrc_addr <= 21'd0; sdrc_data <= 32'd0;
        end else begin
            sdrc_wr_n <= 1'b1;
            sdrc_rd_n <= 1'b1;
            case (st)
                S_IDLE: begin
                    done <= 1'b0; err_cnt <= 16'd0;
                    idx  <= 11'd0;
                    if (start && sdrc_init_done && sdrc_busy_n) st <= S_WCMD;
                end
                S_WCMD: begin
                    if (sdrc_busy_n) begin
                        sdrc_wr_n     <= 1'b0;
                        sdrc_addr     <= {10'b0, idx};
                        sdrc_data     <= wr_word;
                        sdrc_data_len <= BURST[7:0];
                        sdrc_dqm      <= 4'h0;
                        bc            <= 5'd1;
                        st            <= S_WDATA;
                    end
                end
                S_WDATA: begin
                    sdrc_data <= {a16 + bc[10:0], ~(a16 + bc[10:0])} ;
                    if (bc >= BURST) st <= S_WWAIT;
                    bc <= bc + 1'b1;
                end
                S_WWAIT: begin
                    if (sdrc_busy_n) begin
                        if (idx >= (N_WORDS - BURST)) st <= S_RCMD;
                        else begin
                            idx <= idx + BURST;
                            st  <= S_WCMD;
                        end
                    end
                end
                S_RCMD: begin
                    if (sdrc_busy_n) begin
                        sdrc_rd_n     <= 1'b0;
                        sdrc_addr     <= 21'd0;
                        sdrc_data_len <= BURST[7:0];
                        idx           <= 11'd0;
                        rrem          <= BURST[4:0];
                        st            <= S_RDATA;
                    end
                end
                S_RDATA: begin
                    if (sdrc_rd_valid) begin
                        if (sdrc_data_q !== {16'd0 + idx[15:0], ~(16'd0 + idx[15:0])})
                            err_cnt <= err_cnt + 1'b1;
                        idx  <= idx + 1'b1;
                        rrem <= rrem - 1'b1;
                        if (rrem == 5'd1) begin
                            if (idx >= (N_WORDS - 1)) begin
                                st <= S_DONE;
                            end else begin
                                st <= S_RCMD;
                            end
                        end
                    end
                end
                S_DONE: begin
                    done <= 1'b1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
