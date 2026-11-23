// DE2-115 board top for the integrity measurement stand.
//
// Board: Terasic DE2-115, Cyclone IV E EP4CE115F29C7.
// Input clock: on-board 50 MHz oscillator (CLOCK_50, PIN_Y2).
// Stand clock: CLOCK_50 / 4 = 12.5 MHz (2-bit counter toggle).  TimeQuest
//              Fmax is ~23.6 MHz on the slow 85C model, so 50 MHz cannot
//              close timing without a deep RTL re-pipeline.
// Reset: KEY[0] (PIN_M23), active low on the board.
// Host link: RS-232 via the on-board transceiver
//            UART_RXD = PIN_G12, UART_TXD = PIN_G9, 115200 8N1.
//
// The campaign starts automatically after reset.  KEY[0] re-runs it.
// Visualization:
//   HEX7     = selected lane (KEY[1] cycles 0..5)
//   HEX6..4  = packets processed by that lane (hex, live)
//   HEX3..0  = payload bytes processed by that lane (hex, live)
//   LEDG[5:0]= per-lane pass (no missed packets after the campaign)
//   LEDR[0]  = heartbeat, LEDR[1] = busy, LEDR[2] = done
module de2_115_top (
    input  logic         CLOCK_50,
    input  logic [3:0]   KEY,
    input  logic         UART_RXD,
    output logic         UART_TXD,
    output logic [17:0]  LEDR,
    output logic [8:0]   LEDG,
    output logic [7:0][6:0] HEX
);
  localparam int CLK_FREQ_HZ = 12_500_000;
  localparam int BAUD_RATE   = 115_200;

  // Fixed 64-byte packets keep SPAN=1 in stimulus_gen: a variable length
  // forced Quartus 21.1 to infer a 79 ns divider.  The simulator reference
  // was regenerated with the same parameters.
  parameter int NUM_PACKETS = 64;
  parameter int LEN_MIN     = 64;
  parameter int LEN_MAX     = 64;
  parameter int MODE        = 0;
  parameter logic [31:0] SEED = 32'h1234_5678;
  parameter bit INCLUDE_SHA  = 1'b1;

  // Power-on reset and a short reset pulse on the falling edge of KEY[0].
  // Using the button level directly can leave the stand held in reset if the
  // line is not high at configuration time or the button is held down.
  logic key0_meta, key0_sync;
  always_ff @(posedge CLOCK_50) begin
    key0_meta <= KEY[0];
    key0_sync <= key0_meta;
  end
  wire key0_press = key0_sync & ~key0_meta;  // active-low button, falling edge

  logic [19:0] rst_cnt_q;
  always_ff @(posedge CLOCK_50) begin
    if (key0_press) rst_cnt_q <= 20'd0;
    else if (rst_cnt_q != 20'hFFFFF) rst_cnt_q <= rst_cnt_q + 20'd1;
  end
  // Assert reset for ~26 ms after power-up or after KEY[0] is pressed.
  wire rst = (rst_cnt_q < 20'd330000);

  // 50 MHz / 4 -> 12.5 MHz.  Bit 1 of the counter toggles every 4 input
  // clocks, giving a 50 % duty cycle without an IP PLL.
  // Free-running divider: clk_std must keep toggling while rst is asserted,
  // otherwise report_uart's registers never see the reset edge and start_q
  // stays high, suppressing the next report after KEY[0].
  logic [1:0] div_q;
  always_ff @(posedge CLOCK_50) div_q <= div_q + 2'd1;
  logic clk_std;
  assign clk_std = div_q[1];

  logic start;
  assign start = 1'b1;                 // auto-start one campaign after reset release

  logic done, busy;
  logic [5:0][31:0] packets_total, corrupted_total, detected_total;
  logic [5:0][31:0] missed_total, false_total, bytes_total, cycles_total;
  logic [5:0][31:0] corrupted_weights, missed_weights;

  exp_harness_top #(
      .DATA_WIDTH  (32),
      .NUM_PACKETS (NUM_PACKETS),
      .LEN_MIN     (LEN_MIN),
      .LEN_MAX     (LEN_MAX),
      .SEED        (SEED),
      .MODE        (MODE),
      .INCLUDE_SHA (INCLUDE_SHA),
      .ENABLE_UART (1'b1),
      .CLK_FREQ_HZ (CLK_FREQ_HZ),
      .BAUD_RATE   (BAUD_RATE)
  ) u_harness (
      .clk    (clk_std),
      .rst    (rst),
      .start  (start),
      // The report formatter uses uart_rxd only as a "host line idle" gate.
      // Tie it high: the RS-232 transceiver can hold the physical pin low
      // when no host is transmitting, which would suppress the report.
      .uart_rxd (1'b1),
      .uart_txd (UART_TXD),
      .done   (done),
      .busy   (busy),
      .packets_total    (packets_total),
      .corrupted_total  (corrupted_total),
      .detected_total   (detected_total),
      .missed_total     (missed_total),
      .false_total      (false_total),
      .bytes_total      (bytes_total),
      .cycles_total     (cycles_total),
      .corrupted_weights(corrupted_weights),
      .missed_weights   (missed_weights)
  );

  // --- Visualization -------------------------------------------------------
  // Active-low, common-anode hex decoder (bit 0 = segment a ... bit 6 = g).
  function automatic logic [6:0] hex7(input logic [3:0] value);
    case (value)
      4'h0: hex7 = 7'b1000000;
      4'h1: hex7 = 7'b1111001;
      4'h2: hex7 = 7'b0100100;
      4'h3: hex7 = 7'b0110000;
      4'h4: hex7 = 7'b0011001;
      4'h5: hex7 = 7'b0010010;
      4'h6: hex7 = 7'b0000010;
      4'h7: hex7 = 7'b1111000;
      4'h8: hex7 = 7'b0000000;
      4'h9: hex7 = 7'b0010000;
      4'hA: hex7 = 7'b0001000;
      4'hB: hex7 = 7'b0000011;
      4'hC: hex7 = 7'b1000110;
      4'hD: hex7 = 7'b0100001;
      4'hE: hex7 = 7'b0000110;
      default: hex7 = 7'b0001110;
    endcase
  endfunction

  // KEY[1] selects the lane shown on the 7-segment displays.  A simple
  // 20 ms debounce at 12.5 MHz keeps the display stable.
  logic [17:0] key_db_q;
  logic [2:0]  lane_sel_q;
  always_ff @(posedge clk_std or posedge rst) begin
    if (rst) begin
      key_db_q   <= 18'd0;
      lane_sel_q <= 3'd0;
    end else begin
      if (KEY[1]) key_db_q <= 18'd0;
      else if (key_db_q != 18'd250000) key_db_q <= key_db_q + 18'd1;

      if (key_db_q == 18'd250000) begin
        lane_sel_q <= (lane_sel_q == 3'd5) ? 3'd0 : lane_sel_q + 3'd1;
      end
    end
  end

  logic [31:0] pkt_sel;
  logic [31:0] byte_sel;
  always_comb begin
    pkt_sel  = packets_total[lane_sel_q];
    byte_sel = bytes_total[lane_sel_q];
    HEX[7] = hex7({1'b0, lane_sel_q});
    HEX[6] = hex7(pkt_sel[11:8]);
    HEX[5] = hex7(pkt_sel[7:4]);
    HEX[4] = hex7(pkt_sel[3:0]);
    HEX[3] = hex7(byte_sel[15:12]);
    HEX[2] = hex7(byte_sel[11:8]);
    HEX[1] = hex7(byte_sel[7:4]);
    HEX[0] = hex7(byte_sel[3:0]);
  end

  // One green LED per lane: lit when the campaign for that lane has no missed
  // detections.  LEDG[8] mirrors the overall done signal.
  always_comb begin
    for (int unsigned i = 0; i < 6; i++) begin
      LEDG[i] = done && (missed_total[i] == 32'd0);
    end
    LEDG[6] = 1'b0;
    LEDG[7] = 1'b0;
    LEDG[8] = done;
  end

  // Slow heartbeat proves the 12.5 MHz clock and reset are alive.
  logic [23:0] hb_q;
  always_ff @(posedge clk_std or posedge rst) begin
    if (rst) hb_q <= 24'd0;
    else     hb_q <= hb_q + 24'd1;
  end

  assign LEDR = {15'd0, done, busy, hb_q[23]};
endmodule
