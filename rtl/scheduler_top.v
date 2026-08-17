//=============================================================================
// scheduler_top.v - top-level wiring. Own logic: pop merge, grant record mux,
//   idle detect.
//=============================================================================
`include "sched_defines.vh"

module scheduler_top #(
    parameter TRACE_FILE = "trace.mem",
    parameter TDEPTH     = 16384,
    parameter LATENCY    = `LATENCY
)(
    input  wire                i_clk,
    input  wire                i_rstn,
    input  wire                i_run,
    input  wire                i_clr,
    input  wire [1:0]          i_mode,
    input  wire [7:0]          i_w_d,
    input  wire [7:0]          i_w_u,
    input  wire [31:0]         i_n_entry,
    output wire                o_idle,
    output wire [`CNT_W-1:0]   o_now,
    // counters
    output wire [31:0]         o_pushed,
    output wire [31:0]         o_dispatched,
    output wire [31:0]         o_expired,
    output wire [31:0]         o_miss,
    output wire [31:0]         o_busy_cycles,
    output wire [31:0]         o_done_total,
    output wire [63:0]         o_sum_latency,
    output wire [31:0]         o_disp_s0,
    output wire [31:0]         o_disp_s1,
    output wire [31:0]         o_disp_s2,
    output wire [31:0]         o_disp_s3
);

    localparam FAW = $clog2(`FIFO_DEPTH);

    wire [3:0]                  w_push;
    wire [`REC_W-1:0]           w_pdata;
    wire                        w_trace_done;
    wire [4*`REC_W-1:0]         w_head_bus;
    wire [3:0]                  w_head_vld;
    wire [3:0]                  w_full;
    wire [4*(FAW+1)-1:0]        w_cnt_bus;
    wire [3:0]                  w_expire;
    wire [4*`CNT_W-1:0]         w_slack_bus;
    wire [3:0]                  w_sel_onehot;
    wire                        w_sel_vld;
    wire [3:0]                  w_grant;
    wire [1:0]                  w_rr_ptr;
    wire                        w_busy, w_done;
    wire [`REC_W-1:0]           w_eng_rec;

    // a head leaves either by expire or by grant; policy_core excludes
    // expiring heads from candidacy, so the two are mutually exclusive and a
    // plain OR is safe (checked by A5)
    wire [3:0] w_pop = w_expire | w_grant;

    cycle_counter u_cnt (
        .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr), .i_run(i_run),
        .o_now(o_now)
    );

    trace_player #(.TRACE_FILE(TRACE_FILE), .TDEPTH(TDEPTH)) u_player (
        .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr), .i_run(i_run),
        .i_now(o_now), .i_full(w_full), .i_n_entry(i_n_entry),
        .o_push(w_push), .o_wdata(w_pdata), .o_done(w_trace_done)
    );

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_fifo
            req_fifo #(.DEPTH(`FIFO_DEPTH), .DW(`REC_W), .AW(FAW)) u_fifo (
                .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr),
                .i_push(w_push[g]), .i_wdata(w_pdata),
                .i_pop(w_pop[g]),
                .o_head(w_head_bus[g*`REC_W +: `REC_W]),
                .o_head_vld(w_head_vld[g]),
                .o_full(w_full[g]),
                .o_cnt(w_cnt_bus[g*(FAW+1) +: (FAW+1)])
            );
        end
    endgenerate

    expire_unit u_exp (
        .i_head_bus(w_head_bus), .i_head_vld(w_head_vld), .i_now(o_now),
        .o_expire(w_expire), .o_slack_bus(w_slack_bus)
    );

    policy_core u_pol (
        .i_mode(i_mode), .i_w_d(i_w_d), .i_w_u(i_w_u),
        .i_head_bus(w_head_bus), .i_head_vld(w_head_vld),
        .i_expire(w_expire), .i_slack_bus(w_slack_bus),
        .i_rr_ptr(w_rr_ptr),
        .o_sel_onehot(w_sel_onehot), .o_sel_vld(w_sel_vld)
    );

    dispatch_arbiter u_arb (
        .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr), .i_run(i_run),
        .i_engine_busy(w_busy),
        .i_sel_vld(w_sel_vld), .i_sel_onehot(w_sel_onehot),
        .o_grant(w_grant), .o_rr_ptr(w_rr_ptr)
    );

    // granted record (one-hot mux)
    reg [`REC_W-1:0] w_grant_rec;
    always @(*) begin
        case (w_grant)
            4'b0001 : w_grant_rec = w_head_bus[0*`REC_W +: `REC_W];
            4'b0010 : w_grant_rec = w_head_bus[1*`REC_W +: `REC_W];
            4'b0100 : w_grant_rec = w_head_bus[2*`REC_W +: `REC_W];
            4'b1000 : w_grant_rec = w_head_bus[3*`REC_W +: `REC_W];
            default : w_grant_rec = {`REC_W{1'b0}};
        endcase
    end

    engine_model #(.LATENCY(LATENCY)) u_eng (
        .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr),
        .i_grant(w_grant), .i_rec(w_grant_rec),
        .o_busy(w_busy), .o_done(w_done), .o_rec(w_eng_rec)
    );

    perf_counters u_perf (
        .i_clk(i_clk), .i_rstn(i_rstn), .i_clr(i_clr),
        .i_push(w_push), .i_grant(w_grant), .i_expire(w_expire),
        .i_done(w_done), .i_busy(w_busy),
        .i_grant_rec(w_grant_rec), .i_now(o_now),
        .o_pushed(o_pushed), .o_dispatched(o_dispatched), .o_expired(o_expired),
        .o_miss(o_miss), .o_busy_cycles(o_busy_cycles), .o_done_total(o_done_total),
        .o_sum_latency(o_sum_latency),
        .o_disp_s0(o_disp_s0), .o_disp_s1(o_disp_s1),
        .o_disp_s2(o_disp_s2), .o_disp_s3(o_disp_s3)
    );

    // experiment-done flag; TB / board SW reads counters after this
    assign o_idle = w_trace_done & ~(|w_head_vld) & ~w_busy;

endmodule
