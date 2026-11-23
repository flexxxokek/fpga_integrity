// One measurement lane: TX -> RX for a single algorithm plus counters.
//
// The lane consumes the broadcast stimulus and internally connects the tag
// generator to the checker.  `corrupt` is supplied by the injector; the lane
// keeps a small per-packet flag queue because the RX releases tlast after the
// trailing tag has been checked.
module integrity_lane #(
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
    parameter logic [CRC_WIDTH-1:0] CRC_XOROUT = 32'hFFFFFFFF,
    // error injection on the TX -> RX link
    parameter int  MODE            = 0,
    parameter int  BURST_LEN       = 8,
    parameter logic [31:0] ERR_SEED = 32'h5,
    parameter int  GE_P_GB_Q16     = 8,
    parameter int  GE_P_BG_Q16     = 8192,
    parameter int  GE_H_Q16        = 65535
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    output logic [31:0]             packets_total,
    output logic [31:0]             corrupted_total,
    output logic [31:0]             detected_total,
    output logic [31:0]             missed_total,
    output logic [31:0]             false_total,
    output logic [31:0]             bytes_total,
    output logic [31:0]             cycles_total,
    // Per-weight counters: four 8-bit buckets [m=1, m=2, m=3, m>=4].
    output logic [31:0]             corrupted_weights,
    output logic [31:0]             missed_weights
);

  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;

  // TX output (tag + payload) and the link after error injection.
  logic [DATA_WIDTH-1:0]   tx_tdata;
  logic [DATA_WIDTH/8-1:0] tx_tkeep;
  logic                    tx_tvalid;
  logic                    tx_tready;
  logic                    tx_tlast;

  logic [DATA_WIDTH-1:0]   link_tdata;
  logic [DATA_WIDTH/8-1:0] link_tkeep;
  logic                    link_tvalid;
  logic                    link_tready;
  logic                    link_tlast;
  logic                    link_corrupt;
  logic [2:0]              link_flip_count;

  /* verilator lint_off UNUSEDSIGNAL */
  logic [DATA_WIDTH-1:0]   out_tdata;
  logic [DATA_WIDTH/8-1:0] out_tkeep;
  logic                    out_tvalid;
  logic                    out_tlast;
  logic                    out_tag_valid;
  logic                    out_tag_error;

  // Small per-packet corruption flag and injection-weight queue.
  logic [3:0] corrupt_fifo;
  logic [2:0] weight_fifo[0:3];
  logic [1:0] fifo_wr;
  logic [1:0] fifo_rd;
  logic [2:0] fifo_count;

  logic [7:0] out_bytes;
  logic       out_corrupt;
  logic [2:0] out_weight;
  logic       pkt_corrupt_q;
  logic       tag_phase_q;

  logic       tx_busy;
  logic       rx_busy;
  logic       lane_busy;

  // Cycles during which this lane is actually engaged with the stream.  Idle
  // cycles spent waiting for another lane (the broadcast holds a beat until
  // every lane is ready) are excluded, so the counter reflects the cost of
  // this particular algorithm rather than the slowest lane in the stand.
  assign lane_busy = (s_axis_tvalid && s_axis_tready) || tx_tvalid || tx_busy ||
                     link_tvalid || rx_busy || out_tvalid;

  /* verilator lint_off PINCONNECTEMPTY */
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
      .m_axis_tdata(tx_tdata), .m_axis_tkeep(tx_tkeep),
      .m_axis_tvalid(tx_tvalid), .m_axis_tready(tx_tready),
      .m_axis_tlast(tx_tlast),
      .tag_value(), .tag_valid(), .busy(tx_busy)
  );

  error_injector #(
      .DATA_WIDTH(DATA_WIDTH), .MODE(MODE), .BURST_LEN(BURST_LEN),
      .SEED(ERR_SEED),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_err (
      .clk, .rst,
      .s_axis_tdata(tx_tdata), .s_axis_tkeep(tx_tkeep),
      .s_axis_tvalid(tx_tvalid), .s_axis_tready(tx_tready),
      .s_axis_tlast(tx_tlast),
      .enable(!tag_phase_q),
      .m_axis_tdata(link_tdata), .m_axis_tkeep(link_tkeep),
      .m_axis_tvalid(link_tvalid), .m_axis_tready(link_tready),
      .m_axis_tlast(link_tlast), .corrupt(link_corrupt),
      .flip_count(link_flip_count)
  );

  integrity_rx #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(ALGO), .TAG_WIDTH(TAG_WIDTH),
      .PARITY_ODD(PARITY_ODD), .SUM_WIDTH(SUM_WIDTH),
      .ONES_COMPLEMENT(ONES_COMPLEMENT), .BLOCK_WIDTH(BLOCK_WIDTH),
      .CRC_WIDTH(CRC_WIDTH), .CRC_POLY(CRC_POLY), .CRC_INIT(CRC_INIT),
      .CRC_REFIN(CRC_REFIN), .CRC_REFOUT(CRC_REFOUT), .CRC_XOROUT(CRC_XOROUT)
  ) u_rx (
      .clk, .rst,
      .s_axis_tdata(link_tdata), .s_axis_tkeep(link_tkeep),
      .s_axis_tvalid(link_tvalid), .s_axis_tready(link_tready),
      .s_axis_tlast(link_tlast),
      .m_axis_tdata(out_tdata), .m_axis_tkeep(out_tkeep),
      .m_axis_tvalid(out_tvalid), .m_axis_tready(1'b1), .m_axis_tlast(out_tlast),
      .tag_value(), .tag_valid(out_tag_valid), .tag_error(out_tag_error),
      .busy(rx_busy)
  );
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on PINCONNECTEMPTY */

  always_comb begin
    out_bytes = 8'd0;
    for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
      if (out_tkeep[i]) begin
        out_bytes = out_bytes + 8'd1;
      end
    end
  end

  assign out_corrupt = corrupt_fifo[fifo_rd];
  assign out_weight  = weight_fifo[fifo_rd];

  always_ff @(posedge clk) begin
    if (rst) begin
      packets_total   <= 32'd0;
      corrupted_total <= 32'd0;
      detected_total  <= 32'd0;
      missed_total    <= 32'd0;
      false_total     <= 32'd0;
      bytes_total     <= 32'd0;
      cycles_total    <= 32'd0;
      corrupted_weights <= 32'd0;
      missed_weights    <= 32'd0;
      corrupt_fifo    <= 4'd0;
      for (int unsigned i = 0; i < 4; i++) begin
        weight_fifo[i] <= 3'd0;
      end
      fifo_wr         <= 2'd0;
      fifo_rd         <= 2'd0;
      fifo_count      <= 3'd0;
      pkt_corrupt_q   <= 1'b0;
      tag_phase_q     <= 1'b0;
    end else begin
      if (lane_busy) begin
        cycles_total <= cycles_total + 32'd1;
      end
      // The TX emits the payload last beat and the tag last beat with tlast;
      // toggle on each one to know when the link carries tag data.
      if (tx_tvalid && tx_tready && tx_tlast) begin
        tag_phase_q <= ~tag_phase_q;
      end
      // Track whether this packet was corrupted on the TX -> RX link and push
      // one flag per packet when its trailing tag has been accepted.
      if (link_tvalid && link_tready && link_tlast && !tag_phase_q) begin
        corrupt_fifo[fifo_wr] <= pkt_corrupt_q || link_corrupt;
        weight_fifo[fifo_wr]  <= link_flip_count;
        fifo_wr <= fifo_wr + 2'd1;
        if (fifo_count != 3'd4) begin
          fifo_count <= fifo_count + 3'd1;
        end
        pkt_corrupt_q <= 1'b0;
      end else if (link_tvalid && link_tready && link_corrupt) begin
        pkt_corrupt_q <= 1'b1;
      end

      if (out_tvalid) begin
        bytes_total <= bytes_total + 32'(out_bytes);
        if (out_tlast) begin
          packets_total <= packets_total + 32'd1;
          if (out_corrupt) begin
            automatic int unsigned bucket =
                (out_weight >= 3'd4) ? 3 : (out_weight == 0 ? 0 : int'(out_weight) - 1);
            corrupted_total <= corrupted_total + 32'd1;
            corrupted_weights[8*bucket +: 8] <=
                corrupted_weights[8*bucket +: 8] + 8'd1;
            if (out_tag_error) begin
              detected_total <= detected_total + 32'd1;
            end else begin
              missed_total <= missed_total + 32'd1;
              missed_weights[8*bucket +: 8] <=
                  missed_weights[8*bucket +: 8] + 8'd1;
            end
          end else if (out_tag_error) begin
            false_total <= false_total + 32'd1;
          end
          fifo_rd <= fifo_rd + 2'd1;
          if (fifo_count != 3'd0) begin
            fifo_count <= fifo_count - 3'd1;
          end
        end
      end
    end
  end

endmodule
