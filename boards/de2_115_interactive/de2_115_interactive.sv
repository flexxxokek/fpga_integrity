// Interactive hash demo for Terasic DE2-115.
//
// Host sends: A5 5A LEN <payload bytes> XOR   (UART 115200 8N1, LEN <= 64)
// Board replies: HASH,<lane>,<TAG_HEX>,<TICKS_HEX>\n x6, then DONE\n
// TICKS counts stand-clock cycles from the first accepted payload beat until
// tag_valid for that lane; it is the real on-chip latency of the algorithm.
module de2_115_interactive #(
    parameter int CLK_FREQ_HZ = 12_500_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int MAX_LEN     = 64
) (
    input  logic         CLOCK_50,
    input  logic         UART_RXD,
    output logic         UART_TXD,
    output logic [17:0]  LEDR
);
  // ---------------------------------------------------------------- clock ---
  logic [1:0] div_q;
  always_ff @(posedge CLOCK_50) div_q <= div_q + 2'd1;
  wire clk = div_q[1];                       // 12.5 MHz, free-running

  /* verilator lint_off SYNCASYNCNET */
  logic [19:0] por_q;
  always_ff @(posedge CLOCK_50) begin
    if (por_q != 20'hFFFFF) por_q <= por_q + 20'd1;
  end
  wire rst = (por_q < 20'd330000);           // ~26 ms power-on reset
  /* verilator lint_on SYNCASYNCNET */

  // ------------------------------------------------------------ UART link ---
  logic [7:0] rx_data;
  logic       rx_valid;
  logic       rx_ack_q;
  logic       rx_valid_prev_q;
  uart_rx_sync #(
      .CLK_FREQ_HZ(50_000_000), .BAUD_RATE(BAUD_RATE)
  ) u_rx (
      .clk_fast(CLOCK_50), .rst(rst), .rxd(UART_RXD),
      .clk_slow(clk), .data(rx_data), .valid(rx_valid),
      .ack(rx_ack_q)
  );

  // Convert the level-oriented handshake into one pulse per received byte.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      rx_valid_prev_q <= 1'b0;
      rx_ack_q        <= 1'b0;
    end else begin
      rx_valid_prev_q <= rx_valid;
      rx_ack_q        <= 1'b0;
      if (rx_valid && !rx_valid_prev_q) rx_ack_q <= 1'b1;
    end
  end
  wire rx_byte_pulse = rx_valid && !rx_valid_prev_q;

  logic       tx_start;
  logic [7:0] tx_data;
  logic       tx_ready;
  logic       tx_txd;
  uart_tx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)
  ) u_tx (
      .clk(clk), .rst(rst), .start(tx_start), .data(tx_data),
      /* verilator lint_off PINCONNECTEMPTY */
      .txd(tx_txd), .ready(tx_ready), .busy()
      /* verilator lint_on PINCONNECTEMPTY */
  );
  assign UART_TXD = tx_txd;

  // ------------------------------------------------------- frame parser -----
  localparam logic [7:0] MAGIC1 = 8'hA5;
  localparam logic [7:0] MAGIC2 = 8'h5A;

  logic [7:0] payload_q [0:MAX_LEN-1];
  logic [7:0] len_q;
  logic [7:0] byte_cnt_q;
  logic [7:0] xor_q;
  logic [2:0] parse_q;                       // 0: magic1, 1: magic2, 2: len,
                                             // 3: payload, 4: xor
  logic       frame_q;                       // one-cycle "valid frame" pulse

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      len_q <= 8'd0; byte_cnt_q <= 8'd0; xor_q <= 8'd0;
      parse_q <= 3'd0; frame_q <= 1'b0;
    end else begin
      frame_q <= 1'b0;
      if (rx_byte_pulse) begin
        case (parse_q)
          3'd0: begin
            if (rx_data == MAGIC1) begin
              xor_q <= MAGIC1;
              parse_q <= 3'd1;
            end
          end
          3'd1: begin
            xor_q <= xor_q ^ rx_data;
            if (rx_data == MAGIC2) parse_q <= 3'd2;
            else                   parse_q <= 3'd0;
          end
          3'd2: begin
            xor_q <= xor_q ^ rx_data;
            len_q <= rx_data;
            byte_cnt_q <= 8'd0;
            if ((rx_data == 8'd0) || (rx_data > 8'(MAX_LEN))) parse_q <= 3'd0;
            else                                          parse_q <= 3'd3;
          end
          3'd3: begin
            xor_q <= xor_q ^ rx_data;
            payload_q[byte_cnt_q[5:0]] <= rx_data;
            byte_cnt_q <= byte_cnt_q + 8'd1;
            if (byte_cnt_q == len_q - 8'd1) parse_q <= 3'd4;
          end
          3'd4: begin
            if (rx_data == xor_q) frame_q <= 1'b1;
            parse_q <= 3'd0;
          end
          default: parse_q <= 3'd0;
        endcase
      end
    end
  end

  // -------------------------------------------------------- integrity TX ---
  wire  [7:0]   s_tdata;
  wire          s_tvalid, s_tlast;
  logic         all_tready;
  logic [5:0]   tx_ready_v;
  logic [5:0]   tag_valid_v;
  logic [0:0]   tag0;
  logic [15:0]  tag1, tag2;
  logic [31:0]  tag3, tag4;
  logic [255:0] tag5;
  logic [255:0] tag_wide [0:5];

  interactive_lane_tx #(.ALGO(0), .TAG_WIDTH(1)) u_l0 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[0]),
      .tag_value(tag0), .tag_valid(tag_valid_v[0]));
  interactive_lane_tx #(.ALGO(1), .TAG_WIDTH(16)) u_l1 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[1]),
      .tag_value(tag1), .tag_valid(tag_valid_v[1]));
  interactive_lane_tx #(.ALGO(2), .TAG_WIDTH(16)) u_l2 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[2]),
      .tag_value(tag2), .tag_valid(tag_valid_v[2]));
  interactive_lane_tx #(.ALGO(3), .TAG_WIDTH(32)) u_l3 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[3]),
      .tag_value(tag3), .tag_valid(tag_valid_v[3]));
  interactive_lane_tx #(.ALGO(4), .TAG_WIDTH(32)) u_l4 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[4]),
      .tag_value(tag4), .tag_valid(tag_valid_v[4]));
  interactive_lane_tx #(.ALGO(5), .TAG_WIDTH(256)) u_l5 (
      .clk(clk), .rst(rst), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
      .s_tlast(s_tlast), .s_tready(tx_ready_v[5]),
      .tag_value(tag5), .tag_valid(tag_valid_v[5]));

  assign tag_wide[0] = {{255{1'b0}}, tag0};
  assign tag_wide[1] = {{240{1'b0}}, tag1};
  assign tag_wide[2] = {{240{1'b0}}, tag2};
  assign tag_wide[3] = {{224{1'b0}}, tag3};
  assign tag_wide[4] = {{224{1'b0}}, tag4};
  assign tag_wide[5] = tag5;

  // Combinational stream: tvalid drops immediately when the last beat is
  // accepted.  A registered tvalid would leave one extra core_valid cycle and
  // feed the last byte twice to CRC/Adler/SHA.
  assign s_tvalid = (run_q == 3'd1);
  assign s_tdata  = payload_q[beat_q[5:0]];
  assign s_tlast  = (beat_q == active_len_q - 8'd1);
  assign all_tready = &tx_ready_v;

  // --------------------------------------------------------- measurement ---
  logic [31:0] cycles_q;
  logic [31:0] ticks_q [0:5];
  logic [255:0] tag_q [0:5];
  logic [5:0]  latched_q;
  logic [2:0]  run_q;                        // 0 idle, 1 payload, 2 wait, 3 send
  logic [7:0]  beat_q;
  logic [7:0]  active_len_q;
  logic        send_q;
  logic        reply_last_q;              // set by the serializer, read by driver

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      cycles_q <= 32'd0; beat_q <= 8'd0; active_len_q <= 8'd0;
      latched_q <= 6'd0; run_q <= 3'd0; send_q <= 1'b0;
    end else begin
      case (run_q)
        3'd0: begin
          if (frame_q) begin
            active_len_q <= len_q;
            beat_q       <= 8'd0;
            cycles_q     <= 32'd0;
            latched_q    <= 6'd0;
            run_q        <= 3'd1;
          end
        end
        3'd1: begin
          if (all_tready) begin
            cycles_q <= cycles_q + 32'd1;
            beat_q   <= beat_q + 8'd1;
            if (beat_q == active_len_q - 8'd1) run_q <= 3'd2;
          end
        end
        3'd2: begin
          cycles_q <= cycles_q + 32'd1;
          for (int i = 0; i < 6; i++) begin
            if (tag_valid_v[i] && !latched_q[i]) begin
              tag_q[i]     <= tag_wide[i];
              ticks_q[i]   <= cycles_q;
              latched_q[i] <= 1'b1;
            end
          end
          if (&latched_q) begin
            run_q  <= 3'd3;
            send_q <= 1'b1;
          end
        end
        3'd3: begin
          if (reply_last_q) begin
            send_q <= 1'b0;
            run_q  <= 3'd0;
          end
        end
        default: run_q <= 3'd0;
      endcase
    end
  end

  // ---------------------------------------------------- binary response ---
  // Fixed frame: 6 lanes x (32-byte tag + 4-byte ticks) + "DONE".
  logic [2:0]   rep_lane;
  logic [5:0]   rep_byte;        // 0..35 inside the current lane
  logic [1:0]   done_idx;        // 0..3 inside "DONE"
  logic [255:0] tag_out;
  logic [31:0]  ticks_out;
  logic [7:0]   next_byte;

  assign tag_out   = tag_q[rep_lane];
  assign ticks_out = ticks_q[rep_lane];

  always_comb begin
    if (rep_lane < 3'd6) begin
      if (rep_byte < 6'd32)
        next_byte = 8'(tag_out >> (8 * (6'd31 - rep_byte)));
      else
        next_byte = 8'(ticks_out >> (8 * (rep_byte - 6'd32)));
    end else begin
      case (done_idx)
        2'd0: next_byte = 8'h44;  // D
        2'd1: next_byte = 8'h4F;  // O
        2'd2: next_byte = 8'h4E;  // N
        default: next_byte = 8'h45;  // E
      endcase
    end
    // Combinational start/data (the proven report_uart style): uart_tx
    // samples both at the same clock edge with no registered handshake.
    tx_start = send_q && tx_ready;
    tx_data  = next_byte;
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      rep_lane <= 3'd0; rep_byte <= 6'd0; done_idx <= 2'd0;
      reply_last_q <= 1'b0;
    end else begin
      reply_last_q <= 1'b0;
      if (!send_q) begin
        rep_lane <= 3'd0; rep_byte <= 6'd0; done_idx <= 2'd0;
      end else if (tx_ready) begin
        if (rep_lane < 3'd6) begin
          if (rep_byte == 6'd35) begin
            rep_byte <= 6'd0;
            rep_lane <= rep_lane + 3'd1;
          end else begin
            rep_byte <= rep_byte + 6'd1;
          end
        end else if (done_idx == 2'd3) begin
          reply_last_q <= 1'b1;
        end else begin
          done_idx <= done_idx + 2'd1;
        end
      end
    end
  end

  // -------------------------------------------------------------- status ---
  logic [23:0] hb_q;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) hb_q <= 24'd0;
    else     hb_q <= hb_q + 24'd1;
  end
  assign LEDR = {15'd0, send_q, (run_q != 3'd0), hb_q[23]};
endmodule
