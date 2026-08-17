//=============================================================================
// sva_bind.sv - concurrent assertions attached to scheduler_top via bind, so
//   the design files stay untouched. Written for xsim (plain asserts only).
//   A6 (conservation) is an end-of-sim check and lives in tb_top.
//   iverilog does not support concurrent assertions; exclude this file there.
//=============================================================================
`include "sched_defines.vh"

module sched_sva (
    input wire                      i_clk,
    input wire                      i_rstn,
    input wire [3:0]                w_grant,
    input wire [3:0]                w_head_vld,
    input wire [3:0]                w_expire,
    input wire                      w_busy,
    input wire [4*`CNT_W-1:0]       w_slack_bus
);

    // A1: grant is one-hot or zero
    a1_grant_onehot0 : assert property (@(posedge i_clk) disable iff (!i_rstn)
        $onehot0(w_grant))
        else $error("[SVA A1] grant not one-hot0: %b", w_grant);

    // A3: no grant while engine busy
    a3_no_grant_when_busy : assert property (@(posedge i_clk) disable iff (!i_rstn)
        w_busy |-> (w_grant == 4'b0000))
        else $error("[SVA A3] grant while engine busy");

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_sva
            // A2: granted head must be valid
            a2_grant_head_vld : assert property (@(posedge i_clk) disable iff (!i_rstn)
                w_grant[g] |-> w_head_vld[g])
                else $error("[SVA A2] grant on empty head, stream %0d", g);

            // A4: no grant of an expired head (slack sign bit must be 0)
            a4_grant_not_expired : assert property (@(posedge i_clk) disable iff (!i_rstn)
                w_grant[g] |-> !w_slack_bus[g*`CNT_W + `CNT_W - 1])
                else $error("[SVA A4] dispatched expired request, stream %0d", g);

            // A5: expire and grant never hit the same head in one cycle
            a5_no_expire_and_grant : assert property (@(posedge i_clk) disable iff (!i_rstn)
                !(w_grant[g] & w_expire[g]))
                else $error("[SVA A5] expire+grant same head, stream %0d", g);
        end
    endgenerate

endmodule

// bound to internal signal names
bind scheduler_top sched_sva u_sva (
    .i_clk(i_clk), .i_rstn(i_rstn),
    .w_grant(w_grant), .w_head_vld(w_head_vld), .w_expire(w_expire),
    .w_busy(w_busy), .w_slack_bus(w_slack_bus)
);
