//=============================================================================
// dispatch_arbiter.v - issues the grant.
//   grant = run & engine idle & candidate valid (combinational, 1-cycle pulse).
//   rr_ptr points one past the last winner; policy_core uses it for tie-break.
//=============================================================================
`include "sched_defines.vh"

module dispatch_arbiter (
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_clr,
    input  wire        i_run,
    input  wire        i_engine_busy,
    input  wire        i_sel_vld,
    input  wire [3:0]  i_sel_onehot,
    output wire [3:0]  o_grant,
    output reg  [1:0]  o_rr_ptr
);

    assign o_grant = (i_run & ~i_engine_busy & i_sel_vld) ? i_sel_onehot : 4'b0000;

    // one-hot to index
    wire [1:0] w_gidx = o_grant[1] ? 2'd1 :
                        o_grant[2] ? 2'd2 :
                        o_grant[3] ? 2'd3 : 2'd0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn)         o_rr_ptr <= 2'd0;
        else if (i_clr)      o_rr_ptr <= 2'd0;
        else if (|o_grant)   o_rr_ptr <= w_gidx + 1'b1;   // rotate past winner
    end

endmodule
