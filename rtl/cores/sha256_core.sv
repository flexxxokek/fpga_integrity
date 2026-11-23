// Streaming SHA-256 core (FIPS 180-4).
//
// Bytes are collected into 512-bit blocks in an internal buffer.  Compression
// runs one round per clock; the core deasserts `ready` while a block is being
// compressed, satisfying the AXI-Stream backpressure contract.  On `last` the
// core pads the message (including the 64-bit big-endian bit length), runs the
// remaining block(s) and pulses `tag_done` with the digest available on `tag`.
//
// `tag` is the digest serialised little-endian (byte 0 of the digest in
// tag[7:0]) so that the common TX rule "tag bytes, little-endian" holds.
module sha256_core #(
    parameter int DATA_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init,
    input  logic                    valid,
    input  logic [DATA_WIDTH-1:0]   data,
    input  logic [DATA_WIDTH/8-1:0] keep,
    input  logic                    last,
    output logic [255:0]            tag,
    output logic                    tag_done,
    output logic                    busy,
    output logic                    ready
);

  localparam int unsigned BYTES = DATA_WIDTH / 8;

  localparam logic [2:0] S_FILL     = 3'd0;
  localparam logic [2:0] S_PAD      = 3'd1;
  localparam logic [2:0] S_LOAD     = 3'd2;
  localparam logic [2:0] S_COMPRESS = 3'd3;
  localparam logic [2:0] S_IDLE     = 3'd4;

  // Round constants are exposed through a function rather than an unpacked
  // localparam array: both Yosys and Verilator elaborate this form without
  // vendor-specific attributes.
  function automatic logic [31:0] k_const(input logic [5:0] i);
    case (i)
      6'd0: k_const = 32'h428a2f98;
      6'd1: k_const = 32'h71374491;
      6'd2: k_const = 32'hb5c0fbcf;
      6'd3: k_const = 32'he9b5dba5;
      6'd4: k_const = 32'h3956c25b;
      6'd5: k_const = 32'h59f111f1;
      6'd6: k_const = 32'h923f82a4;
      6'd7: k_const = 32'hab1c5ed5;
      6'd8: k_const = 32'hd807aa98;
      6'd9: k_const = 32'h12835b01;
      6'd10: k_const = 32'h243185be;
      6'd11: k_const = 32'h550c7dc3;
      6'd12: k_const = 32'h72be5d74;
      6'd13: k_const = 32'h80deb1fe;
      6'd14: k_const = 32'h9bdc06a7;
      6'd15: k_const = 32'hc19bf174;
      6'd16: k_const = 32'he49b69c1;
      6'd17: k_const = 32'hefbe4786;
      6'd18: k_const = 32'h0fc19dc6;
      6'd19: k_const = 32'h240ca1cc;
      6'd20: k_const = 32'h2de92c6f;
      6'd21: k_const = 32'h4a7484aa;
      6'd22: k_const = 32'h5cb0a9dc;
      6'd23: k_const = 32'h76f988da;
      6'd24: k_const = 32'h983e5152;
      6'd25: k_const = 32'ha831c66d;
      6'd26: k_const = 32'hb00327c8;
      6'd27: k_const = 32'hbf597fc7;
      6'd28: k_const = 32'hc6e00bf3;
      6'd29: k_const = 32'hd5a79147;
      6'd30: k_const = 32'h06ca6351;
      6'd31: k_const = 32'h14292967;
      6'd32: k_const = 32'h27b70a85;
      6'd33: k_const = 32'h2e1b2138;
      6'd34: k_const = 32'h4d2c6dfc;
      6'd35: k_const = 32'h53380d13;
      6'd36: k_const = 32'h650a7354;
      6'd37: k_const = 32'h766a0abb;
      6'd38: k_const = 32'h81c2c92e;
      6'd39: k_const = 32'h92722c85;
      6'd40: k_const = 32'ha2bfe8a1;
      6'd41: k_const = 32'ha81a664b;
      6'd42: k_const = 32'hc24b8b70;
      6'd43: k_const = 32'hc76c51a3;
      6'd44: k_const = 32'hd192e819;
      6'd45: k_const = 32'hd6990624;
      6'd46: k_const = 32'hf40e3585;
      6'd47: k_const = 32'h106aa070;
      6'd48: k_const = 32'h19a4c116;
      6'd49: k_const = 32'h1e376c08;
      6'd50: k_const = 32'h2748774c;
      6'd51: k_const = 32'h34b0bcb5;
      6'd52: k_const = 32'h391c0cb3;
      6'd53: k_const = 32'h4ed8aa4a;
      6'd54: k_const = 32'h5b9cca4f;
      6'd55: k_const = 32'h682e6ff3;
      6'd56: k_const = 32'h748f82ee;
      6'd57: k_const = 32'h78a5636f;
      6'd58: k_const = 32'h84c87814;
      6'd59: k_const = 32'h8cc70208;
      6'd60: k_const = 32'h90befffa;
      6'd61: k_const = 32'ha4506ceb;
      6'd62: k_const = 32'hbef9a3f7;
      default: k_const = 32'hc67178f2;
    endcase
  endfunction

  logic [31:0] hash_q[0:7];
  logic [7:0]  block_q[0:63];
  logic [31:0] w_q[0:63];
  logic [31:0] a_q, b_q, c_q, d_q, e_q, f_q, g_q, h_q;
  logic [6:0]  block_len_q;
  logic [5:0]  round_q;
  logic [63:0] msg_len_q;
  logic [2:0]  state_q;
  logic        finalizing_q;
  logic        pad_started_q;
  logic        finish_after_block_q;
  logic [255:0] tag_q;

  logic [7:0]   nbytes;
  logic         accept;
  logic [63:0]  bit_len;

  always_comb begin
    nbytes = 8'd0;
    for (int unsigned i = 0; i < BYTES; i++) begin
      if (keep[i]) begin
        nbytes = nbytes + 8'd1;
      end
    end
    accept = valid && ready;
    bit_len = msg_len_q << 3;
  end

  assign ready = (state_q == S_FILL) && !finalizing_q &&
                 ((8'(block_len_q) + nbytes) <= 8'd64);
  assign busy  = finalizing_q && (state_q != S_IDLE);
  assign tag   = tag_q;

  function automatic logic [31:0] rotr32(input logic [31:0] x, input int unsigned n);
    rotr32 = (x >> n) | (x << (32 - n));
  endfunction

  function automatic logic [31:0] big_sigma0(input logic [31:0] x);
    big_sigma0 = rotr32(x, 2) ^ rotr32(x, 13) ^ rotr32(x, 22);
  endfunction

  function automatic logic [31:0] big_sigma1(input logic [31:0] x);
    big_sigma1 = rotr32(x, 6) ^ rotr32(x, 11) ^ rotr32(x, 25);
  endfunction

  function automatic logic [31:0] small_sigma0(input logic [31:0] x);
    small_sigma0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3);
  endfunction

  function automatic logic [31:0] small_sigma1(input logic [31:0] x);
    small_sigma1 = rotr32(x, 17) ^ rotr32(x, 19) ^ (x >> 10);
  endfunction

  function automatic logic [31:0] ch(input logic [31:0] x,
                                     input logic [31:0] y,
                                     input logic [31:0] z);
    ch = (x & y) ^ (~x & z);
  endfunction

  function automatic logic [31:0] maj(input logic [31:0] x,
                                      input logic [31:0] y,
                                      input logic [31:0] z);
    maj = (x & y) ^ (x & z) ^ (y & z);
  endfunction

  // Working variables for one compression round.
  logic [31:0] w_val, t1, t2, na, nb, nc, nd, ne, nf, ng, nh;
  logic [31:0] hn [0:7];

  // Temporary variables are intentionally blocking: they model the
  // combinational round function inside the clocked process.
  /* verilator lint_off BLKSEQ */
  always_ff @(posedge clk) begin
    if (rst) begin
      hash_q[0] <= 32'h6a09e667;
      hash_q[1] <= 32'hbb67ae85;
      hash_q[2] <= 32'h3c6ef372;
      hash_q[3] <= 32'ha54ff53a;
      hash_q[4] <= 32'h510e527f;
      hash_q[5] <= 32'h9b05688c;
      hash_q[6] <= 32'h1f83d9ab;
      hash_q[7] <= 32'h5be0cd19;
      for (int unsigned i = 0; i < 64; i++) begin
        block_q[i] <= 8'h00;
        w_q[i]     <= 32'h00000000;
      end
      a_q <= 32'h0;
      b_q <= 32'h0;
      c_q <= 32'h0;
      d_q <= 32'h0;
      e_q <= 32'h0;
      f_q <= 32'h0;
      g_q <= 32'h0;
      h_q <= 32'h0;
      block_len_q <= 7'd0;
      round_q     <= 6'd0;
      msg_len_q   <= 64'd0;
      state_q     <= S_FILL;
      finalizing_q <= 1'b0;
      pad_started_q <= 1'b0;
      finish_after_block_q <= 1'b0;
      tag_q       <= 256'd0;
      tag_done    <= 1'b0;
    end else if (init) begin
      hash_q[0] <= 32'h6a09e667;
      hash_q[1] <= 32'hbb67ae85;
      hash_q[2] <= 32'h3c6ef372;
      hash_q[3] <= 32'ha54ff53a;
      hash_q[4] <= 32'h510e527f;
      hash_q[5] <= 32'h9b05688c;
      hash_q[6] <= 32'h1f83d9ab;
      hash_q[7] <= 32'h5be0cd19;
      block_len_q <= 7'd0;
      round_q     <= 6'd0;
      msg_len_q   <= 64'd0;
      state_q     <= S_FILL;
      finalizing_q <= 1'b0;
      pad_started_q <= 1'b0;
      finish_after_block_q <= 1'b0;
      tag_q       <= 256'd0;
      tag_done    <= 1'b0;
    end else begin
      tag_done <= 1'b0;

      // Byte ingestion.  `ready` guarantees the beat fits into the block.
      if (accept) begin
        for (int unsigned i = 0; i < BYTES; i++) begin
          if (keep[i]) begin
            block_q[32'(block_len_q) + i] <= data[i*8 +: 8];
          end
        end
        block_len_q <= 7'(32'(block_len_q) + 32'(nbytes));
        msg_len_q   <= msg_len_q + 64'(nbytes);
        if (last) begin
          finalizing_q <= 1'b1;
        end
      end

      case (state_q)
        S_FILL: begin
          if (block_len_q == 7'd64) begin
            finish_after_block_q <= 1'b0;
            state_q <= S_LOAD;
          end else if (finalizing_q) begin
            state_q <= S_PAD;
          end
        end

        S_PAD: begin
          if (!pad_started_q) begin
            // Place 0x80 after the last message byte.
            for (int unsigned i = 0; i < 64; i++) begin
              if (i < block_len_q) begin
                // keep existing message bytes
              end else if (32'(i) == 32'(block_len_q)) begin
                block_q[i] <= 8'h80;
              end else begin
                block_q[i] <= 8'h00;
              end
            end
            if (block_len_q <= 7'd55) begin
              block_q[56] <= bit_len[63:56];
              block_q[57] <= bit_len[55:48];
              block_q[58] <= bit_len[47:40];
              block_q[59] <= bit_len[39:32];
              block_q[60] <= bit_len[31:24];
              block_q[61] <= bit_len[23:16];
              block_q[62] <= bit_len[15:8];
              block_q[63] <= bit_len[7:0];
              finish_after_block_q <= 1'b1;
            end else begin
              finish_after_block_q <= 1'b0;
            end
            pad_started_q <= 1'b1;
          end else begin
            for (int unsigned i = 0; i < 56; i++) begin
              block_q[i] <= 8'h00;
            end
            block_q[56] <= bit_len[63:56];
            block_q[57] <= bit_len[55:48];
            block_q[58] <= bit_len[47:40];
            block_q[59] <= bit_len[39:32];
            block_q[60] <= bit_len[31:24];
            block_q[61] <= bit_len[23:16];
            block_q[62] <= bit_len[15:8];
            block_q[63] <= bit_len[7:0];
            finish_after_block_q <= 1'b1;
          end
          state_q <= S_LOAD;
        end

        S_LOAD: begin
          for (int unsigned i = 0; i < 16; i++) begin
            w_q[i] <= {block_q[4*i], block_q[4*i+1],
                       block_q[4*i+2], block_q[4*i+3]};
          end
          a_q <= hash_q[0];
          b_q <= hash_q[1];
          c_q <= hash_q[2];
          d_q <= hash_q[3];
          e_q <= hash_q[4];
          f_q <= hash_q[5];
          g_q <= hash_q[6];
          h_q <= hash_q[7];
          round_q <= 6'd0;
          block_len_q <= 7'd0;
          state_q <= S_COMPRESS;
        end

        S_COMPRESS: begin
          if (round_q < 6'd16) begin
            w_val = w_q[round_q];
          end else begin
            w_val = w_q[round_q-16] + small_sigma0(w_q[round_q-15]) +
                    w_q[round_q-7] + small_sigma1(w_q[round_q-2]);
            w_q[round_q] <= w_val;
          end

          t1 = h_q + big_sigma1(e_q) + ch(e_q, f_q, g_q) +
               k_const(round_q) + w_val;
          t2 = big_sigma0(a_q) + maj(a_q, b_q, c_q);

          na = t1 + t2;
          nb = a_q;
          nc = b_q;
          nd = c_q;
          ne = d_q + t1;
          nf = e_q;
          ng = f_q;
          nh = g_q;

          a_q <= na;
          b_q <= nb;
          c_q <= nc;
          d_q <= nd;
          e_q <= ne;
          f_q <= nf;
          g_q <= ng;
          h_q <= nh;

          if (round_q == 6'd63) begin
            hn[0] = hash_q[0] + na;
            hn[1] = hash_q[1] + nb;
            hn[2] = hash_q[2] + nc;
            hn[3] = hash_q[3] + nd;
            hn[4] = hash_q[4] + ne;
            hn[5] = hash_q[5] + nf;
            hn[6] = hash_q[6] + ng;
            hn[7] = hash_q[7] + nh;

            hash_q[0] <= hn[0];
            hash_q[1] <= hn[1];
            hash_q[2] <= hn[2];
            hash_q[3] <= hn[3];
            hash_q[4] <= hn[4];
            hash_q[5] <= hn[5];
            hash_q[6] <= hn[6];
            hash_q[7] <= hn[7];

            if (finish_after_block_q) begin
              for (int unsigned j = 0; j < 8; j++) begin
                tag_q[32*j +: 8]    <= hn[j][31:24];
                tag_q[32*j+8 +: 8]  <= hn[j][23:16];
                tag_q[32*j+16 +: 8] <= hn[j][15:8];
                tag_q[32*j+24 +: 8] <= hn[j][7:0];
              end
              tag_done <= 1'b1;
              state_q <= S_IDLE;
            end else begin
              block_len_q <= 7'd0;
              state_q <= S_FILL;
            end
          end else begin
            round_q <= round_q + 6'd1;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule
