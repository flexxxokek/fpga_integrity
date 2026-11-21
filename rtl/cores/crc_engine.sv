// Parameterised CRC engine (CRC-8/16/32/32C and any other width/polynomial).
//
// The engine always works in the MSB-first domain.  When REFIN is set each
// payload byte is bit-reversed before being fed to the LFSR; REFOUT reverses
// the final remainder.  This is equivalent to the usual reflected LFSR
// formulation and keeps one implementation for all catalogue entries.
module crc_engine #(
    parameter int          DATA_WIDTH = 32,
    parameter int          CRC_WIDTH  = 32,
    parameter logic [CRC_WIDTH-1:0] POLY    = 32'h04C11DB7,
    parameter logic [CRC_WIDTH-1:0] INIT    = 32'hFFFFFFFF,
    parameter bit          REFIN      = 1'b1,
    parameter bit          REFOUT     = 1'b1,
    parameter logic [CRC_WIDTH-1:0] XOROUT  = 32'hFFFFFFFF
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic [CRC_WIDTH-1:0]    tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  localparam int unsigned BYTES = DATA_WIDTH / 8;

  logic [CRC_WIDTH-1:0] crc_q;
  logic [CRC_WIDTH-1:0] crc_next;

  function automatic logic [7:0] reverse8(input logic [7:0] value);
    logic [7:0] r;
    for (int unsigned i = 0; i < 8; i++) begin
      r[i] = value[7-i];
    end
    return r;
  endfunction

  function automatic logic [CRC_WIDTH-1:0] reverse_crc(
      input logic [CRC_WIDTH-1:0] value
  );
    logic [CRC_WIDTH-1:0] r;
    for (int unsigned i = 0; i < CRC_WIDTH; i++) begin
      r[i] = value[CRC_WIDTH-1-i];
    end
    return r;
  endfunction

  function automatic logic [CRC_WIDTH-1:0] update_byte(
      input logic [CRC_WIDTH-1:0] crc_in,
      input logic [7:0]           byte_in
  );
    logic [CRC_WIDTH-1:0] r;
    r = crc_in;
    for (int k = 7; k >= 0; k--) begin
      if (r[CRC_WIDTH-1] ^ byte_in[k]) begin
        r = (r << 1) ^ POLY;
      end else begin
        r = r << 1;
      end
    end
    return r;
  endfunction

  always_comb begin
    crc_next = crc_q;
    for (int unsigned i = 0; i < BYTES; i++) begin
      if (keep[i]) begin
        crc_next = update_byte(crc_next, REFIN ? reverse8(data[i*8 +: 8])
                                              : data[i*8 +: 8]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      crc_q    <= INIT;
      tag_done <= 1'b0;
    end else begin
      tag_done <= 1'b0;
      if (init) begin
        crc_q <= INIT;
      end else if (valid) begin
        crc_q <= crc_next;
        if (last) begin
          tag_done <= 1'b1;
        end
      end
    end
  end

  assign tag   = (REFOUT ? reverse_crc(crc_q) : crc_q) ^ XOROUT;
  assign busy  = 1'b0;
  assign ready = 1'b1;

endmodule
