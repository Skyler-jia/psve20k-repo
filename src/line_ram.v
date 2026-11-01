//======================================================================
// line_ram.v — 单写口/单读口行缓存（推断为 BSRAM）
// 读数据滞后 1 拍；写与读使用不同物理例化，故同址读写无冲突
//======================================================================
`timescale 1ns/1ps

module line_ram #(
    parameter DW = 8,
    parameter AW = 11
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule
