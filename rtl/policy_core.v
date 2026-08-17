//=============================================================================
// policy_core.v - selects one dispatch candidate among the 4 stream heads.
//   All modes are mapped to a single "larger wins" prio so one compare tree
//   serves every policy:
//     FIFO : ~arrival      (older -> larger; unsigned a<b <=> ~a>~b)
//     EDF  : ~slack        (tighter -> larger)
//     UNC  : uncertainty   (as is)
//     HYB  : W_D*urgency8 + W_U*u  (17b score)
//   Tie-break: smallest rank = g - rr_ptr (2b wrap) -> rotating fairness.
//=============================================================================
`include "sched_defines.vh"

module policy_core (
    input  wire [1:0]                   i_mode,
    input  wire [7:0]                   i_w_d,
    input  wire [7:0]                   i_w_u,
    input  wire [4*`REC_W-1:0]          i_head_bus,
    input  wire [3:0]                   i_head_vld,
    input  wire [3:0]                   i_expire,
    input  wire [4*`CNT_W-1:0]          i_slack_bus,
    input  wire [1:0]                   i_rr_ptr,
    output wire [3:0]                   o_sel_onehot,
    output wire                         o_sel_vld
);

    wire [3:0]     w_cand;
    wire [4*32-1:0] w_prio_bus;
    wire [4*2-1:0]  w_rank_bus;

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_key
            wire [`REC_W-1:0] w_rec   = i_head_bus[g*`REC_W +: `REC_W];
            wire [`CNT_W-1:0] w_slack = i_slack_bus[g*`CNT_W +: `CNT_W];

            // candidate = head valid & not expiring this cycle
            assign w_cand[g] = i_head_vld[g] & ~i_expire[g];

            // hybrid score (spec 3.3)
            wire [15:0] w_slack16 = (|w_slack[31:16]) ? 16'hFFFF : w_slack[15:0]; // saturate
            wire [15:0] w_urg16   = `SLACK_MAX - w_slack16;   // less slack -> larger
            wire [7:0]  w_urg8    = w_urg16[15:8];            // top 8 bits
            wire [16:0] w_score   = i_w_d * w_urg8 + i_w_u * `REC_U(w_rec); // 16b+16b=17b

            reg [31:0] r_prio;
            always @(*) begin
                case (i_mode)
                    `MODE_FIFO : r_prio = ~`REC_AR(w_rec);
                    `MODE_EDF  : r_prio = ~w_slack;
                    `MODE_UNC  : r_prio = {24'd0, `REC_U(w_rec)};
                    default    : r_prio = {15'd0, w_score};   // MODE_HYB
                endcase
            end
            assign w_prio_bus[g*32 +: 32] = r_prio;
            assign w_rank_bus[g*2  +:  2] = g[1:0] - i_rr_ptr;  // 2b wrap sub
        end
    endgenerate

    // pairwise compare, returns {valid, winner index}.
    // order: valid first, then larger prio, then smaller rank on tie
    function [2:0] f_pick;
        input        a_vld;
        input [31:0] a_pri;
        input [1:0]  a_rnk;
        input [1:0]  a_idx;
        input        b_vld;
        input [31:0] b_pri;
        input [1:0]  b_rnk;
        input [1:0]  b_idx;
        begin
            if (a_vld & ~b_vld)          f_pick = {1'b1, a_idx};
            else if (~a_vld & b_vld)     f_pick = {1'b1, b_idx};
            else if (~a_vld & ~b_vld)    f_pick = 3'b000;
            else if (a_pri > b_pri)      f_pick = {1'b1, a_idx};
            else if (a_pri < b_pri)      f_pick = {1'b1, b_idx};
            else if (a_rnk <= b_rnk)     f_pick = {1'b1, a_idx};
            else                         f_pick = {1'b1, b_idx};
        end
    endfunction

    // tournament: (0 vs 1), (2 vs 3), then final
    wire [2:0] w_s01 = f_pick(w_cand[0], w_prio_bus[0*32 +: 32], w_rank_bus[0*2 +: 2], 2'd0,
                              w_cand[1], w_prio_bus[1*32 +: 32], w_rank_bus[1*2 +: 2], 2'd1);
    wire [2:0] w_s23 = f_pick(w_cand[2], w_prio_bus[2*32 +: 32], w_rank_bus[2*2 +: 2], 2'd2,
                              w_cand[3], w_prio_bus[3*32 +: 32], w_rank_bus[3*2 +: 2], 2'd3);

    wire [1:0] w_i01 = w_s01[1:0];
    wire [1:0] w_i23 = w_s23[1:0];

    wire [2:0] w_fin = f_pick(w_s01[2], w_prio_bus[w_i01*32 +: 32], w_rank_bus[w_i01*2 +: 2], w_i01,
                              w_s23[2], w_prio_bus[w_i23*32 +: 32], w_rank_bus[w_i23*2 +: 2], w_i23);

    assign o_sel_vld    = w_fin[2];
    assign o_sel_onehot = w_fin[2] ? (4'b0001 << w_fin[1:0]) : 4'b0000;

endmodule
