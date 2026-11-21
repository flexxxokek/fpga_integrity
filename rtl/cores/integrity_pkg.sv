// Shared definitions for the integrity cores and wrappers.
package integrity_pkg;

  // Algorithm selector used by integrity_tx / integrity_rx.
  typedef enum int {
    ALGO_PARITY    = 0,
    ALGO_CHECKSUM  = 1,
    ALGO_FLETCHER  = 2,
    ALGO_ADLER32   = 3,
    ALGO_CRC       = 4,
    ALGO_SHA256    = 5
  } algo_t;

  // Number of bytes required to carry a tag of TAG_WIDTH bits.
  function automatic int unsigned tag_bytes(input int unsigned tag_width);
    return (tag_width + 7) / 8;
  endfunction

  // Ceiling of log2(n), with n == 1 returning 1.
  function automatic int unsigned clog2(input int unsigned n);
    int unsigned r;
    r = 0;
    if (n > 1) begin
      for (r = 0; (1 << r) < n; r = r + 1) begin
        // empty
      end
    end else begin
      r = 1;
    end
    return r;
  endfunction

endpackage
