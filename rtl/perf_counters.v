//=============================================================================
// perf_counters.v - statistics counters, shared by TB and board SW.
//   miss is decided at grant time (fixed latency makes completion time known).
//   clear is synchronous only; keep it out of the async reset.
//=============================================================================
`include "sched_defines.vh"

module perf_counters (
    input  wire                i_clk,
    input  wire                i_rstn,
    input  wire                i_clr,
    input  wire [3:0]          i_push,
    input  wire [3:0]          i_grant,
    input  wire [3:0]          i_expire,
    input  wire                i_done,
    input  wire                i_busy,
    input  wire [`REC_W-1:0]   i_grant_rec,
    input  wire [`CNT_W-1:0]   i_now,
    output reg  [31:0]         o_pushed,
    output reg  [31:0]         o_dispatched,
    output reg  [31:0]         o_expired,
    output reg  [31:0]         o_miss,
    output reg  [31:0]         o_busy_cycles,
    output reg  [31:0]         o_done_total,
    output reg  [63:0]         o_sum_latency,
    output reg  [31:0]         o_disp_s0,
    output reg  [31:0]         o_disp_s1,
    output reg  [31:0]         o_disp_s2,
    output reg  [31:0]         o_disp_s3
);

    // 4b popcount (up to 4 expires in one cycle)
    function [2:0] f_cnt1;
        input [3:0] x;
        begin
            f_cnt1 = {2'b0, x[0]} + {2'b0, x[1]} + {2'b0, x[2]} + {2'b0, x[3]};
        end
    endfunction

    // Counter arithmetic is pipelined off the grant path. The grant-time
    // operands (grant vector, dl, ar, now) are captured here and the
    // subtract/compare/accumulate run one cycle later on the snapshot, so the
    // final counter values are identical while the 64b adder no longer sits on
    // the head->policy->arbiter critical path.
    reg        r_g_vld;
    reg [3:0]  r_g;
    reg [31:0] r_g_dl, r_g_ar;
    reg [`CNT_W-1:0] r_g_now;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_g_vld <= 1'b0; r_g <= 4'd0;
            r_g_dl <= 32'd0; r_g_ar <= 32'd0; r_g_now <= {`CNT_W{1'b0}};
        end else if (i_clr) begin
            r_g_vld <= 1'b0; r_g <= 4'd0;
        end else begin
            r_g_vld <= |i_grant;
            r_g     <= i_grant;
            r_g_dl  <= `REC_DL(i_grant_rec);
            r_g_ar  <= `REC_AR(i_grant_rec);
            r_g_now <= i_now;
        end
    end

    // computed from the snapshot: uses grant-time now, so results match the
    // unpipelined version bit for bit
    wire [32:0] w_finish = {1'b0, r_g_now} + `LATENCY;
    wire        w_miss   = r_g_vld & (w_finish > {1'b0, r_g_dl});
    wire [31:0] w_lat    = r_g_now - r_g_ar;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_pushed <= 32'd0; o_dispatched <= 32'd0; o_expired <= 32'd0;
            o_miss <= 32'd0; o_busy_cycles <= 32'd0; o_done_total <= 32'd0;
            o_sum_latency <= 64'd0;
            o_disp_s0 <= 32'd0; o_disp_s1 <= 32'd0; o_disp_s2 <= 32'd0; o_disp_s3 <= 32'd0;
        end else if (i_clr) begin
            o_pushed <= 32'd0; o_dispatched <= 32'd0; o_expired <= 32'd0;
            o_miss <= 32'd0; o_busy_cycles <= 32'd0; o_done_total <= 32'd0;
            o_sum_latency <= 64'd0;
            o_disp_s0 <= 32'd0; o_disp_s1 <= 32'd0; o_disp_s2 <= 32'd0; o_disp_s3 <= 32'd0;
        end else begin
            o_pushed  <= o_pushed  + {29'd0, f_cnt1(i_push)};
            o_expired <= o_expired + {29'd0, f_cnt1(i_expire)};
            if (r_g_vld) begin
                o_dispatched  <= o_dispatched + 32'd1;
                o_sum_latency <= o_sum_latency + {32'd0, w_lat};
                if (w_miss)  o_miss    <= o_miss + 32'd1;
                if (r_g[0])  o_disp_s0 <= o_disp_s0 + 32'd1;
                if (r_g[1])  o_disp_s1 <= o_disp_s1 + 32'd1;
                if (r_g[2])  o_disp_s2 <= o_disp_s2 + 32'd1;
                if (r_g[3])  o_disp_s3 <= o_disp_s3 + 32'd1;
            end
            if (i_done) o_done_total  <= o_done_total + 32'd1;
            if (i_busy) o_busy_cycles <= o_busy_cycles + 32'd1;
        end
    end

endmodule
