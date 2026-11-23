// Text report formatter for the UART host link.
//
// Emits one line per lane with hexadecimal counters:
//   RESULT,<lane>,<packets>,<corrupted>,<detected>,<missed>,<false>,<bytes>,<cycles>\n
// followed by DONE\n.  Hexadecimal is used to keep the formatter small; the
// host script parses it just like the decimal variant in measurement_plan.md.
// `bytes` and `cycles` are the speed counters used for ticks-per-byte analysis.
module report_uart #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              start,
    input  logic [5:0][31:0]  packets_total,
    input  logic [5:0][31:0]  corrupted_total,
    input  logic [5:0][31:0]  detected_total,
    input  logic [5:0][31:0]  missed_total,
    input  logic [5:0][31:0]  false_total,
    input  logic [5:0][31:0]  bytes_total,
    input  logic [5:0][31:0]  cycles_total,
    output logic              uart_txd
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_LINE = 2'd1;
  localparam logic [1:0] S_DONE = 2'd2;
  localparam int unsigned LINE_LEN = 72;

  logic [1:0]  state_q;
  logic [2:0]  lane_q;
  logic [6:0]  pos_q;
  logic        start_q;
  logic        start_pulse;

  logic        tx_start;
  logic [7:0]  tx_data;
  logic        tx_ready;

  assign start_pulse = start && !start_q;

  /* verilator lint_off PINCONNECTEMPTY */
  uart_tx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)
  ) u_uart (
      .clk, .rst, .start(tx_start), .data(tx_data),
      .txd(uart_txd), .ready(tx_ready), .busy()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  function automatic logic [7:0] hex_char(input logic [3:0] value);
    if (value < 4'd10) begin
      return 8'h30 + {4'd0, value};
    end
    return 8'h41 + {4'd0, value} - 8'd10;
  endfunction

  function automatic logic [31:0] field_value(
      input logic [2:0] lane,
      input logic [6:0] pos
  );
    case (pos)
      7'd9, 7'd10, 7'd11, 7'd12, 7'd13, 7'd14, 7'd15, 7'd16:
        return packets_total[lane];
      7'd18, 7'd19, 7'd20, 7'd21, 7'd22, 7'd23, 7'd24, 7'd25:
        return corrupted_total[lane];
      7'd27, 7'd28, 7'd29, 7'd30, 7'd31, 7'd32, 7'd33, 7'd34:
        return detected_total[lane];
      7'd36, 7'd37, 7'd38, 7'd39, 7'd40, 7'd41, 7'd42, 7'd43:
        return missed_total[lane];
      7'd45, 7'd46, 7'd47, 7'd48, 7'd49, 7'd50, 7'd51, 7'd52:
        return false_total[lane];
      7'd54, 7'd55, 7'd56, 7'd57, 7'd58, 7'd59, 7'd60, 7'd61:
        return bytes_total[lane];
      default:
        return cycles_total[lane];
    endcase
  endfunction

  function automatic logic [7:0] char_at(
      input logic [2:0] lane,
      input logic [6:0] pos
  );
    logic [31:0] value;
    value = field_value(lane, pos);
    if (pos >= 7'd9 && pos <= 7'd16) begin
      return hex_char(value[4 * (7'd16 - pos) +: 4]);
    end else if (pos >= 7'd18 && pos <= 7'd25) begin
      return hex_char(value[4 * (7'd25 - pos) +: 4]);
    end else if (pos >= 7'd27 && pos <= 7'd34) begin
      return hex_char(value[4 * (7'd34 - pos) +: 4]);
    end else if (pos >= 7'd36 && pos <= 7'd43) begin
      return hex_char(value[4 * (7'd43 - pos) +: 4]);
    end else if (pos >= 7'd45 && pos <= 7'd52) begin
      return hex_char(value[4 * (7'd52 - pos) +: 4]);
    end else if (pos >= 7'd54 && pos <= 7'd61) begin
      return hex_char(value[4 * (7'd61 - pos) +: 4]);
    end else if (pos >= 7'd63 && pos <= 7'd70) begin
      return hex_char(value[4 * (7'd70 - pos) +: 4]);
    end
    case (pos)
      7'd0: return "R";
      7'd1: return "E";
      7'd2: return "S";
      7'd3: return "U";
      7'd4: return "L";
      7'd5: return "T";
      7'd6: return ",";
      7'd7: return 8'h30 + {5'd0, lane};
      7'd8: return ",";
      7'd17: return ",";
      7'd26: return ",";
      7'd35: return ",";
      7'd44: return ",";
      7'd53: return ",";
      7'd62: return ",";
      default: return "\n";
    endcase
  endfunction

  function automatic logic [7:0] done_char(input logic [6:0] pos);
    case (pos)
      7'd0: return "D";
      7'd1: return "O";
      7'd2: return "N";
      7'd3: return "E";
      default: return "\n";
    endcase
  endfunction

  always_comb begin
    tx_start = 1'b0;
    tx_data  = 8'h00;
    if ((state_q == S_LINE) && tx_ready) begin
      tx_start = 1'b1;
      tx_data  = char_at(lane_q, pos_q);
    end else if ((state_q == S_DONE) && tx_ready) begin
      tx_start = 1'b1;
      tx_data  = done_char(pos_q);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      lane_q  <= 3'd0;
      pos_q   <= 7'd0;
      start_q <= 1'b0;
    end else begin
      start_q <= start;
      case (state_q)
        S_IDLE: begin
          lane_q <= 3'd0;
          pos_q  <= 7'd0;
          if (start_pulse) begin
            state_q <= S_LINE;
          end
        end
        S_LINE: begin
          if (tx_ready) begin
            if (pos_q == 7'(LINE_LEN - 1)) begin
              pos_q <= 7'd0;
              if (lane_q == 3'd5) begin
                state_q <= S_DONE;
              end else begin
                lane_q <= lane_q + 3'd1;
              end
            end else begin
              pos_q <= pos_q + 7'd1;
            end
          end
        end
        S_DONE: begin
          if (tx_ready) begin
            if (pos_q == 7'd4) begin
              state_q <= S_IDLE;
            end else begin
              pos_q <= pos_q + 7'd1;
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
