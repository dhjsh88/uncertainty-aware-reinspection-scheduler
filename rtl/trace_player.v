//=============================================================================
// trace_player.v - replays trace.mem, pushing each entry to its stream FIFO
//   at its arrival cycle.
//   entry 88b = {stream[87:80] (low 2b used), req_id[79:72], u[71:64],
//                deadline[63:32], arrival[31:0]}; [79:0] is the record.
//   push/wdata are registered (one cycle after detect) so the index and data
//   paths stay aligned. At most one push per cycle; simultaneous arrivals
//   serialize (golden model follows the same rule).
//   Note: N_ENTRY larger than the file waits on x data forever.
//=============================================================================
`include "sched_defines.vh"

module trace_player #(
    parameter TRACE_FILE = "trace.mem",
    parameter TDEPTH     = 16384
)(
    input  wire                i_clk,
    input  wire                i_rstn,
    input  wire                i_clr,
    input  wire                i_run,
    input  wire [`CNT_W-1:0]   i_now,
    input  wire [3:0]          i_full,
    input  wire [31:0]         i_n_entry,
    output reg  [3:0]          o_push,
    output reg  [`REC_W-1:0]   o_wdata,
    output wire                o_done
);

    localparam TAW = $clog2(TDEPTH);

    reg [87:0] mem [0:TDEPTH-1];
    initial $readmemh(TRACE_FILE, mem);   // memory init at synthesis

    reg  [31:0] r_idx;
    wire [87:0] w_ent    = mem[r_idx[TAW-1:0]];
    wire [1:0]  w_stream = w_ent[81:80];
    wire        w_valid  = i_run & (r_idx < i_n_entry);
    wire        w_due    = w_valid & (i_now >= w_ent[31:0]);
    wire        w_can    = w_due & ~i_full[w_stream];

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_push <= 4'b0000; r_idx <= 32'd0; o_wdata <= {`REC_W{1'b0}};
        end else if (i_clr) begin
            o_push <= 4'b0000; r_idx <= 32'd0;
        end else begin
            o_push <= 4'b0000;
            if (w_can) begin
                o_push  <= 4'b0001 << w_stream;
                o_wdata <= w_ent[79:0];
                r_idx   <= r_idx + 32'd1;
            end
        end
    end

    assign o_done = i_run & (r_idx >= i_n_entry) & ~(|o_push);

endmodule
