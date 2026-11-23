// Fletcher-16 / Fletcher-32 engine.
//
// BLOCK_WIDTH selects the summation block: 8 for Fletcher-16 and 16 for
// Fletcher-32.  Blocks are assembled big-endian from the byte stream (the
// first byte is the most significant byte); a final partial block is
// zero-padded in the low byte(s).
module fletcher_core #(
    parameter int DATA_WIDTH  = 32,
    parameter int BLOCK_WIDTH = 8
) (
    input  logic                      clk,
    input  logic                      rst,
    input  logic                      init,
    input  logic                      valid,
    input  logic [DATA_WIDTH-1:0]     data,
    input  logic [DATA_WIDTH/8-1:0]   keep,
    input  logic                      last,
    output logic [2*BLOCK_WIDTH-1:0]  tag,
    output logic                      tag_done,
    output logic                      busy,
    output logic                      ready
);

  localparam int unsigned BYTES       = DATA_WIDTH / 8;
  localparam int unsigned BLOCK_BYTES = (BLOCK_WIDTH + 7) / 8;
  localparam int unsigned MODULUS     = (1 << BLOCK_WIDTH) - 1;

  logic [BLOCK_WIDTH-1:0] blk_q;
  logic [3:0]             fill_q;
  logic [BLOCK_WIDTH-1:0] sum1_q;
  logic [BLOCK_WIDTH-1:0] sum2_q;

  // Combinational next values.
  logic [BLOCK_WIDTH-1:0] next_blk;
  logic [3:0]             next_fill;
  logic [BLOCK_WIDTH-1:0] next_sum1;
  logic [BLOCK_WIDTH-1:0] next_sum2;
  logic [31:0]            tmp_sum;
  logic [31:0]            tmp_word;

  // MODULUS = 2**BLOCK_WIDTH - 1.  tmp_sum is at most 2*MODULUS, so one
  // end-around fold plus one conditional subtraction is exact and far
  // shallower than the divider Quartus infers for `% MODULUS`.
  function automatic logic [BLOCK_WIDTH-1:0] mod_flet(input logic [31:0] value);
    logic [31:0] folded;
    folded = (value & 32'(MODULUS)) + (value >> BLOCK_WIDTH);
    if (folded >= 32'(MODULUS)) folded = folded - 32'(MODULUS);
    return BLOCK_WIDTH'(folded);
  endfunction

  always_comb begin
    next_blk  = blk_q;
    next_fill = fill_q;
    next_sum1 = sum1_q;
    next_sum2 = sum2_q;
    tmp_sum   = 32'd0;
    tmp_word  = 32'd0;

    for (int unsigned i = 0; i < BYTES; i++) begin
      if (keep[i]) begin
        next_blk = (next_blk << 8) | 8'(data[i*8 +: 8]);
        if (next_fill == 4'(BLOCK_BYTES - 1)) begin
          tmp_sum   = 32'(next_sum1) + 32'(next_blk);
          next_sum1 = mod_flet(tmp_sum);
          tmp_sum   = 32'(next_sum2) + 32'(next_sum1);
          next_sum2 = mod_flet(tmp_sum);
          next_blk  = '0;
          next_fill = 4'd0;
        end else begin
          next_fill = next_fill + 4'd1;
        end
      end
    end

    if (last && (next_fill != 4'd0)) begin
      tmp_word  = 32'(next_blk) << (8 * (BLOCK_BYTES - 32'(next_fill)));
      tmp_sum   = 32'(next_sum1) + tmp_word;
      next_sum1 = mod_flet(tmp_sum);
      tmp_sum   = 32'(next_sum2) + 32'(next_sum1);
      next_sum2 = mod_flet(tmp_sum);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      blk_q    <= '0;
      fill_q   <= '0;
      sum1_q   <= '0;
      sum2_q   <= '0;
      tag_done <= 1'b0;
    end else begin
      tag_done <= 1'b0;
      if (init) begin
        blk_q  <= '0;
        fill_q <= '0;
        sum1_q <= '0;
        sum2_q <= '0;
      end else if (valid) begin
        blk_q  <= next_blk;
        fill_q <= next_fill;
        sum1_q <= next_sum1;
        sum2_q <= next_sum2;
        if (last) begin
          tag_done <= 1'b1;
        end
      end
    end
  end

  assign tag   = {sum2_q, sum1_q};
  assign busy  = 1'b0;
  assign ready = 1'b1;

endmodule
