// AXI4-Stream tag checker / stripper.
//
// Payload beats are forwarded immediately except the tlast beat, which is held
// back until the trailing tag has been received and checked.  Tag beats are
// consumed and never forwarded.  The held payload beat is released with
// tlast=1 together with `tag_error`; `tag_valid` is asserted on the same
// handshake.
module integrity_rx #(
    parameter int  DATA_WIDTH       = 32,
    parameter int  ALGO             = 0,
    parameter int  TAG_WIDTH        = 1,
    // parity
    parameter bit  PARITY_ODD       = 1'b0,
    // checksum
    parameter int  SUM_WIDTH        = 16,
    parameter bit  ONES_COMPLEMENT  = 1'b1,
    // Fletcher
    parameter int  BLOCK_WIDTH      = 8,
    // CRC
    parameter int  CRC_WIDTH        = 32,
    parameter logic [CRC_WIDTH-1:0] CRC_POLY   = 32'h04C11DB7,
    parameter logic [CRC_WIDTH-1:0] CRC_INIT   = 32'hFFFFFFFF,
    parameter bit  CRC_REFIN        = 1'b1,
    parameter bit  CRC_REFOUT       = 1'b1,
    parameter logic [CRC_WIDTH-1:0] CRC_XOROUT = 32'hFFFFFFFF
) (
    input  logic                    clk,
    input  logic                    rst,
    // packet + tag input
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    // payload output
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    // sideband
    output logic [TAG_WIDTH-1:0]    tag_value,
    output logic                    tag_valid,
    output logic                    tag_error,
    output logic                    busy
);

  localparam int unsigned TAG_BYTES  = (TAG_WIDTH + 7) / 8;
  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;
  localparam int unsigned TB_BITS    = TAG_BYTES * 8;

  localparam logic [2:0] ST_IDLE  = 3'd0;
  localparam logic [2:0] ST_DATA  = 3'd1;
  localparam logic [2:0] ST_TAG   = 3'd2;
  localparam logic [2:0] ST_WAIT  = 3'd3;
  localparam logic [2:0] ST_FLUSH = 3'd4;

  logic [2:0]  state_q;
  logic [7:0]  tag_count_q;
  logic [7:0]  tag_rx_bytes[0:TAG_BYTES-1];
  logic [TB_BITS-1:0] tag_rx_full;

  logic [DATA_WIDTH-1:0]   held_data_q;
  logic [DATA_WIDTH/8-1:0] held_keep_q;

  logic [TAG_WIDTH-1:0] core_tag_latched;
  logic                 core_tag_ready_q;
  logic                 tag_error_q;

  logic core_init;
  logic core_valid;
  logic core_ready;
  logic core_busy;
  logic core_tag_done;
  logic [TAG_WIDTH-1:0] core_tag;

  logic [7:0] beat_bytes;

  assign core_init  = (state_q == ST_IDLE);
  assign core_valid = (state_q == ST_DATA) && s_axis_tvalid && s_axis_tready;

  always_comb begin
    beat_bytes = 8'd0;
    for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
      if (s_axis_tkeep[i]) begin
        beat_bytes = beat_bytes + 8'd1;
      end
    end
    tag_rx_full = '0;
    for (int unsigned i = 0; i < TAG_BYTES; i++) begin
      tag_rx_full[i*8 +: 8] = tag_rx_bytes[i];
    end
  end

  always_comb begin
    s_axis_tready = 1'b0;
    if (state_q == ST_DATA) begin
      if (s_axis_tlast) begin
        s_axis_tready = core_ready;
      end else begin
        s_axis_tready = m_axis_tready && core_ready;
      end
    end else if (state_q == ST_TAG) begin
      s_axis_tready = 1'b1;
    end
  end

  always_comb begin
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    if (state_q == ST_DATA) begin
      if (!s_axis_tlast) begin
        m_axis_tdata  = s_axis_tdata;
        m_axis_tkeep  = s_axis_tkeep;
        m_axis_tvalid = s_axis_tvalid && core_ready;
      end
    end else if (state_q == ST_FLUSH) begin
      m_axis_tdata  = held_data_q;
      m_axis_tkeep  = held_keep_q;
      m_axis_tvalid = 1'b1;
      m_axis_tlast  = 1'b1;
    end
  end

  assign tag_value = core_tag_latched;
  assign tag_error = tag_error_q;
  assign tag_valid = (state_q == ST_FLUSH) && m_axis_tvalid && m_axis_tready;
  assign busy      = core_busy ||
                     ((state_q != ST_IDLE) && (state_q != ST_DATA));

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q          <= ST_IDLE;
      tag_count_q      <= 8'd0;
      held_data_q      <= '0;
      held_keep_q      <= '0;
      core_tag_latched <= '0;
      core_tag_ready_q <= 1'b0;
      tag_error_q      <= 1'b0;
      for (int unsigned i = 0; i < TAG_BYTES; i++) begin
        tag_rx_bytes[i] <= 8'h00;
      end
    end else begin
      case (state_q)
        ST_IDLE: begin
          tag_count_q      <= 8'd0;
          core_tag_ready_q <= 1'b0;
          tag_error_q      <= 1'b0;
          if (s_axis_tvalid) begin
            state_q <= ST_DATA;
          end
        end

        ST_DATA: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
            held_data_q <= s_axis_tdata;
            held_keep_q <= s_axis_tkeep;
            state_q     <= ST_TAG;
          end
        end

        ST_TAG: begin
          if (core_tag_done && !core_tag_ready_q) begin
            core_tag_latched <= core_tag;
            core_tag_ready_q <= 1'b1;
          end
          if (s_axis_tvalid && s_axis_tready) begin
            for (int unsigned i = 0; i < BEAT_BYTES; i++) begin
              if (s_axis_tkeep[i] &&
                  ((32'(tag_count_q) + i) < TAG_BYTES)) begin
                tag_rx_bytes[32'(tag_count_q) + i] <= s_axis_tdata[i*8 +: 8];
              end
            end
            tag_count_q <= 8'(32'(tag_count_q) + 32'(beat_bytes));
            if (((32'(tag_count_q) + 32'(beat_bytes)) >= TAG_BYTES) ||
                s_axis_tlast) begin
              state_q <= ST_WAIT;
            end
          end
        end

        ST_WAIT: begin
          if (core_tag_done && !core_tag_ready_q) begin
            core_tag_latched <= core_tag;
            core_tag_ready_q <= 1'b1;
          end
          if (core_tag_ready_q) begin
            tag_error_q <= (tag_rx_full != TB_BITS'(core_tag_latched));
            state_q     <= ST_FLUSH;
          end
        end

        ST_FLUSH: begin
          if (m_axis_tready) begin
            state_q <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // Core instance selected at elaboration time.
  // ---------------------------------------------------------------------
  generate
    if (ALGO == 0) begin : g_parity
      parity_core #(
          .DATA_WIDTH (DATA_WIDTH),
          .PARITY_ODD (PARITY_ODD)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end else if (ALGO == 1) begin : g_checksum
      checksum_core #(
          .DATA_WIDTH      (DATA_WIDTH),
          .SUM_WIDTH       (SUM_WIDTH),
          .ONES_COMPLEMENT (ONES_COMPLEMENT)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end else if (ALGO == 2) begin : g_fletcher
      fletcher_core #(
          .DATA_WIDTH  (DATA_WIDTH),
          .BLOCK_WIDTH (BLOCK_WIDTH)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end else if (ALGO == 3) begin : g_adler
      adler32_core #(
          .DATA_WIDTH (DATA_WIDTH)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end else if (ALGO == 4) begin : g_crc
      crc_engine #(
          .DATA_WIDTH (DATA_WIDTH),
          .CRC_WIDTH  (CRC_WIDTH),
          .POLY       (CRC_POLY),
          .INIT       (CRC_INIT),
          .REFIN      (CRC_REFIN),
          .REFOUT     (CRC_REFOUT),
          .XOROUT     (CRC_XOROUT)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end else begin : g_sha256
      sha256_core #(
          .DATA_WIDTH (DATA_WIDTH)
      ) u_core (
          .clk      (clk),
          .rst      (rst),
          .init     (core_init),
          .valid    (core_valid),
          .data     (s_axis_tdata),
          .keep     (s_axis_tkeep),
          .last     (s_axis_tlast),
          .tag      (core_tag),
          .tag_done (core_tag_done),
          .busy     (core_busy),
          .ready    (core_ready)
      );
    end
  endgenerate

endmodule
