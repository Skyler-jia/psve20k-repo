//======================================================================
// psve20k.sdc — 时序约束
//   27MHz 输入 -> rPLL(371.25MHz) -> CLKDIV/5 -> 74.25MHz 像素钟
//   （数值取自官方例程，勿改：这正是 720p60 的像素钟）
//======================================================================
create_clock -name tmds_clk -period 13.468 -waveform {0 6.734} [get_pins {u_clkdiv/CLKOUT}]
create_clock -name I_clk -period 37.04 -waveform {0 18.52} [get_ports {I_clk}] -add

// 片内 SDRAM 控制器与像素钟同源（都是 u_clkdiv/CLKOUT），
// 因此不需要额外的跨时钟域约束。
