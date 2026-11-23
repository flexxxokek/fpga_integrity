// 8N1 UART receiver clocked at 50 MHz.
// One sample per bit, taken in the middle of the bit.  With CLK_FREQ_HZ=50e6
// and 115200 baud the bit period is 434 clocks, so the centre sample is far
// from both edges and the residual baud error is below 0.01 %.
module uart_rx_16x #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rxd,
    output logic [7:0] data,
    output logic       valid
);
  /* verilator lint_off WIDTHEXPAND */
  localparam int BIT_TICKS = CLK_FREQ_HZ / BAUD_RATE;   // 434
  localparam int MID_TICK  = BIT_TICKS / 2;             // 217

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_START = 2'd1;
  localparam logic [1:0] S_DATA  = 2'd2;
  localparam logic [1:0] S_STOP  = 2'd3;

  logic [1:0]  state_q;
  logic [9:0]  cnt_q;
  logic [2:0]  bit_q;
  logic [7:0]  shift_q;
  logic        rxd_s;

  assign data  = shift_q;
  assign valid = (state_q == S_STOP) && (cnt_q == BIT_TICKS - 1);

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state_q <= S_IDLE; cnt_q <= 10'd0; bit_q <= 3'd0;
      shift_q <= 8'd0; rxd_s <= 1'b1;
    end else begin
      rxd_s <= rxd;
      case (state_q)
        S_IDLE: begin
          cnt_q <= 10'd0;
          if (!rxd_s) state_q <= S_START;
        end
        S_START: begin
          // Falling edge was seen one clock earlier; wait a full bit so that
          // cnt_q == 0 is the beginning of the first data bit.
          if (cnt_q == BIT_TICKS - 1) begin
            cnt_q <= 10'd0; bit_q <= 3'd0; shift_q <= 8'd0; state_q <= S_DATA;
          end else begin
            cnt_q <= cnt_q + 10'd1;
          end
        end
        S_DATA: begin
          if (cnt_q == MID_TICK - 1) begin
            shift_q <= {rxd_s, shift_q[7:1]};
          end
          if (cnt_q == BIT_TICKS - 1) begin
            cnt_q <= 10'd0;
            if (bit_q == 3'd7) state_q <= S_STOP;
            else               bit_q <= bit_q + 3'd1;
          end else begin
            cnt_q <= cnt_q + 10'd1;
          end
        end
        S_STOP: begin
          if (cnt_q == BIT_TICKS - 1) begin
            cnt_q <= 10'd0;
            state_q <= S_IDLE;
          end else begin
            cnt_q <= cnt_q + 10'd1;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
  /* verilator lint_on WIDTHEXPAND */
endmodule
