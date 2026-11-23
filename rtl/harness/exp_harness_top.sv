// Board-independent measurement harness top.
//
// A deterministic stimulus generator feeds one error injector; the resulting
// stream is broadcast to all lanes (TX -> RX pairs).  Lanes consume beats only
// when every lane is ready, so all algorithms observe the identical byte
// stream.  The host-facing UART report is implemented by report_uart.
module exp_harness_top #(
    parameter int  DATA_WIDTH   = 32,
    parameter int  NUM_PACKETS  = 32,
    parameter int  LEN_MIN      = 0,
    parameter int  LEN_MAX      = 128,
    parameter logic [31:0] SEED = 32'h1234_5678,
    parameter int  MODE         = 0,
    parameter int  BURST_LEN    = 8,
    parameter int  GE_P_GB_Q16  = 8,
    parameter int  GE_P_BG_Q16  = 8192,
    parameter int  GE_H_Q16     = 65535,
    parameter bit  INCLUDE_SHA  = 1'b1,
    parameter bit  ENABLE_UART  = 1'b0,
    parameter int  CLK_FREQ_HZ  = 50_000_000,
    parameter int  BAUD_RATE    = 115_200
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic         uart_rxd,
    output logic         uart_txd,
    output logic         done,
    output logic         busy,
    output logic [5:0][31:0] packets_total,
    output logic [5:0][31:0] corrupted_total,
    output logic [5:0][31:0] detected_total,
    output logic [5:0][31:0] missed_total,
    output logic [5:0][31:0] false_total,
    output logic [5:0][31:0] bytes_total,
    output logic [5:0][31:0] cycles_total,
    output logic [5:0][31:0] corrupted_weights,
    output logic [5:0][31:0] missed_weights
);

  localparam int unsigned LANES = INCLUDE_SHA ? 6 : 5;

  logic [DATA_WIDTH-1:0]   stim_tdata;
  logic [DATA_WIDTH/8-1:0] stim_tkeep;
  logic                    stim_tvalid;
  logic                    stim_tready;
  logic                    stim_tlast;
  logic                    stim_done;

  logic [LANES-1:0] lane_ready;
  logic [31:0] l_packets[0:5];
  logic [31:0] l_corrupted[0:5];
  logic [31:0] l_detected[0:5];
  logic [31:0] l_missed[0:5];
  logic [31:0] l_false[0:5];
  logic [31:0] l_bytes[0:5];
  logic [31:0] l_cycles[0:5];
  logic [31:0] l_cw[0:5];
  logic [31:0] l_mw[0:5];

  // Broadcast register: one beat is held until every lane has accepted it,
  // so no lane can receive a beat twice or see a different stream.
  logic                    bcast_valid_q;
  logic [DATA_WIDTH-1:0]   bcast_tdata_q;
  logic [DATA_WIDTH/8-1:0] bcast_tkeep_q;
  logic                    bcast_tlast_q;
  logic [LANES-1:0]        accepted_q;
  logic [LANES-1:0]        accept_now;
  logic [LANES-1:0]        next_accepted;
  logic                    beat_all_done;

  assign accept_now = {LANES{1'b1}} & lane_ready &
                      {LANES{bcast_valid_q}} & ~accepted_q;
  assign next_accepted = accepted_q | accept_now;
  assign beat_all_done  = bcast_valid_q && (&next_accepted);
  assign stim_tready    = !bcast_valid_q;

  /* verilator lint_off PINCONNECTEMPTY */
  stimulus_gen #(
      .DATA_WIDTH(DATA_WIDTH), .NUM_PACKETS(NUM_PACKETS),
      .LEN_MIN(LEN_MIN), .LEN_MAX(LEN_MAX), .SEED(SEED)
  ) u_stim (
      .clk, .rst, .start,
      .m_axis_tdata(stim_tdata), .m_axis_tkeep(stim_tkeep),
      .m_axis_tvalid(stim_tvalid), .m_axis_tready(stim_tready),
      .m_axis_tlast(stim_tlast),
      .done(stim_done), .busy()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  always_ff @(posedge clk) begin
    if (rst) begin
      bcast_valid_q <= 1'b0;
      bcast_tdata_q <= '0;
      bcast_tkeep_q <= '0;
      bcast_tlast_q <= 1'b0;
      accepted_q    <= '0;
    end else if (!bcast_valid_q) begin
      if (stim_tvalid) begin
        bcast_valid_q <= 1'b1;
        bcast_tdata_q <= stim_tdata;
        bcast_tkeep_q <= stim_tkeep;
        bcast_tlast_q <= stim_tlast;
        accepted_q    <= '0;
      end
    end else if (beat_all_done) begin
      bcast_valid_q <= 1'b0;
    end else begin
      accepted_q <= next_accepted;
    end
  end

  integrity_lane #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(0), .TAG_WIDTH(1),
      .PARITY_ODD(1'b0),
      .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_lane0 (
      .clk, .rst,
      .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
      .s_axis_tvalid(bcast_valid_q && !accepted_q[0]), .s_axis_tready(lane_ready[0]),
      .s_axis_tlast(bcast_tlast_q),
      .packets_total(l_packets[0]), .corrupted_total(l_corrupted[0]),
      .detected_total(l_detected[0]), .missed_total(l_missed[0]),
      .false_total(l_false[0]), .bytes_total(l_bytes[0]),
      .cycles_total(l_cycles[0]),
      .corrupted_weights(l_cw[0]), .missed_weights(l_mw[0])
  );

  integrity_lane #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(1), .TAG_WIDTH(16),
      .SUM_WIDTH(16), .ONES_COMPLEMENT(1'b1),
      .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_lane1 (
      .clk, .rst,
      .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
      .s_axis_tvalid(bcast_valid_q && !accepted_q[1]), .s_axis_tready(lane_ready[1]),
      .s_axis_tlast(bcast_tlast_q),
      .packets_total(l_packets[1]), .corrupted_total(l_corrupted[1]),
      .detected_total(l_detected[1]), .missed_total(l_missed[1]),
      .false_total(l_false[1]), .bytes_total(l_bytes[1]),
      .cycles_total(l_cycles[1]),
      .corrupted_weights(l_cw[1]), .missed_weights(l_mw[1])
  );

  integrity_lane #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(2), .TAG_WIDTH(16),
      .BLOCK_WIDTH(8),
      .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_lane2 (
      .clk, .rst,
      .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
      .s_axis_tvalid(bcast_valid_q && !accepted_q[2]), .s_axis_tready(lane_ready[2]),
      .s_axis_tlast(bcast_tlast_q),
      .packets_total(l_packets[2]), .corrupted_total(l_corrupted[2]),
      .detected_total(l_detected[2]), .missed_total(l_missed[2]),
      .false_total(l_false[2]), .bytes_total(l_bytes[2]),
      .cycles_total(l_cycles[2]),
      .corrupted_weights(l_cw[2]), .missed_weights(l_mw[2])
  );

  integrity_lane #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(3), .TAG_WIDTH(32),
      .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_lane3 (
      .clk, .rst,
      .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
      .s_axis_tvalid(bcast_valid_q && !accepted_q[3]), .s_axis_tready(lane_ready[3]),
      .s_axis_tlast(bcast_tlast_q),
      .packets_total(l_packets[3]), .corrupted_total(l_corrupted[3]),
      .detected_total(l_detected[3]), .missed_total(l_missed[3]),
      .false_total(l_false[3]), .bytes_total(l_bytes[3]),
      .cycles_total(l_cycles[3]),
      .corrupted_weights(l_cw[3]), .missed_weights(l_mw[3])
  );

  integrity_lane #(
      .DATA_WIDTH(DATA_WIDTH), .ALGO(4), .TAG_WIDTH(32), .CRC_WIDTH(32),
      .CRC_POLY(32'h04C11DB7), .CRC_INIT(32'hFFFFFFFF),
      .CRC_REFIN(1'b1), .CRC_REFOUT(1'b1), .CRC_XOROUT(32'hFFFFFFFF),
      .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
      .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
      .GE_H_Q16(GE_H_Q16)
  ) u_lane4 (
      .clk, .rst,
      .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
      .s_axis_tvalid(bcast_valid_q && !accepted_q[4]), .s_axis_tready(lane_ready[4]),
      .s_axis_tlast(bcast_tlast_q),
      .packets_total(l_packets[4]), .corrupted_total(l_corrupted[4]),
      .detected_total(l_detected[4]), .missed_total(l_missed[4]),
      .false_total(l_false[4]), .bytes_total(l_bytes[4]),
      .cycles_total(l_cycles[4]),
      .corrupted_weights(l_cw[4]), .missed_weights(l_mw[4])
  );

  if (INCLUDE_SHA) begin : g_sha_lane
    integrity_lane #(
        .DATA_WIDTH(DATA_WIDTH), .ALGO(5), .TAG_WIDTH(256),
        .MODE(MODE), .BURST_LEN(BURST_LEN), .ERR_SEED(SEED ^ 32'hA5A5_5A5A),
        .GE_P_GB_Q16(GE_P_GB_Q16), .GE_P_BG_Q16(GE_P_BG_Q16),
        .GE_H_Q16(GE_H_Q16)
    ) u_lane5 (
        .clk, .rst,
        .s_axis_tdata(bcast_tdata_q), .s_axis_tkeep(bcast_tkeep_q),
        .s_axis_tvalid(bcast_valid_q && !accepted_q[5]), .s_axis_tready(lane_ready[5]),
        .s_axis_tlast(bcast_tlast_q),
        .packets_total(l_packets[5]), .corrupted_total(l_corrupted[5]),
        .detected_total(l_detected[5]), .missed_total(l_missed[5]),
        .false_total(l_false[5]), .bytes_total(l_bytes[5]),
        .cycles_total(l_cycles[5]),
        .corrupted_weights(l_cw[5]), .missed_weights(l_mw[5])
    );
  end else begin : g_no_sha
    assign l_packets[5]   = 32'd0;
    assign l_corrupted[5] = 32'd0;
    assign l_detected[5]  = 32'd0;
    assign l_missed[5]    = 32'd0;
    assign l_false[5]     = 32'd0;
    assign l_bytes[5]     = 32'd0;
    assign l_cycles[5]    = 32'd0;
    assign l_cw[5]        = 32'd0;
    assign l_mw[5]        = 32'd0;
    assign lane_ready[5]  = 1'b1;
  end

  always_comb begin
    done = stim_done;
    busy = !stim_done;
    for (int unsigned i = 0; i < LANES; i++) begin
      done = done && (l_packets[i] >= NUM_PACKETS);
      busy = busy || (l_packets[i] < NUM_PACKETS);
    end
    packets_total   = '0;
    corrupted_total = '0;
    detected_total  = '0;
    missed_total    = '0;
    false_total     = '0;
    bytes_total     = '0;
    cycles_total    = '0;
    corrupted_weights = '0;
    missed_weights    = '0;
    for (int unsigned i = 0; i < 6; i++) begin
      packets_total[i]   = l_packets[i];
      corrupted_total[i] = l_corrupted[i];
      detected_total[i]  = l_detected[i];
      missed_total[i]    = l_missed[i];
      false_total[i]     = l_false[i];
      bytes_total[i]     = l_bytes[i];
      cycles_total[i]    = l_cycles[i];
      corrupted_weights[i] = l_cw[i];
      missed_weights[i]    = l_mw[i];
    end
  end

  // UART report is optional; ENABLE_UART is a constant so it disappears when
  // disabled.  uart_rxd is used as a "host line idle" gate so a report is not
  // started while the host is driving a command.
  logic report_start;
  assign report_start = done && uart_rxd && ENABLE_UART;

  report_uart #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)
  ) u_report (
      .clk, .rst, .start(report_start),
      .packets_total, .corrupted_total, .detected_total,
      .missed_total, .false_total, .bytes_total, .cycles_total,
      .uart_txd
  );

endmodule
