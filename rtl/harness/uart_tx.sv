// Minimal 8N1 UART transmitter.
module uart_tx #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       start,
    input  logic [7:0] data,
    output logic       txd,
    output logic       ready,
    output logic       busy
);

  localparam int unsigned DIV = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_START = 2'd1;
  localparam logic [1:0] S_DATA  = 2'd2;
  localparam logic [1:0] S_STOP  = 2'd3;

  logic [1:0] state_q;
  logic [31:0] div_q;
  logic [2:0] bit_q;
  logic [7:0] shift_q;

  assign ready = (state_q == S_IDLE);
  assign busy  = (state_q != S_IDLE);
  assign txd   = (state_q == S_START) ? 1'b0 :
                 (state_q == S_DATA)  ? shift_q[0] : 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      div_q   <= 32'd0;
      bit_q   <= 3'd0;
      shift_q <= 8'd0;
    end else begin
      case (state_q)
        S_IDLE: begin
          div_q <= 32'd0;
          if (start) begin
            shift_q <= data;
            bit_q   <= 3'd0;
            state_q <= S_START;
          end
        end
        S_START, S_DATA, S_STOP: begin
          if (div_q == DIV - 1) begin
            div_q <= 32'd0;
            if (state_q == S_START) begin
              state_q <= S_DATA;
            end else if (state_q == S_DATA) begin
              if (bit_q == 3'd7) begin
                state_q <= S_STOP;
              end else begin
                bit_q   <= bit_q + 3'd1;
                shift_q <= {1'b0, shift_q[7:1]};
              end
            end else begin
              state_q <= S_IDLE;
            end
          end else begin
            div_q <= div_q + 32'd1;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
