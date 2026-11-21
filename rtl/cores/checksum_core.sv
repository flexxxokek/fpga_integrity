// Generic checksum engine.
//
// Bytes are grouped into SUM_WIDTH-bit words in network (big-endian) order,
// matching the Internet checksum interpretation for SUM_WIDTH == 16.  A final
// partial word is zero-padded.  With ONES_COMPLEMENT every addition folds the
// carry back into the low bits and the final result is inverted (RFC 1071).
module checksum_core #(
    parameter int DATA_WIDTH      = 32,
    parameter int SUM_WIDTH       = 16,
    parameter bit ONES_COMPLEMENT = 1'b1
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic [SUM_WIDTH-1:0]    tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  localparam int unsigned BYTES       = DATA_WIDTH / 8;
  localparam int unsigned BLOCK_BYTES = (SUM_WIDTH + 7) / 8;

  logic [SUM_WIDTH:0] sum_q;
  logic [SUM_WIDTH-1:0] blk_q;
  logic [3:0]           fill_q;

  // Combinational next values.
  logic [SUM_WIDTH:0]   next_sum;
  logic [SUM_WIDTH-1:0] next_blk;
  logic [3:0]           next_fill;
  logic [SUM_WIDTH-1:0] add_word;

  always_comb begin
    next_sum  = sum_q;
    next_blk  = blk_q;
    next_fill = fill_q;
    add_word  = '0;

    for (int unsigned i = 0; i < BYTES; i++) begin
      if (keep[i]) begin
        next_blk = (next_blk << 8) | {{(SUM_WIDTH-8){1'b0}}, data[i*8 +: 8]};
        if (next_fill == 4'(BLOCK_BYTES - 1)) begin
          next_sum = next_sum + {1'b0, next_blk};
          if (ONES_COMPLEMENT && next_sum[SUM_WIDTH]) begin
            next_sum = {1'b0, next_sum[SUM_WIDTH-1:0]} + 1'b1;
          end else begin
            next_sum = {1'b0, next_sum[SUM_WIDTH-1:0]};
          end
          next_blk  = '0;
          next_fill = 0;
        end else begin
          next_fill = next_fill + 1'b1;
        end
      end
    end

    if (last && (next_fill != 0)) begin
      add_word = next_blk << (8 * (BLOCK_BYTES - 32'(next_fill)));
      next_sum = next_sum + {1'b0, add_word};
      if (ONES_COMPLEMENT && next_sum[SUM_WIDTH]) begin
        next_sum = {1'b0, next_sum[SUM_WIDTH-1:0]} + 1'b1;
      end else begin
        next_sum = {1'b0, next_sum[SUM_WIDTH-1:0]};
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sum_q    <= '0;
      blk_q    <= '0;
      fill_q   <= '0;
      tag_done <= 1'b0;
    end else begin
      tag_done <= 1'b0;
      if (init) begin
        sum_q  <= '0;
        blk_q  <= '0;
        fill_q <= '0;
      end else if (valid) begin
        sum_q  <= next_sum;
        blk_q  <= next_blk;
        fill_q <= next_fill;
        if (last) begin
          tag_done <= 1'b1;
        end
      end
    end
  end

  assign tag   = ONES_COMPLEMENT ? ~sum_q[SUM_WIDTH-1:0] : sum_q[SUM_WIDTH-1:0];
  assign busy  = 1'b0;
  assign ready = 1'b1;

endmodule
