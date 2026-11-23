// UART receiver clocked directly from the 50 MHz input, with a level-oriented
// handshake into the 12.5 MHz stand domain.
//
// The original uart_rx sampled from the divided stand clock; at 115200 that
// gives a 109-clock bit period instead of 108.5, which accumulated enough
// phase error to corrupt arbitrary bytes.  At 50 MHz the divisor is 434
// (error < 0.01 %).
module uart_rx_sync #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic        clk_fast,
    input  logic        rst,
    input  logic        rxd,

    input  logic        clk_slow,
    output logic [7:0]  data,
    output logic        valid,      // level: a byte is waiting
    input  logic        ack         // one-cycle pulse in the slow domain
);
  logic [7:0] rx_data;
  logic       rx_valid;

  uart_rx_16x #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .BAUD_RATE(BAUD_RATE)
  ) u_rx (
      .clk(clk_fast), .rst(rst), .rxd(rxd),
      .data(rx_data), .valid(rx_valid)
  );

  logic [7:0] byte_q;
  logic       pending_q;
  logic       ack_meta, ack_sync;

  always_ff @(posedge clk_fast or posedge rst) begin
    if (rst) begin
      byte_q    <= 8'd0;
      pending_q <= 1'b0;
      ack_meta  <= 1'b0;
      ack_sync  <= 1'b0;
    end else begin
      ack_meta <= ack;
      ack_sync <= ack_meta;
      if (rx_valid) begin
        byte_q    <= rx_data;
        pending_q <= 1'b1;
      end else if (ack_sync) begin
        pending_q <= 1'b0;
      end
    end
  end

  logic [1:0] pending_sync;
  always_ff @(posedge clk_slow or posedge rst) begin
    if (rst) pending_sync <= 2'd0;
    else     pending_sync <= {pending_sync[0], pending_q};
  end

  assign valid = pending_sync[1];
  assign data  = byte_q;
endmodule
