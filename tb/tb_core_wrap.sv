// Cocotb-visible wrapper around one integrity core.
module tb_core_wrap #(
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
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic [TAG_WIDTH-1:0]    tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  generate
    if (ALGO == 0) begin : g_parity
      parity_core #(.DATA_WIDTH(DATA_WIDTH), .PARITY_ODD(PARITY_ODD)) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end else if (ALGO == 1) begin : g_checksum
      checksum_core #(
          .DATA_WIDTH(DATA_WIDTH), .SUM_WIDTH(SUM_WIDTH),
          .ONES_COMPLEMENT(ONES_COMPLEMENT)
      ) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end else if (ALGO == 2) begin : g_fletcher
      fletcher_core #(
          .DATA_WIDTH(DATA_WIDTH), .BLOCK_WIDTH(BLOCK_WIDTH)
      ) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end else if (ALGO == 3) begin : g_adler
      adler32_core #(.DATA_WIDTH(DATA_WIDTH)) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end else if (ALGO == 4) begin : g_crc
      crc_engine #(
          .DATA_WIDTH(DATA_WIDTH), .CRC_WIDTH(CRC_WIDTH), .POLY(CRC_POLY),
          .INIT(CRC_INIT), .REFIN(CRC_REFIN), .REFOUT(CRC_REFOUT),
          .XOROUT(CRC_XOROUT)
      ) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end else begin : g_sha256
      sha256_core #(.DATA_WIDTH(DATA_WIDTH)) u_core (
          .clk, .rst, .init, .valid, .data, .keep, .last,
          .tag, .tag_done, .busy, .ready
      );
    end
  endgenerate

endmodule
