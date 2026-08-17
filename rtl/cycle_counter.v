//=============================================================================
// cycle_counter.v - global cycle counter. Counts only while i_run is high,
//   so time is frozen while the trace is being loaded.
//=============================================================================
`include "sched_defines.vh"

module cycle_counter (
    input  wire                i_clk,
    input  wire                i_rstn,
    input  wire                i_clr,     // soft clear (sync)
    input  wire                i_run,
    output reg  [`CNT_W-1:0]   o_now
);

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn)      o_now <= {`CNT_W{1'b0}};
        else if (i_clr)   o_now <= {`CNT_W{1'b0}};
        else if (i_run)   o_now <= o_now + 1'b1;
    end

endmodule
