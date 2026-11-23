// One integrity TX lane for the interactive demo.
// All cores share the same parameter values except ALGO and TAG_WIDTH.
module interactive_lane_tx #(
    parameter int ALGO      = 0,
    parameter int TAG_WIDTH = 1
) (
    input  logic               clk,
    input  logic               rst,
    input  logic [7:0]         s_tdata,
    input  logic               s_tvalid,
    input  logic               s_tlast,
    output logic               s_tready,
    output logic [TAG_WIDTH-1:0] tag_value,
    output logic               tag_valid
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic        m_tready;
  logic [7:0]  m_tdata;
  logic [0:0]  m_tkeep;
  logic        m_tvalid;
  logic        m_tlast;
  logic        busy;
  assign m_tready = 1'b1;

  integrity_tx #(
      .DATA_WIDTH(8),
      .ALGO(ALGO),
      .TAG_WIDTH(TAG_WIDTH),
      .PARITY_ODD(1'b0),
      .SUM_WIDTH(16),
      .ONES_COMPLEMENT(1'b1),
      .BLOCK_WIDTH(8),
      .CRC_WIDTH(32),
      .CRC_POLY(32'h04C11DB7),
      .CRC_INIT(32'hFFFFFFFF),
      .CRC_REFIN(1'b1),
      .CRC_REFOUT(1'b1),
      .CRC_XOROUT(32'hFFFFFFFF)
  ) u_txn (
      .clk(clk), .rst(rst),
      .s_axis_tdata(s_tdata), .s_axis_tkeep(1'b1),
      .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
      .s_axis_tlast(s_tlast),
      .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
      .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
      .m_axis_tlast(m_tlast),
      .tag_value(tag_value), .tag_valid(tag_valid),
      .busy(busy)
  );
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
