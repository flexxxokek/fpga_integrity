// Minimal 8N1 UART receiver (command path for the host protocol).
module uart_rx #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rxd,
    output logic [7:0] data,
    output logic       valid
);

  localparam int unsigned DIV = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
  localparam int unsigned HALF = DIV / 2;

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_START = 2'd1;
  localparam logic [1:0] S_DATA  = 2'd2;
  localparam logic [1:0] S_STOP  = 2'd3;

  logic [1:0]  state_q;
  logic [31:0] div_q;
  logic [2:0]  bit_q;
  logic [7:0]  shift_q;
  logic        rxd_q;

  assign data  = shift_q;
  assign valid = (state_q == S_STOP) && (div_q == DIV - 1) && rxd_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      div_q   <= 32'd0;
      bit_q   <= 3'd0;
      shift_q <= 8'd0;
      rxd_q   <= 1'b1;
    end else begin
      rxd_q <= rxd;
      case (state_q)
        S_IDLE: begin
          div_q <= 32'd0;
          if (!rxd_q) begin
            state_q <= S_START;
          end
        end
        S_START: begin
          if (div_q == HALF - 1) begin
            div_q   <= 32'd0;
            state_q <= S_DATA;
          end else begin
            div_q <= div_q + 32'd1;
          end
        end
        S_DATA: begin
          if (div_q == DIV - 1) begin
            div_q   <= 32'd0;
            shift_q <= {rxd_q, shift_q[7:1]};
            if (bit_q == 3'd7) begin
              state_q <= S_STOP;
            end else begin
              bit_q <= bit_q + 3'd1;
            end
          end else begin
            div_q <= div_q + 32'd1;
          end
        end
        S_STOP: begin
          if (div_q == DIV - 1) begin
            div_q   <= 32'd0;
            state_q <= S_IDLE;
          end else begin
            div_q <= div_q + 32'd1;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
