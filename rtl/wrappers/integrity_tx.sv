// AXI4-Stream tag generator.
//
// Forwards the payload unchanged and, after the payload beat with tlast, emits
// ceil(TAG_WIDTH/8) tag bytes as separate beats (little-endian, final beat has
// tlast).  The core is selected with ALGO; TAG_WIDTH must match the selected
// core's natural tag width.
module integrity_tx #(
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
    // payload input
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    // payload + tag output
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    // sideband
    output logic [TAG_WIDTH-1:0]    tag_value,
    output logic                    tag_valid,
    output logic                    busy
);

  localparam int unsigned TAG_BYTES  = (TAG_WIDTH + 7) / 8;
  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;
  localparam int unsigned TAG_BEATS  = (TAG_BYTES + BEAT_BYTES - 1) / BEAT_BYTES;
  localparam int unsigned TB_BITS    = TAG_BYTES * 8;

  localparam logic [1:0] ST_IDLE    = 2'd0;
  localparam logic [1:0] ST_PAYLOAD = 2'd1;
  localparam logic [1:0] ST_WAIT    = 2'd2;
  localparam logic [1:0] ST_TAG     = 2'd3;

  logic [1:0]  state_q;
  logic [31:0] tag_beat_q;
  logic [TAG_BYTES*8-1:0] tag_buf;

  logic core_init;
  logic core_valid;
  logic core_ready;
  logic core_busy;
  logic core_tag_done;
  logic [TAG_WIDTH-1:0] core_tag;

  assign core_init  = (state_q == ST_IDLE);
  assign core_valid = (state_q == ST_PAYLOAD) && s_axis_tvalid &&
                      s_axis_tready;

  assign s_axis_tready = (state_q == ST_PAYLOAD) && m_axis_tready &&
                         core_ready;

  always_comb begin
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    if (state_q == ST_PAYLOAD) begin
      m_axis_tdata  = s_axis_tdata;
      m_axis_tkeep  = s_axis_tkeep;
      m_axis_tvalid = s_axis_tvalid && core_ready;
      m_axis_tlast  = s_axis_tlast && core_ready;
    end else if (state_q == ST_TAG) begin
      m_axis_tvalid = 1'b1;
      m_axis_tlast  = (tag_beat_q == TAG_BEATS - 1);
      for (int unsigned k = 0; k < BEAT_BYTES; k++) begin
        if ((tag_beat_q * BEAT_BYTES + k) < TAG_BYTES) begin
          m_axis_tdata[k*8 +: 8] =
              tag_buf[(tag_beat_q * BEAT_BYTES + k)*8 +: 8];
          m_axis_tkeep[k] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q    <= ST_IDLE;
      tag_beat_q <= 32'd0;
      tag_buf    <= '0;
      tag_valid  <= 1'b0;
    end else begin
      tag_valid <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          // One cycle is spent here with core_init asserted, ensuring the
          // accumulator is cleared before the first payload beat.
          if (s_axis_tvalid) begin
            state_q <= ST_PAYLOAD;
          end
        end

        ST_PAYLOAD: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
            state_q <= ST_WAIT;
          end
        end

        ST_WAIT: begin
          if (core_tag_done) begin
            tag_buf    <= TB_BITS'(core_tag);
            tag_beat_q <= 32'd0;
            state_q    <= ST_TAG;
          end
        end

        ST_TAG: begin
          if (m_axis_tready) begin
            if (tag_beat_q == TAG_BEATS - 1) begin
              tag_valid <= 1'b1;
              state_q   <= ST_IDLE;
            end else begin
              tag_beat_q <= tag_beat_q + 32'd1;
            end
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign tag_value = core_tag;
  assign busy      = core_busy ||
                     ((state_q != ST_IDLE) && (state_q != ST_PAYLOAD));

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
