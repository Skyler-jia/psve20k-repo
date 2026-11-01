//======================================================================
// sync_fifo.v — 同步 FIFO（组合读端口，推断为分布式 RAM）
// 用途：像素字流在 img_gen / sdram_fb / img_proc 之间的速率匹配缓冲
// 说明：dout 是组合读出（first-word-fall-through），适合"给命令的同时
//       就要把首字放到数据总线上"这类接口（SDRAM 突发写就是这样）
//======================================================================
`timescale 1ns/1ps

module sync_fifo #(
    parameter DW = 32,
    parameter AW = 6              // 深度 = 2^AW
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          flush,   // 高电平清空（同步）
    input  wire          wr_en,
    input  wire [DW-1:0] din,
    input  wire          rd_en,
    output wire [DW-1:0] dout,
    output wire          full,
    output wire          empty,
    output wire [AW:0]   count
);

    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW:0]   wptr, rptr;

    assign count = wptr - rptr;
    assign full  = (count == (1<<AW));
    assign empty = (wptr == rptr);
    assign dout  = mem[rptr[AW-1:0]];

    always @(posedge clk) begin
        if (wr_en && !full && !flush)
            mem[wptr[AW-1:0]] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
        end else if (flush) begin
            wptr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
        end else begin
            if (wr_en && !full) wptr <= wptr + 1'b1;
            if (rd_en && !empty) rptr <= rptr + 1'b1;
        end
    end

endmodule
