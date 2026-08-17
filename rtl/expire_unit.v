//=============================================================================
// expire_unit.v - per-stream deadline check.
//   slack = deadline - now; sign bit set means expired. Wrap-safe as long as
//   the distance stays under 2^31. slack is exported to policy_core so the
//   subtractors are not duplicated.
//=============================================================================
`include "sched_defines.vh"

module expire_unit (
    input  wire [`N_STREAM*`REC_W-1:0]  i_head_bus,
    input  wire [`N_STREAM-1:0]         i_head_vld,
    input  wire [`CNT_W-1:0]            i_now,
    output wire [`N_STREAM-1:0]         o_expire,
    output wire [`N_STREAM*`CNT_W-1:0]  o_slack_bus
);

    genvar g;
    generate
        for (g = 0; g < `N_STREAM; g = g + 1) begin : g_exp
            wire [`REC_W-1:0] w_rec   = i_head_bus[g*`REC_W +: `REC_W];
            wire [`CNT_W-1:0] w_slack = `REC_DL(w_rec) - i_now;
            assign o_expire[g] = i_head_vld[g] & w_slack[`CNT_W-1];
            assign o_slack_bus[g*`CNT_W +: `CNT_W] = w_slack;
        end
    endgenerate

endmodule
