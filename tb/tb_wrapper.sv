// TX -> RX loop for wrapper-level cocotb tests.
module tb_wrapper #(
    parameter int  DATA_WIDTH      = 32,
    parameter int  ALGO            = 0,
    parameter int  TAG_WIDTH       = 1,
    parameter bit  PARITY_ODD      = 1'b0,
    parameter int  SUM_WIDTH       = 16,
    parameter bit  ONES_COMPLEMENT = 1'b1,
    parameter int  BLOCK_WIDTH     = 8,
    parameter int  CRC_WIDTH       = 32,
    parameter logic [CRC_WIDTH-1:0] CRC_POLY   = 32'h04C11DB7,
    parameter logic [CRC_WIDTH-1:0] CRC_INIT   = 32'hFFFFFFFF,
    parameter bit  CRC_REFIN       = 1'b1,
    parameter bit  CRC_REFOUT      = 1'b1,
    parameter logic [CRC_WIDTH-1:0] CRC_XOROUT = 32'hFFFFFFFF
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic [TAG_WIDTH-1:0]    tag_value,
    output logic                    tag_valid,
    output logic                    tag_error,
    output logic                    busy,
    input  logic                    inject
);

  logic [DATA_WIDTH-1:0]   link_tdata;
  logic [DATA_WIDTH-1:0]   link_tdata_rx;
  logic [DATA_WIDTH/8-1:0] link_tkeep;
  logic                    link_tvalid;
  logic                    link_tready;
  logic                    link_tlast;
  logic                    injected_q;

  // Corrupt the first payload beat of a packet (used by the RX test).
  always_ff @(posedge clk) begin
    if (rst) begin
      injected_q <= 1'b0;
    end else if (inject && link_tvalid && link_tready && !link_tlast) begin
      injected_q <= 1'b1;
    end else if (link_tvalid && link_tready && link_tlast) begin
      injected_q <= 1'b0;
    end
  end

  assign link_tdata_rx = (inject && !injected_q && !link_tlast) ?
                         (link_tdata ^ {{(DATA_WIDTH-1){1'b0}}, 1'b1}) :
                         link_tdata;

  integrity_tx #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(ALGO), .TAG_WIDTH(TAG_WIDTH),
      .PARITY_ODD(PARITY_ODD), .SUM_WIDTH(SUM_WIDTH),
      .ONES_COMPLEMENT(ONES_COMPLEMENT), .BLOCK_WIDTH(BLOCK_WIDTH),
      .CRC_WIDTH(CRC_WIDTH), .CRC_POLY(CRC_POLY), .CRC_INIT(CRC_INIT),
      .CRC_REFIN(CRC_REFIN), .CRC_REFOUT(CRC_REFOUT), .CRC_XOROUT(CRC_XOROUT)
  ) u_tx (
      .clk, .rst,
      .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready,
      .s_axis_tlast,
      .m_axis_tdata(link_tdata), .m_axis_tkeep(link_tkeep),
      .m_axis_tvalid(link_tvalid), .m_axis_tready(link_tready),
      .m_axis_tlast(link_tlast),
      .tag_value(), .tag_valid(), .busy()
  );

  integrity_rx #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(ALGO), .TAG_WIDTH(TAG_WIDTH),
      .PARITY_ODD(PARITY_ODD), .SUM_WIDTH(SUM_WIDTH),
      .ONES_COMPLEMENT(ONES_COMPLEMENT), .BLOCK_WIDTH(BLOCK_WIDTH),
      .CRC_WIDTH(CRC_WIDTH), .CRC_POLY(CRC_POLY), .CRC_INIT(CRC_INIT),
      .CRC_REFIN(CRC_REFIN), .CRC_REFOUT(CRC_REFOUT), .CRC_XOROUT(CRC_XOROUT)
  ) u_rx (
      .clk, .rst,
      .s_axis_tdata(link_tdata_rx), .s_axis_tkeep(link_tkeep),
      .s_axis_tvalid(link_tvalid), .s_axis_tready(link_tready),
      .s_axis_tlast(link_tlast),
      .m_axis_tdata, .m_axis_tkeep, .m_axis_tvalid, .m_axis_tready,
      .m_axis_tlast,
      .tag_value, .tag_valid, .tag_error, .busy
  );

endmodule
