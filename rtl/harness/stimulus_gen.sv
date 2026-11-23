// Deterministic PRNG packet source for the measurement harness.
//
// Emits NUM_PACKETS AXI4-Stream packets with lengths in [LEN_MIN, LEN_MAX].
// Payload bytes come from a xorshift32 generator seeded with SEED, so a given
// seed reproduces the same stimulus on simulation and on hardware.
module stimulus_gen #(
    parameter int DATA_WIDTH = 32,
    parameter int NUM_PACKETS = 16,
    parameter int LEN_MIN = 0,
    parameter int LEN_MAX = 128,
    parameter logic [31:0] SEED = 32'h1
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    start,
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic                    done,
    output logic                    busy
);

  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;
  // A localparam lets Quartus infer a divide-by-constant network.  Calling
  // span() inline previously produced a 79 ns combinational divider path.
  localparam int unsigned SPAN = (LEN_MAX > LEN_MIN) ? (LEN_MAX - LEN_MIN + 1) : 1;

  logic [31:0] rng_q;
  logic [31:0] packets_q;
  logic [31:0] remaining_q;
  logic [7:0] mix_b;  // Quartus 21.1 cannot slice a function call directly
  logic active_q;

  function automatic logic [31:0] xs32(input logic [31:0] value);
    logic [31:0] x;
    x = value;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  // Quartus 21.1 elaborates `%` even when the divisor is 1, which costs
  // ~79 ns.  Prune the variable-length branch entirely for SPAN == 1.
  logic [31:0] len_offset;
  generate
    if (SPAN == 1) begin : g_len_fixed
      assign len_offset = 32'd0;
    end else begin : g_len_random
      assign len_offset = xs32(rng_q) % SPAN;
    end
  endgenerate

  logic [31:0] beat_bytes;
  assign beat_bytes = (remaining_q >= BEAT_BYTES) ? BEAT_BYTES : remaining_q;

  assign m_axis_tvalid = active_q;
  assign m_axis_tlast  = active_q && (remaining_q <= BEAT_BYTES);
  assign busy          = active_q;
  assign done          = (packets_q >= NUM_PACKETS) && !active_q;

  // Payload is combinational from the current PRNG state.  A zero-length
  // packet still emits one beat with tkeep == 0.
  always_comb begin
    m_axis_tdata = '0;
    m_axis_tkeep = '0;
    mix_b = 8'd0;
    if (active_q) begin
      for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
        if (i < beat_bytes) begin
          mix_b = 8'(xs32(rng_q ^ (32'(i) * 32'h9E3779B9)));
          m_axis_tdata[i*8 +: 8] = mix_b;
          m_axis_tkeep[i] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rng_q       <= SEED;
      packets_q   <= 32'd0;
      remaining_q <= 32'd0;
      active_q    <= 1'b0;
    end else if (!active_q) begin
      if (start && (packets_q < NUM_PACKETS)) begin
        rng_q       <= xs32(rng_q);
        remaining_q <= LEN_MIN + len_offset;
        active_q    <= 1'b1;
      end
    end else if (m_axis_tready) begin
      if (remaining_q <= BEAT_BYTES) begin
        active_q    <= 1'b0;
        packets_q   <= packets_q + 32'd1;
        remaining_q <= 32'd0;
      end else begin
        rng_q       <= xs32(rng_q);
        remaining_q <= remaining_q - BEAT_BYTES;
      end
    end
  end

endmodule
