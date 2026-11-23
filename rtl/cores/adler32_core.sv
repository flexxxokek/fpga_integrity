// Adler-32 (RFC 1950).
//
// A starts at 1 and B at 0; each payload byte updates A and then B modulo
// 65521.  The tag is {B, A}.
module adler32_core #(
    parameter int DATA_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic [31:0]             tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  localparam int unsigned BYTES   = DATA_WIDTH / 8;
  localparam logic [31:0] MODULUS = 32'd65521;

  logic [15:0] a_q;
  logic [15:0] b_q;

  logic [31:0] next_a;
  logic [31:0] next_b;

  // Both operands are < 2*MODULUS, so one conditional subtraction is an exact
  // replacement for `% MODULUS` and avoids a 32-bit divider in the FPGA.
  function automatic logic [15:0] mod_adler(input logic [31:0] value);
    logic [31:0] reduced;
    reduced = value;
    if (reduced >= MODULUS) reduced = reduced - MODULUS;
    return 16'(reduced);
  endfunction

  always_comb begin
    next_a = {16'd0, a_q};
    next_b = {16'd0, b_q};
    for (int unsigned i = 0; i < BYTES; i++) begin
      if (keep[i]) begin
        next_a = 32'(mod_adler(next_a + 32'(data[i*8 +: 8])));
        next_b = 32'(mod_adler(next_b + next_a));
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      a_q      <= 16'd1;
      b_q      <= 16'd0;
      tag_done <= 1'b0;
    end else begin
      tag_done <= 1'b0;
      if (init) begin
        a_q <= 16'd1;
        b_q <= 16'd0;
      end else if (valid) begin
        a_q <= next_a[15:0];
        b_q <= next_b[15:0];
        if (last) begin
          tag_done <= 1'b1;
        end
      end
    end
  end

  assign tag   = {b_q, a_q};
  assign busy  = 1'b0;
  assign ready = 1'b1;

endmodule
