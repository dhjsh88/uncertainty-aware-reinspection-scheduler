//=============================================================================
// engine_model.v - fixed-latency engine stub.
//   Busy for LATENCY cycles after grant, then a 1-cycle done pulse.
//   Placeholder for a real accelerator with the same grant/busy/done interface.
//=============================================================================
`include "sched_defines.vh"

module engine_model #(
    parameter LATENCY = `LATENCY
)(
    input  wire                i_clk,
    input  wire                i_rstn,
    input  wire                i_clr,
    input  wire [3:0]          i_grant,
    input  wire [`REC_W-1:0]   i_rec,
    output reg                 o_busy,
    output reg                 o_done,     // 1-cycle pulse
    output reg  [`REC_W-1:0]   o_rec       // record in service (debug)
);

    localparam CW = $clog2(LATENCY + 1);
    reg [CW-1:0] r_cnt;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_busy <= 1'b0; o_done <= 1'b0; r_cnt <= {CW{1'b0}}; o_rec <= {`REC_W{1'b0}};
        end else if (i_clr) begin
            o_busy <= 1'b0; o_done <= 1'b0; r_cnt <= {CW{1'b0}};
        end else begin
            o_done <= 1'b0;                    // default low
            if (|i_grant) begin
                o_busy <= 1'b1;
                o_rec  <= i_rec;
                r_cnt  <= LATENCY - 1;         // grant cycle counts as one
            end else if (o_busy) begin
                if (r_cnt == {CW{1'b0}}) begin
                    o_busy <= 1'b0;
                    o_done <= 1'b1;            // pulse on final cycle
                end else begin
                    r_cnt <= r_cnt - 1'b1;
                end
            end
        end
    end

endmodule
