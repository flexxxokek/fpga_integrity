// Stream error injector.
//
// The same corrupted stream is broadcast to every measurement lane.  Mode
// selects the corruption applied once per packet, on the first valid beat:
//   0 clean, 1 single-bit, 2 burst of BURST_LEN bits, 3 byte swap,
//   4 zero the first payload byte.
module error_injector #(
    parameter int DATA_WIDTH = 32,
    parameter int MODE = 0,
    parameter int BURST_LEN = 8,
    parameter logic [31:0] SEED = 32'h5
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    input  logic                    enable,
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic                    corrupt
);

  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;

  logic [31:0] rng_q;
  logic        injected_q;
  logic        corrupt_q;

  logic [DATA_WIDTH-1:0]   mask;
  logic [DATA_WIDTH-1:0]   swapped;
  logic [DATA_WIDTH-1:0]   swap_bytes;
  logic                    inject_now;
  logic                    beat_has_bytes;
  logic [31:0]             bit_sel;
  logic [31:0]             valid_bits;
  logic [31:0]             rank;

  function automatic logic [31:0] xs32(input logic [31:0] value);
    logic [31:0] x;
    x = value;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  // Byte-swap helper.  The generate keeps the 16-bit slice out of the
  // elaboration when DATA_WIDTH == 8.
  generate
    if (DATA_WIDTH >= 16) begin : g_swap
      always_comb begin
        swap_bytes = s_axis_tdata;
        swap_bytes[7:0]   = s_axis_tdata[15:8];
        swap_bytes[15:8]  = s_axis_tdata[7:0];
      end
    end else begin : g_no_swap
      assign swap_bytes = s_axis_tdata;
    end
  endgenerate

  // Select a bit inside a byte covered by tkeep.  Padding bits are never
  // corrupted, so an injected error always changes payload data.
  always_comb begin
    valid_bits = 32'd0;
    for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
      if (s_axis_tkeep[i]) begin
        valid_bits = valid_bits + 32'd8;
      end
    end

    rank = (valid_bits != 32'd0) ? (rng_q % valid_bits) : 32'd0;
    bit_sel = 32'd0;
    for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
      if (s_axis_tkeep[i]) begin
        if (rank < 32'd8) begin
          bit_sel = 32'(i) * 32'd8 + rank;
        end else begin
          rank = rank - 32'd8;
        end
      end
    end
  end

  always_comb begin
    beat_has_bytes = (s_axis_tkeep != '0);
    inject_now = (MODE != 0) && enable && s_axis_tvalid && !injected_q &&
                 beat_has_bytes;
    mask = '0;
    swapped = s_axis_tdata;
    if (MODE == 2) begin
      for (int unsigned j = 0; j < BURST_LEN; j++) begin
        mask[(bit_sel + j) % DATA_WIDTH] = 1'b1;
      end
    end else begin
      mask[bit_sel] = 1'b1;
    end

    if (MODE == 3) begin
      swapped = swap_bytes;
    end else if (MODE == 4) begin
      swapped[7:0] = 8'h00;
    end else begin
      swapped = s_axis_tdata ^ mask;
    end
  end

  assign s_axis_tready = m_axis_tready;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tkeep  = s_axis_tkeep;
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tdata  = inject_now ? swapped : s_axis_tdata;
  assign corrupt       = corrupt_q || inject_now;

  always_ff @(posedge clk) begin
    if (rst) begin
      rng_q      <= SEED;
      injected_q <= 1'b0;
      corrupt_q  <= 1'b0;
    end else if (s_axis_tvalid && s_axis_tready) begin
      if (inject_now) begin
        rng_q      <= xs32(rng_q);
        injected_q <= 1'b1;
        corrupt_q  <= 1'b1;
      end
      if (s_axis_tlast) begin
        injected_q <= 1'b0;
        corrupt_q  <= 1'b0;
      end
    end
  end

endmodule
