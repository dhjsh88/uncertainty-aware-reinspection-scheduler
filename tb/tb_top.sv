//=============================================================================
// tb_top.sv - self-checking testbench.
//   Sequence: clock, reset release, run, wait for idle (with timeout), dump
//   counters and dispatch log. The dispatch log (cycle,stream,req_id per
//   grant) feeds compare.py. A6 conservation check at end of sim:
//   pushed == dispatched + expired.
//
// compile-time configuration (override with -d / edit the block below):
//   -DTRACE_FILE=\"...\" -DN_ENTRY=... -DMODE_SEL="2'd1" -DW_D=8'd3 -DW_U=8'd1
//   -DLOG_FILE=\"...\" -DCNT_FILE=\"...\"
//=============================================================================
`timescale 1ns/1ps
`include "sched_defines.vh"

`ifndef TRACE_FILE
`define TRACE_FILE "trace.mem"
`endif
`ifndef N_ENTRY
`define N_ENTRY 32
`endif
`ifndef MODE_SEL
`define MODE_SEL 2'd0
`endif
`ifndef W_D
`define W_D 8'd3
`endif
`ifndef W_U
`define W_U 8'd1
`endif
`ifndef LOG_FILE
`define LOG_FILE "dispatch_rtl.csv"
`endif
`ifndef CNT_FILE
`define CNT_FILE "counters_rtl.csv"
`endif
`ifndef TIMEOUT
`define TIMEOUT 5_000_000
`endif

module tb_top;

    reg i_clk = 1'b0;
    reg i_rstn = 1'b0;
    reg i_run  = 1'b0;
    reg i_clr  = 1'b0;
    reg [1:0]  i_mode;
    reg [7:0]  i_w_d, i_w_u;
    reg [31:0] i_n_entry;

    wire        w_idle;
    wire [31:0] w_now;
    wire [31:0] w_pushed, w_dispatched, w_expired, w_miss, w_busy_cycles, w_done_total;
    wire [63:0] w_sum_latency;
    wire [31:0] w_ds0, w_ds1, w_ds2, w_ds3;

    scheduler_top #(.TRACE_FILE(`TRACE_FILE)) u_top (
        .i_clk(i_clk), .i_rstn(i_rstn),
        .i_run(i_run), .i_clr(i_clr),
        .i_mode(i_mode), .i_w_d(i_w_d), .i_w_u(i_w_u),
        .i_n_entry(i_n_entry),
        .o_idle(w_idle), .o_now(w_now),
        .o_pushed(w_pushed), .o_dispatched(w_dispatched), .o_expired(w_expired),
        .o_miss(w_miss), .o_busy_cycles(w_busy_cycles), .o_done_total(w_done_total),
        .o_sum_latency(w_sum_latency),
        .o_disp_s0(w_ds0), .o_disp_s1(w_ds1), .o_disp_s2(w_ds2), .o_disp_s3(w_ds3)
    );

    always #5 i_clk = ~i_clk;   // 10ns period

    // dispatch log, sampled at negedge for a settled grant/now snapshot
    integer fd;
    wire [1:0] w_gidx = u_top.w_grant[1] ? 2'd1 :
                        u_top.w_grant[2] ? 2'd2 :
                        u_top.w_grant[3] ? 2'd3 : 2'd0;
    always @(negedge i_clk) begin
        if (i_rstn && (|u_top.w_grant)) begin
            $fdisplay(fd, "%0d,%0d,%0d", w_now, w_gidx, `REC_ID(u_top.w_grant_rec));
        end
    end

    integer fdc;
    integer timeout;
    integer fifo_resid;

    initial begin
        i_mode    = `MODE_SEL;
        i_w_d     = `W_D;
        i_w_u     = `W_U;
        i_n_entry = `N_ENTRY;

        fd = $fopen(`LOG_FILE, "w");
        $fdisplay(fd, "cycle,stream,req_id");

        // reset release, then run
        repeat (10) @(posedge i_clk);
        i_rstn = 1'b1;
        repeat (5) @(posedge i_clk);
        i_run = 1'b1;

        // wait for idle (timeout guards against a hang)
        timeout = 0;
        while (!w_idle && timeout < `TIMEOUT) begin
            @(posedge i_clk);
            timeout = timeout + 1;
        end
        // let counters settle
        repeat (4) @(posedge i_clk);

        if (!w_idle) begin
            $display("[TB] TIMEOUT after %0d cycles, idle never asserted", timeout);
        end

        // counter dump (name,value for compare.py)
        fdc = $fopen(`CNT_FILE, "w");
        $fdisplay(fdc, "pushed,%0d",       w_pushed);
        $fdisplay(fdc, "dispatched,%0d",   w_dispatched);
        $fdisplay(fdc, "expired,%0d",      w_expired);
        $fdisplay(fdc, "miss,%0d",         w_miss);
        $fdisplay(fdc, "done_total,%0d",   w_done_total);
        $fdisplay(fdc, "busy_cycles,%0d",  w_busy_cycles);
        $fdisplay(fdc, "sum_latency,%0d",  w_sum_latency);
        $fdisplay(fdc, "disp_s0,%0d",      w_ds0);
        $fdisplay(fdc, "disp_s1,%0d",      w_ds1);
        $fdisplay(fdc, "disp_s2,%0d",      w_ds2);
        $fdisplay(fdc, "disp_s3,%0d",      w_ds3);
        $fdisplay(fdc, "end_cycle,%0d",    w_now);
        $fclose(fdc);
        $fclose(fd);

        $display("[TB] pushed=%0d dispatched=%0d expired=%0d miss=%0d done=%0d",
                 w_pushed, w_dispatched, w_expired, w_miss, w_done_total);

        // A6 conservation: pushed == dispatched + expired, no residue
        fifo_resid = u_top.g_fifo[0].u_fifo.o_cnt + u_top.g_fifo[1].u_fifo.o_cnt
                   + u_top.g_fifo[2].u_fifo.o_cnt + u_top.g_fifo[3].u_fifo.o_cnt;
        if (w_pushed == (w_dispatched + w_expired) && fifo_resid == 0 && w_idle)
            $display("[TB] A6 conservation PASS");
        else
            $display("[TB] A6 conservation FAIL: pushed=%0d disp=%0d exp=%0d resid=%0d idle=%0d",
                     w_pushed, w_dispatched, w_expired, fifo_resid, w_idle);

        $finish;
    end

endmodule
