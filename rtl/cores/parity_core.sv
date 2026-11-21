// Parity (even/odd) over the valid bytes of a packet.
//
// The core consumes one DATA_WIDTH beat per accepted cycle.  `init` clears the
// accumulator before a packet; `last` marks the final beat and produces a
// one-cycle `tag_done` pulse on the following clock edge.
module parity_core #(
    parameter int DATA_WIDTH = 32,
    parameter bit PARITY_ODD = 1'b0
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic                    tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  localparam int unsigned BYTES = DATA_WIDTH / 8;

  logic [DATA_WIDTH-1:0] mask;
  logic                  beat_parity;
  logic                  parity_q;

  always_comb begin
    mask = '0;
    for (int unsigned i = 0; i < BYTES; i++) begin
      mask[i*8 +: 8] = keep[i] ? 8'hFF : 8'h00;
    end
    beat_parity = ^(data & mask);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      parity_q <= PARITY_ODD;
      tag_done <= 1'b0;
    end else begin
      tag_done <= 1'b0;
      if (init) begin
        parity_q <= PARITY_ODD;
      end else if (valid) begin
        parity_q <= parity_q ^ beat_parity;
        if (last) begin
          tag_done <= 1'b1;
        end
      end
    end
  end

  assign tag   = parity_q;
  assign busy  = 1'b0;
  assign ready = 1'b1;

endmodule
